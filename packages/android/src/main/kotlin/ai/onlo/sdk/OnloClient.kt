package ai.onlo.sdk

import ai.onlo.sdk.logging.SafeLogCode
import ai.onlo.sdk.logging.SafeLogEvent
import ai.onlo.sdk.logging.SafeLogger
import ai.onlo.sdk.protocol.ApiFailure
import ai.onlo.sdk.protocol.ApiRetry
import ai.onlo.sdk.protocol.ApiSuccess
import ai.onlo.sdk.protocol.Capability
import ai.onlo.sdk.protocol.IdentityClass
import ai.onlo.sdk.protocol.PROTOCOL_VERSION
import ai.onlo.sdk.protocol.ProtocolViolation
import ai.onlo.sdk.protocol.RetryDirective
import ai.onlo.sdk.protocol.SdkClientDescriptor
import ai.onlo.sdk.protocol.SdkFamily
import ai.onlo.sdk.protocol.SessionOperation
import ai.onlo.sdk.protocol.SessionRequest
import ai.onlo.sdk.protocol.SessionResult
import ai.onlo.sdk.security.CredentialLoad
import ai.onlo.sdk.security.CredentialStore
import ai.onlo.sdk.security.PendingSessionTransition
import ai.onlo.sdk.security.ProtectedSession
import ai.onlo.sdk.security.ProtectedSessionState
import ai.onlo.sdk.config.MobileConfigController
import ai.onlo.sdk.config.MobileConfigSnapshot
import ai.onlo.sdk.storage.OwnerScope
import ai.onlo.sdk.storage.OwnerScopedOutboxStore
import ai.onlo.sdk.transport.OnloSessionApi
import ai.onlo.sdk.chat.DurableChatOutbox
import ai.onlo.sdk.chat.WidgetChatApi
import ai.onlo.sdk.chat.ConversationDetail
import ai.onlo.sdk.chat.ConversationSummary
import ai.onlo.sdk.chat.TranscriptConvergence
import ai.onlo.sdk.chat.ForegroundStream
import ai.onlo.sdk.chat.ForegroundHint
import ai.onlo.sdk.push.PushAuthority
import ai.onlo.sdk.push.PushPayloadOutcome
import ai.onlo.sdk.push.PushRegistrationOutcome
import ai.onlo.sdk.push.PushRegistry
import java.io.IOException
import java.security.SecureRandom
import java.util.Base64
import java.util.UUID
import kotlin.random.Random
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

internal data class OnloConfiguration(
    val sdkKey: String,
    val appIdentifier: String,
    val sdkVersion: String = SDK_VERSION,
    val appVersion: String? = null,
    val appBuild: String? = null,
    /** Internal bridge selection only; hosts cannot select a different SDK family. */
    val sdkFamily: SdkFamily = SdkFamily.ANDROID,
    val capabilities: List<Capability> = listOf(
        Capability.SECURE_STORAGE,
        Capability.PERSISTENT_OUTBOX,
        Capability.IDENTITY_JWT,
    ),
) {
    init {
        require(sdkKey.isNotBlank()) { "sdk_key" }
        require(appIdentifier.isNotBlank()) { "app_identifier" }
        require(sdkVersion.isNotBlank()) { "sdk_version" }
    }
}

public enum class OnloPhase {
    RESTORING,
    ANONYMOUS_READY,
    IDENTIFYING,
    IDENTIFIED_READY,
    OFFLINE_READY,
    REAUTHENTICATION_REQUIRED,
    LOGOUT_PENDING,
}

public enum class OnloIdentityState {
    UNKNOWN,
    ANONYMOUS,
    IDENTIFIED,
}

/** No session identifiers, credentials, or customer content are exposed through state. */
public data class OnloState(
    val phase: OnloPhase,
    val identity: OnloIdentityState,
    val safeErrorCode: String? = null,
)

/** Native messenger adapters consume this state intent; the core installs no overlay itself. */
public enum class MessengerPresentationIntent {
    HIDDEN,
    PRESENT,
}

/** UI hosts observe this only after the native core has authorised the requested transcript. */
public sealed interface MessengerPresentationTarget {
    public data object Inbox : MessengerPresentationTarget
    public data class Conversation(val conversationId: String) : MessengerPresentationTarget
}

public sealed interface OpenConversationOutcome {
    public data object Opened : OpenConversationOutcome
    public data object NoActiveSession : OpenConversationOutcome
    public data object NotAuthorised : OpenConversationOutcome
    public data object Unavailable : OpenConversationOutcome
}

public sealed interface LogoutOutcome {
    public data object Completed : LogoutOutcome
    public data object AlreadyAnonymous : LogoutOutcome
    public data class Pending(val safeErrorCode: String) : LogoutOutcome
}

/** Internal UI data boundary. Content never crosses a React Native or Flutter adapter. */
internal sealed interface MessengerInboxResult {
    data class Ready(val conversations: List<ConversationSummary>) : MessengerInboxResult
    data object NoActiveSession : MessengerInboxResult
    data object Unavailable : MessengerInboxResult
}

/** Internal UI data boundary. A changed account invalidates an in-flight fetch. */
internal sealed interface MessengerTranscriptResult {
    data class Ready(val transcript: ConversationDetail) : MessengerTranscriptResult
    /** Last authorised encrypted transcript remains renderable while a refresh is offline. */
    data class Stale(val transcript: ConversationDetail) : MessengerTranscriptResult
    data object NoActiveSession : MessengerTranscriptResult
    data object NotAuthorised : MessengerTranscriptResult
    data object Unavailable : MessengerTranscriptResult
}

public sealed class OnloException(internal val safeCode: String) : IllegalStateException(safeCode) {
    public data object LogoutRequired : OnloException("logout_required")
    public data object LogoutInProgress : OnloException("logout_pending")
    public data object InvalidUserJwt : OnloException("invalid_user_jwt")
    public data object IdentityRetryRequired : OnloException("identity_retry_required")
    public data object PendingTransitionUnavailable : OnloException("pending_transition_unavailable")
    public data object Unavailable : OnloException("transport_unavailable")
    public data object InvalidProtocol : OnloException("invalid_protocol")
    public data class Server(val code: String, val retry: RetryDirective) : OnloException(code)
}

/**
 * The server gives per-conversation `unreadCount` values only. Keep the sum in the safe Int
 * range so a malformed response cannot create a negative or wrapped framework-visible total.
 */
internal fun totalUnreadCount(conversations: List<ConversationSummary>): Int {
    var total = 0L
    for (conversation in conversations) {
        if (conversation.unreadCount < 0) throw ProtocolViolation("conversation_list")
        total += conversation.unreadCount.toLong()
        if (total > Int.MAX_VALUE) throw ProtocolViolation("conversation_list")
    }
    return total.toInt()
}

/**
 * Native session owner. All lifecycle mutation is serialized, while state and presentation intent
 * are observable as Flow for Compose and View hosts.
 */
public class OnloClient internal constructor(
    private val configuration: OnloConfiguration,
    private val credentialStore: CredentialStore,
    private val outboxStore: OwnerScopedOutboxStore,
    private val sessionApi: OnloSessionApi,
    private val logger: SafeLogger,
    private val scope: CoroutineScope,
    private val configController: MobileConfigController? = null,
    private val widgetChatApi: WidgetChatApi? = null,
    private val foregroundStream: ForegroundStream? = null,
    private val pushRegistry: PushRegistry? = null,
    private val nowMs: () -> Long = { System.currentTimeMillis() },
    private val fallbackBackoffJitter: () -> Double = { Random.nextDouble() },
) {
    private val operationMutex = Mutex()
    private var protectedSession: ProtectedSession? = null
    private var pendingTransition: PendingSessionTransition? = null
    private var inMemorySession: InMemorySession? = null
    private var configSessionVersion = 0L
    private var restorationJob: Job? = null
    private var chatFlushJob: Job? = null
    private var foregroundJob: Job? = null

    private val mutableState = MutableStateFlow(
        OnloState(OnloPhase.RESTORING, OnloIdentityState.UNKNOWN),
    )
    // This is derived only from an authorised conversation-list response. It is deliberately
    // reset on every account boundary rather than retaining one owner's inbox state for another.
    private val mutableUnreadCount = MutableStateFlow<Int?>(null)
    private val mutablePresentation = MutableStateFlow(MessengerPresentationIntent.HIDDEN)
    private val mutablePresentationTarget = MutableStateFlow<MessengerPresentationTarget>(MessengerPresentationTarget.Inbox)

    public val state: StateFlow<OnloState> = mutableState.asStateFlow()
    /** Account-bound total from the canonical conversation-list `unreadCount` values. */
    public val unreadCount: StateFlow<Int?> = mutableUnreadCount.asStateFlow()
    public val presentationIntent: StateFlow<MessengerPresentationIntent> = mutablePresentation.asStateFlow()
    public val presentationTarget: StateFlow<MessengerPresentationTarget> = mutablePresentationTarget.asStateFlow()
    /** Validated native configuration only; it never exposes credentials or customer state. */
    public val mobileConfig: StateFlow<MobileConfigSnapshot>? get() = configController?.snapshot

    internal fun startRestoration() {
        if (restorationJob != null) return
        restorationJob = scope.launch {
            configController?.restoreLastKnownGood()
            runCatching { restoreOrBootstrap() }
                .onFailure { failure -> publishFailure(failure, phaseForCurrentScope()) }
        }
    }

    /** Explicitly establishes or refreshes anonymous continuity without changing an identified user. */
    public suspend fun loginUnidentifiedUser(): OnloState = operationMutex.withLock {
        var stored = loadProtectedSession()
        if (stored?.logoutPending == true) throw OnloException.LogoutInProgress
        if (stored?.identityClass == IdentityClass.IDENTIFIED) {
            if (logoutLocked(checkNotNull(stored)) !is LogoutOutcome.Completed) throw OnloException.LogoutInProgress
            stored = checkNotNull(protectedSession)
        }
        if (pendingTransition is PendingSessionTransition.Identify) throw OnloException.IdentityRetryRequired
        restoreOrBootstrapLocked(stored)
        state.value
    }

    /** Exchanges, but never persists or locally verifies, the Operator backend's short-lived JWT. */
    public suspend fun loginIdentifiedUser(userJwt: String): OnloState = operationMutex.withLock {
        validateCompactJwt(userJwt)
        var stored = loadProtectedSession()
        if (stored?.logoutPending == true) throw OnloException.LogoutInProgress
        pendingTransition?.let { pending ->
            if (pending is PendingSessionTransition.Identify) {
                return@withLock identifyWithPending(stored ?: throw OnloException.PendingTransitionUnavailable, pending, userJwt)
            }
            restoreOrBootstrapLocked(stored)
            stored = checkNotNull(protectedSession)
        }
        if (stored == null) {
            restoreOrBootstrapLocked(null)
            stored = checkNotNull(protectedSession)
        }
        if (stored.identityClass == IdentityClass.IDENTIFIED) {
            if (logoutLocked(checkNotNull(stored)) !is LogoutOutcome.Completed) throw OnloException.LogoutInProgress
            stored = checkNotNull(protectedSession)
        }

        val pending = PendingSessionTransition.Identify(
            installationId = stored.installationId,
            transitionId = newUuid(),
            expectedGeneration = stored.generation,
            presentedCredential = stored.credential,
            proposedCredential = newCredential(),
        )
        return@withLock identifyWithPending(stored, pending, userJwt)
    }

    /**
     * Immediately blocks the old partition. If revocation cannot complete, only a protected,
     * pending record remains and a later initialization retries it without exposing old content.
     */
    public suspend fun logout(): LogoutOutcome = operationMutex.withLock {
        val stored = loadProtectedSession() ?: return@withLock LogoutOutcome.AlreadyAnonymous
        val registry = pushRegistry
        if (stored.logoutPending && registry?.hasPendingUnregister(stored.ownerScopeId) == true) {
            if (registry.requiresFreshBearer(stored.ownerScopeId) && registry.needsFreshBearerNow(stored.ownerScopeId)) {
                resumeForPendingPushUnlink(stored)
                return@withLock if (state.value.phase == OnloPhase.LOGOUT_PENDING) LogoutOutcome.Pending("push_unlink_pending") else LogoutOutcome.Completed
            }
            val authority = blockedOwnerAuthority(stored)
            if (authority != null) {
                val outcome = registry.reconcileUnregister(authority, freshBearer = false)
                if (outcome !is PushRegistrationOutcome.Unregistered && outcome !is PushRegistrationOutcome.NoToken) {
                    return@withLock LogoutOutcome.Pending("push_unlink_pending")
                }
            } else return@withLock LogoutOutcome.Pending("push_unlink_pending")
        }
        logoutLocked(stored)
    }

    /** Optional-FCM adapter entry point. APNs is rejected on Android and tokens are never logged. */
    public suspend fun registerPushToken(
        provider: ai.onlo.sdk.protocol.PushProvider,
        token: String,
        notificationPreference: ai.onlo.sdk.protocol.NotificationPreference? = null,
        locale: String? = null,
    ): PushRegistrationOutcome = operationMutex.withLock {
        val registry = pushRegistry ?: return@withLock PushRegistrationOutcome.NoActiveSession
        registry.register(currentPushAuthority(), provider, token, notificationPreference, locale)
    }

    /** FCM services pass their data map here; this emits no intent until the transcript authorises it. */
    public suspend fun handlePushPayload(payload: Map<String, String>): PushPayloadOutcome {
        val capture = operationMutex.withLock {
            val registry = pushRegistry ?: return PushPayloadOutcome.NotOnlo
            PushPayloadCapture(registry, currentPushAuthority())
        }
        return capture.registry.handlePayload(payload, capture.authority, { authority, conversationId, messageId ->
            val api = widgetChatApi ?: return@handlePayload false
            val expectedSessionId = operationMutex.withLock {
                inMemorySession?.takeIf { currentPushAuthority() == authority }?.sessionId
            } ?: return@handlePayload false
            val transcript = TranscriptConvergence(api, outboxStore).fetchAfterFullSync(authority.owner, authority.chatToken, conversationId, null, expectedSessionId)
            transcript.messages.any { it.id == messageId }
        }) { authority -> operationMutex.withLock { currentPushAuthority() == authority } }
    }

    /** Refetches with current bearer authority before allowing a targeted native presentation. */
    public suspend fun openConversation(conversationId: String): OpenConversationOutcome {
        if (conversationId.isBlank()) return OpenConversationOutcome.NotAuthorised
        val capture = operationMutex.withLock {
            val session = inMemorySession ?: return@withLock null
            val protected = protectedSession ?: return@withLock null
            val api = widgetChatApi ?: return@withLock null
            if (protected.logoutPending) null else ConversationOpenAuthority(protected, session.sessionId, session.chatToken, api)
        } ?: return OpenConversationOutcome.NoActiveSession
        try {
            TranscriptConvergence(capture.api, outboxStore).fetchAfterFullSync(capture.session.ownerScope(), capture.chatToken, conversationId, null, capture.sessionId)
            return operationMutex.withLock {
                if (protectedSession != capture.session || inMemorySession?.chatToken != capture.chatToken || inMemorySession?.sessionId != capture.sessionId || capture.session.logoutPending) OpenConversationOutcome.NoActiveSession
                else {
                    mutablePresentationTarget.value = MessengerPresentationTarget.Conversation(conversationId)
                    mutablePresentation.value = MessengerPresentationIntent.PRESENT
                    OpenConversationOutcome.Opened
                }
            }
        } catch (_: IOException) { OpenConversationOutcome.Unavailable }
        catch (_: ProtocolViolation) { OpenConversationOutcome.NotAuthorised }
        catch (_: ai.onlo.sdk.storage.OwnerBlockedException) { OpenConversationOutcome.NoActiveSession }
    }

    /** SDK messenger-only inbox fetch. The list route is contract-backed and bearer-authorised. */
    internal suspend fun loadMessengerInbox(): MessengerInboxResult {
        val capture = operationMutex.withLock {
            val session = inMemorySession ?: return@withLock null
            val protected = protectedSession ?: return@withLock null
            val api = widgetChatApi ?: return@withLock null
            if (protected.logoutPending) null else ConversationOpenAuthority(protected, session.sessionId, session.chatToken, api)
        } ?: return MessengerInboxResult.NoActiveSession
        return try {
            val conversations = capture.api.conversations(capture.chatToken, capture.sessionId)
            operationMutex.withLock {
                if (!matchesMessengerAuthority(capture)) MessengerInboxResult.NoActiveSession
                else {
                    publishUnreadCount(conversations)
                    MessengerInboxResult.Ready(conversations)
                }
            }
        } catch (_: IOException) { MessengerInboxResult.Unavailable }
        catch (_: ProtocolViolation) { MessengerInboxResult.Unavailable }
    }

    /** SDK messenger-only transcript refresh. It never returns a result for a retired account. */
    internal suspend fun loadMessengerTranscript(conversationId: String): MessengerTranscriptResult {
        if (conversationId.isBlank()) return MessengerTranscriptResult.NotAuthorised
        val capture = operationMutex.withLock {
            val session = inMemorySession ?: return@withLock null
            val protected = protectedSession ?: return@withLock null
            val api = widgetChatApi ?: return@withLock null
            if (protected.logoutPending) null else ConversationOpenAuthority(protected, session.sessionId, session.chatToken, api)
        } ?: return MessengerTranscriptResult.NoActiveSession
        val convergence = TranscriptConvergence(capture.api, outboxStore)
        return try {
            val transcript = convergence.fetchAfterFullSync(
                capture.session.ownerScope(), capture.chatToken, conversationId, null, capture.sessionId,
            )
            operationMutex.withLock {
                if (!matchesMessengerAuthority(capture)) MessengerTranscriptResult.NoActiveSession
                else MessengerTranscriptResult.Ready(transcript)
            }
        } catch (_: IOException) {
            val cached = runCatching { convergence.cached(capture.session.ownerScope(), conversationId, capture.sessionId) }.getOrNull()
            operationMutex.withLock {
                if (!matchesMessengerAuthority(capture)) MessengerTranscriptResult.NoActiveSession
                else cached?.let(MessengerTranscriptResult::Stale) ?: MessengerTranscriptResult.Unavailable
            }
        }
        catch (_: ProtocolViolation) { MessengerTranscriptResult.NotAuthorised }
        catch (_: ai.onlo.sdk.storage.OwnerBlockedException) { MessengerTranscriptResult.NoActiveSession }
    }

    private suspend fun logoutLocked(
        stored: ProtectedSession,
        allowRetryablePending: Boolean = true,
    ): LogoutOutcome {
        val pending = when (val existing = pendingTransition) {
            null -> PendingSessionTransition.Logout(
                installationId = stored.installationId,
                transitionId = newUuid(),
                expectedGeneration = stored.generation,
                presentedCredential = stored.credential,
                proposedCredential = newCredential(),
            )
            is PendingSessionTransition.Logout -> existing
            else -> throw OnloException.PendingTransitionUnavailable
        }
        requirePendingMatchesStoredSession(pending, stored)
        if (!allowRetryablePending && pending.retryDirective != null) {
            mutableState.value = OnloState(OnloPhase.LOGOUT_PENDING, OnloIdentityState.UNKNOWN, "logout_pending")
            return LogoutOutcome.Pending("logout_pending")
        }
        requireRetryPrerequisite(pending, hostSuppliedJwt = false)
        val oldOwner = stored.ownerScope()
        val oldPushAuthority = currentPushAuthority()
        outboxStore.blockOwner(oldOwner)
        resetUnreadCount()
        mutablePresentation.value = MessengerPresentationIntent.HIDDEN
        mutablePresentationTarget.value = MessengerPresentationTarget.Inbox
        invalidateConfigSession()
        val blocked = stored.copy(logoutPending = true)
        // This must be durable before unregister can suspend: server Logout is still unsent.
        persist(blocked, pending)
        mutableState.value = OnloState(OnloPhase.LOGOUT_PENDING, OnloIdentityState.UNKNOWN)
        val pushOutcome = pushRegistry?.retireOwner(oldPushAuthority)
        if (pushOutcome != null && pushOutcome !is PushRegistrationOutcome.Unregistered && pushOutcome !is PushRegistrationOutcome.NoToken) {
            // Never discard the only old-session bearer while unlink remains uncertain.
            mutableState.value = OnloState(OnloPhase.LOGOUT_PENDING, OnloIdentityState.UNKNOWN, "push_unlink_pending")
            return LogoutOutcome.Pending("push_unlink_pending")
        }
        inMemorySession = null

        try {
            val result = exchange(pending.toOperation(), pending.installationId)
            if (result.identityClass != IdentityClass.ANONYMOUS) throw OnloException.InvalidProtocol
            outboxStore.purgeOwner(oldOwner)
            applySession(result, ownerScopeId = newOpaqueOwnerScopeId())
            LogoutOutcome.Completed
        } catch (failure: Throwable) {
            if (failure is CancellationException) throw failure
            val safeCode = failure.safeCodeOr("logout_pending")
            logger.log(SafeLogEvent(SafeLogCode.LOGOUT_PENDING, configuration.sdkVersion))
            mutableState.value = OnloState(OnloPhase.LOGOUT_PENDING, OnloIdentityState.UNKNOWN, safeCode)
            LogoutOutcome.Pending(safeCode)
        }
    }

    /** Requests native messenger presentation; a Compose/View adapter observes this intent. */
    public fun present() {
        check(state.value.phase in setOf(OnloPhase.ANONYMOUS_READY, OnloPhase.IDENTIFIED_READY)) {
            "onlo_not_ready"
        }
        mutablePresentationTarget.value = MessengerPresentationTarget.Inbox
        mutablePresentation.value = MessengerPresentationIntent.PRESENT
    }

    public fun dismiss() {
        mutablePresentation.value = MessengerPresentationIntent.HIDDEN
    }

    /** Native UI-only text composer. v1 has no conversation target, so ordering is owner-global. */
    internal suspend fun sendTextFromNativeUi(message: String): String = operationMutex.withLock {
        require(message.isNotBlank()) { "message" }
        val session = checkNotNull(inMemorySession) { "onlo_not_ready" }
        val stored = checkNotNull(protectedSession) { "onlo_not_ready" }
        val owner = stored.ownerScope()
        val outbox = checkNotNull(widgetChatApi) { "chat_unavailable" }
        val durable = DurableChatOutbox(
            outboxStore,
            outbox,
            nowMs,
            onDuplicateAccepted = { conversationId ->
                // Duplicate acknowledgement is durable but may have lost the original stream.
                TranscriptConvergence(outbox, outboxStore).fetchAfterFullSync(owner, session.chatToken, conversationId, null, session.sessionId)
            },
        )
        // ChatRequest has no conversation target in v1; this constant only scopes local FIFO storage.
        val entry = durable.enqueue(owner, "v1-owner-global", message)
        val version = configSessionVersion
        chatFlushJob?.cancel()
        chatFlushJob = scope.launch {
            if (version != configSessionVersion || protectedSession?.ownerScope() != owner) return@launch
            durable.flush(owner, session.sessionId, session.chatToken)
        }
        entry.clientMessageId
    }

    private suspend fun restoreOrBootstrap() = operationMutex.withLock {
        val stored = loadProtectedSession()
        if (stored?.logoutPending == true) {
            if (pushRegistry?.needsFreshBearerNow(stored.ownerScopeId) == true) {
                resumeForPendingPushUnlink(stored)
            } else if (pushRegistry?.hasPendingUnregister(stored.ownerScopeId) == true) {
                mutableState.value = OnloState(OnloPhase.LOGOUT_PENDING, OnloIdentityState.UNKNOWN, "push_unlink_pending")
            } else {
                logoutLocked(stored, allowRetryablePending = false)
            }
        } else {
            restoreOrBootstrapLocked(stored, allowRetryablePending = false)
        }
    }

    /** The prior Logout was never sent: push unlink returned before its session exchange. */
    private suspend fun resumeForPendingPushUnlink(stored: ProtectedSession) {
        val resume = PendingSessionTransition.Resume(
            installationId = stored.installationId, transitionId = newUuid(), expectedGeneration = stored.generation,
            presentedCredential = stored.credential, proposedCredential = newCredential(),
        )
        persist(stored, resume)
        val result = exchange(resume.toOperation(), resume.installationId)
        if (result.identityClass != stored.identityClass) throw OnloException.InvalidProtocol
        val rotated = stored.copy(credential = result.proposedCredential, generation = result.generation, logoutPending = true)
        // The Resume is complete; only the protected pending-unlink record proves recovery work.
        persist(rotated, null)
        protectedSession = rotated
        inMemorySession = InMemorySession(result.sessionId, result.chatToken)
        val outcome = checkNotNull(pushRegistry).reconcileUnregister(PushAuthority(rotated.ownerScope(), result.chatToken), freshBearer = true)
        if (outcome !is PushRegistrationOutcome.Unregistered && outcome !is PushRegistrationOutcome.NoToken) {
            mutableState.value = OnloState(OnloPhase.LOGOUT_PENDING, OnloIdentityState.UNKNOWN, "push_unlink_pending")
            return
        }
        // The old bearer has performed its only allowed task. Create a fresh Logout transition.
        logoutLocked(rotated, allowRetryablePending = false)
    }

    private suspend fun restoreOrBootstrapLocked(
        stored: ProtectedSession?,
        allowRetryablePending: Boolean = true,
        refreshConfigAfterSession: Boolean = true,
    ) {
        mutableState.value = OnloState(OnloPhase.RESTORING, stored.identityClassOrUnknown())
        val pending = pendingTransition ?: if (stored == null) {
            PendingSessionTransition.Bootstrap(newUuid(), newUuid(), newCredential())
        } else {
            PendingSessionTransition.Resume(
                installationId = stored.installationId,
                transitionId = newUuid(),
                expectedGeneration = stored.generation,
                presentedCredential = stored.credential,
                proposedCredential = newCredential(),
            )
        }
        if (pending is PendingSessionTransition.Identify || pending is PendingSessionTransition.Logout) {
            throw OnloException.PendingTransitionUnavailable
        }
        requirePendingMatchesStoredSession(pending, stored)
        if (!allowRetryablePending && pending.retryDirective != null) {
            throw OnloException.PendingTransitionUnavailable
        }
        requireRetryPrerequisite(pending, hostSuppliedJwt = false)
        persist(stored, pending)
        val result = exchange(pending.toOperation(), pending.installationId)
        val ownerScopeId = when {
            stored == null -> newOpaqueOwnerScopeId()
            stored.identityClass == result.identityClass -> stored.ownerScopeId
            else -> newOpaqueOwnerScopeId()
        }
        if (stored != null && stored.identityClass != result.identityClass) {
            outboxStore.blockOwner(stored.ownerScope())
            outboxStore.purgeOwner(stored.ownerScope())
            resetUnreadCount()
        }
        applySession(result, ownerScopeId = ownerScopeId, refreshConfigAfterSession = refreshConfigAfterSession)
    }

    private suspend fun applySession(
        result: SessionResult,
        ownerScopeId: String,
        refreshConfigAfterSession: Boolean = true,
    ) {
        val next = ProtectedSession(
            installationId = result.installationId,
            credential = result.proposedCredential,
            generation = result.generation,
            ownerScopeId = ownerScopeId,
            identityClass = result.identityClass,
            logoutPending = false,
        )
        persist(next, null)
        inMemorySession = InMemorySession(result.sessionId, result.chatToken)
        outboxStore.recoverInterruptedSends(next.ownerScope(), nowMs())
        invalidateConfigSession()
        if (refreshConfigAfterSession) scheduleConfigRefresh(result.chatToken, configSessionVersion)
        mutableState.value = when (result.identityClass) {
            IdentityClass.ANONYMOUS -> OnloState(OnloPhase.ANONYMOUS_READY, OnloIdentityState.ANONYMOUS)
            IdentityClass.IDENTIFIED -> OnloState(OnloPhase.IDENTIFIED_READY, OnloIdentityState.IDENTIFIED)
        }
        scheduleUnreadRefresh(result.chatToken, result.sessionId, configSessionVersion, next.ownerScope())
    }

    /** Host lifecycle seam; a conditional refresh uses only the in-memory bearer token. */
    public fun onAppForeground() {
        scope.launch {
            val recovered = recoverOfflineSessionForLifecycle()
            if (recovered) startForegroundStreamFromLifecycle()
            else refreshConfigFromLifecycle()
            refreshUnreadFromLifecycle()
            dispatchDurableOutboxFromLifecycle()
            reconcilePushFromLifecycle()
            retryPendingLogoutFromLifecycle()
        }
    }
    /** Host lifecycle seam for an actual network recovery signal. */
    public fun onNetworkRecovered() { onAppForeground() }
    /** Foreground stream adapters call this after a server `config_changed` hint. */
    public fun onConfigChangedHint() { refreshConfigFromLifecycle() }

    /**
     * Replays only a persisted Bootstrap/Resume transition on recovery. An
     * Identify transition cannot be replayed without a new host JWT, and a
     * logout-pending owner remains blocked for its dedicated unlink flow.
    */
    internal suspend fun recoverOfflineSessionForLifecycle(): Boolean = operationMutex.withLock {
        if (state.value.phase !in setOf(OnloPhase.OFFLINE_READY, OnloPhase.RESTORING)) return@withLock false
        val stored = loadProtectedSession()
        if (stored?.logoutPending == true) return@withLock false
        if (pendingTransition is PendingSessionTransition.Identify) {
            mutableState.value = OnloState(OnloPhase.REAUTHENTICATION_REQUIRED, OnloIdentityState.UNKNOWN, "identity_retry_required")
            return@withLock false
        }
        try {
            restoreOrBootstrapLocked(stored)
            state.value.phase in setOf(OnloPhase.ANONYMOUS_READY, OnloPhase.IDENTIFIED_READY)
        } catch (failure: CancellationException) {
            throw failure
        } catch (failure: Throwable) {
            publishFailure(failure, phaseForCurrentScope())
            false
        }
    }

    /** Session replay already schedules config refresh; only attach the stream here. */
    private fun startForegroundStreamFromLifecycle() {
        scope.launch {
            val capture = operationMutex.withLock {
                val protected = protectedSession
                if (protected == null || protected.logoutPending) null
                else inMemorySession?.chatToken?.let { token -> token to configSessionVersion }
            } ?: return@launch
            startForegroundStream(capture.first, capture.second)
        }
    }

    private fun refreshConfigFromLifecycle() {
        if (configController == null) return
        scope.launch {
            val capture = operationMutex.withLock {
                val protected = protectedSession
                if (protected == null || protected.logoutPending || state.value.phase !in setOf(OnloPhase.ANONYMOUS_READY, OnloPhase.IDENTIFIED_READY)) null
                else inMemorySession?.chatToken?.let { token -> token to configSessionVersion }
            } ?: return@launch
            refreshConfigWithSessionRecovery(capture.first, capture.second)
            val refreshed = operationMutex.withLock {
                inMemorySession?.chatToken?.let { token -> token to configSessionVersion }
            } ?: return@launch
            startForegroundStream(refreshed.first, refreshed.second)
        }
    }

    private fun reconcilePushFromLifecycle() {
        val registry = pushRegistry ?: return
        scope.launch {
            val authority = operationMutex.withLock { currentPushAuthority() }
            registry.reconcileEligible(authority)
        }
    }

    /** Replays only the current unblocked owner's already-persisted work. */
    private fun dispatchDurableOutboxFromLifecycle() {
        val api = widgetChatApi ?: return
        scope.launch {
            val capture = operationMutex.withLock {
                val stored = protectedSession
                val session = inMemorySession
                if (stored == null || stored.logoutPending || session == null ||
                    state.value.phase !in setOf(OnloPhase.ANONYMOUS_READY, OnloPhase.IDENTIFIED_READY)
                ) null else Triple(stored.ownerScope(), session, configSessionVersion)
            } ?: return@launch
            val outbox = DurableChatOutbox(
                outboxStore,
                api,
                nowMs,
                onDuplicateAccepted = { conversationId ->
                    TranscriptConvergence(api, outboxStore).fetchAfterFullSync(
                        capture.first,
                        capture.second.chatToken,
                        conversationId,
                        null,
                        capture.second.sessionId,
                    )
                },
            )
            if (operationMutex.withLock {
                    protectedSession?.ownerScope() == capture.first &&
                        configSessionVersion == capture.third &&
                        protectedSession?.logoutPending == false
                }
            ) {
                outboxStore.recoverInterruptedSends(capture.first, nowMs())
                outbox.flush(capture.first, capture.second.sessionId, capture.second.chatToken)
            }
        }
    }

    private fun retryPendingLogoutFromLifecycle() {
        if (state.value.phase != OnloPhase.LOGOUT_PENDING) return
        scope.launch { logout() }
    }

    private fun startForegroundStream(token: String, version: Long) {
        if (foregroundJob?.isActive == true) return
        val stream = foregroundStream ?: return
        foregroundJob = scope.launch {
            try {
                stream.collect(token) { hint ->
                    val authority = foregroundAuthority(token, version)
                        ?: throw CancellationException("stale_foreground_stream")
                    when (hint) {
                        ForegroundHint.Ready -> Unit
                        is ForegroundHint.ConfigChanged -> refreshConfigWithSessionRecovery(authority.token, authority.version)
                        is ForegroundHint.Conversation -> {
                            convergeHintTranscript(hint.conversationId, authority)
                            refreshUnreadCount(authority)
                        }
                        is ForegroundHint.Message -> {
                            convergeHintTranscript(hint.conversationId, authority)
                            refreshUnreadCount(authority)
                        }
                    }
                }
            } catch (failure: CancellationException) {
                throw failure
            } catch (_: IOException) {
                // Foreground hints are best effort; lifecycle/network recovery starts a new stream.
            }
        }
    }

    /** Captured under the lifecycle lock so a retiring account cannot authorise a stale hint. */
    private suspend fun foregroundAuthority(token: String, version: Long): ForegroundAuthority? = operationMutex.withLock {
        val session = inMemorySession ?: return@withLock null
        val protected = protectedSession ?: return@withLock null
        if (version != configSessionVersion || session.chatToken != token || protected.logoutPending) return@withLock null
        ForegroundAuthority(session.chatToken, session.sessionId, version, protected.ownerScope())
    }

    private fun currentPushAuthority(): PushAuthority? {
        val protected = protectedSession ?: return null
        val session = inMemorySession ?: return null
        if (protected.logoutPending) return null
        return PushAuthority(protected.ownerScope(), session.chatToken)
    }

    private fun matchesMessengerAuthority(capture: ConversationOpenAuthority): Boolean =
        protectedSession == capture.session &&
            inMemorySession?.chatToken == capture.chatToken &&
            inMemorySession?.sessionId == capture.sessionId &&
            !capture.session.logoutPending

    private fun matchesForegroundAuthority(capture: ForegroundAuthority): Boolean {
        val session = inMemorySession ?: return false
        val protected = protectedSession ?: return false
        return configSessionVersion == capture.version &&
            session.chatToken == capture.token &&
            session.sessionId == capture.sessionId &&
            protected.ownerScope() == capture.owner &&
            !protected.logoutPending
    }

    /** Refetch hints do not carry unread state; derive it from the authorised canonical list. */
    private suspend fun refreshUnreadCount(authority: ForegroundAuthority) {
        val api = widgetChatApi ?: return
        try {
            val conversations = api.conversations(authority.token, authority.sessionId)
            operationMutex.withLock {
                if (matchesForegroundAuthority(authority)) publishUnreadCount(conversations)
            }
        } catch (failure: CancellationException) {
            throw failure
        } catch (_: IOException) {
            // A later foreground/network recovery will retry this refetch hint.
        } catch (_: ProtocolViolation) {
            // Invalid or cross-session list data is never published.
        }
    }

    private fun publishUnreadCount(conversations: List<ConversationSummary>) {
        mutableUnreadCount.value = totalUnreadCount(conversations)
    }

    private fun resetUnreadCount() {
        mutableUnreadCount.value = null
    }

    private fun scheduleUnreadRefresh(token: String, sessionId: String, version: Long, owner: OwnerScope) {
        scope.launch { refreshUnreadCount(ForegroundAuthority(token, sessionId, version, owner)) }
    }

    /** Lifecycle refresh remains best effort and does not delay session readiness. */
    private fun refreshUnreadFromLifecycle() {
        scope.launch {
            val authority = operationMutex.withLock {
                val session = inMemorySession ?: return@withLock null
                val protected = protectedSession ?: return@withLock null
                if (protected.logoutPending) null else ForegroundAuthority(
                    session.chatToken, session.sessionId, configSessionVersion, protected.ownerScope(),
                )
            } ?: return@launch
            refreshUnreadCount(authority)
        }
    }

    /** Only logout recovery may use this retained bearer; ordinary APIs remain blocked by logoutPending. */
    private fun blockedOwnerAuthority(stored: ProtectedSession): PushAuthority? {
        val session = inMemorySession ?: return null
        val current = protectedSession ?: return null
        if (!current.logoutPending || current.ownerScopeId != stored.ownerScopeId) return null
        return PushAuthority(stored.ownerScope(), session.chatToken)
    }

    private suspend fun convergeHintTranscript(conversationId: String, authority: ForegroundAuthority) {
        val api = widgetChatApi ?: return
        try {
            TranscriptConvergence(api, outboxStore).fetchAfterFullSync(authority.owner, authority.token, conversationId, null, authority.sessionId)
        } catch (failure: CancellationException) {
            throw failure
        } catch (_: IOException) {
            // Hint convergence is best effort; later hints/lifecycle recovery retry it.
        } catch (_: ProtocolViolation) {
            // A malformed widget payload is not authority and is never persisted.
        } catch (_: ai.onlo.sdk.storage.OwnerBlockedException) {
            // The account boundary won the race; the retiring partition stays inaccessible.
        }
    }

    /** This job waits for any current session mutation before it starts network work. */
    private fun scheduleConfigRefresh(token: String, version: Long) {
        if (configController == null) return
        scope.launch { refreshConfigWithSessionRecovery(token, version) }
    }

    private suspend fun refreshConfigWithSessionRecovery(token: String, version: Long) {
        val controller = configController ?: return
        if (controller.refresh(token, version) is ai.onlo.sdk.config.ConfigRefreshResult.ReauthenticationRequired) {
            refreshConfigAfterTokenRefresh(version)
        }
    }

    /** One bearer-session refresh and one config retry; no Operator JWT is involved. */
    private suspend fun refreshConfigAfterTokenRefresh(version: Long) = operationMutex.withLock {
        if (version != configSessionVersion) return@withLock
        val stored = loadProtectedSession() ?: return@withLock
        if (stored.logoutPending) return@withLock
        restoreOrBootstrapLocked(stored, refreshConfigAfterSession = false)
        val token = inMemorySession?.chatToken ?: return@withLock
        configController?.refresh(token, configSessionVersion, allowTokenRefresh = false)
    }

    private suspend fun invalidateConfigSession() {
        chatFlushJob?.cancel(); chatFlushJob = null
        foregroundJob?.cancel(); foregroundJob = null
        configSessionVersion = configController?.onSessionBoundary() ?: (configSessionVersion + 1)
    }

    private suspend fun loadProtectedSession(): ProtectedSession? = when (val loaded = credentialStore.load()) {
        CredentialLoad.Empty -> {
            protectedSession = null
            pendingTransition = null
            resetUnreadCount()
            null
        }
        is CredentialLoad.Found -> loaded.state.session.also {
            protectedSession = it
            pendingTransition = loaded.state.pendingTransition
        }
        CredentialLoad.Invalidated -> {
            invalidateConfigSession()
            inMemorySession = null
            protectedSession = null
            pendingTransition = null
            resetUnreadCount()
            outboxStore.clearAll()
            logger.log(SafeLogEvent(SafeLogCode.CREDENTIAL_INVALIDATED, configuration.sdkVersion))
            null
        }
    }

    private suspend fun exchange(operation: SessionOperation, installationId: String): SessionResult {
        val startedAt = nowMs()
        try {
            val envelope = sessionApi.exchange(
                SessionRequest(
                    sdkKey = configuration.sdkKey,
                    appIdentifier = configuration.appIdentifier,
                    client = SdkClientDescriptor(
                        protocolVersion = PROTOCOL_VERSION,
                        installationId = installationId,
                        sdkVersion = configuration.sdkVersion,
                        sdkFamily = configuration.sdkFamily,
                        appVersion = configuration.appVersion,
                        appBuild = configuration.appBuild,
                        capabilities = configuration.capabilities,
                    ),
                    operation = operation,
                ),
            )
            return when (envelope) {
                is ApiSuccess -> {
                    logger.log(
                        SafeLogEvent(
                            SafeLogCode.SESSION_EXCHANGE_SUCCEEDED,
                            configuration.sdkVersion,
                            requestId = envelope.requestId,
                            durationMs = nowMs() - startedAt,
                        ),
                    )
                    envelope.result.also { result ->
                        if (result.proposedCredential != operation.proposedCredential) throw OnloException.InvalidProtocol
                    }
                }

                is ApiFailure -> {
                    logger.log(
                        SafeLogEvent(
                            SafeLogCode.SESSION_EXCHANGE_FAILED,
                            configuration.sdkVersion,
                            requestId = envelope.requestId,
                            durationMs = nowMs() - startedAt,
                        ),
                    )
                    resolveDefinitiveFailure(operation, envelope.error.retry)
                    throw OnloException.Server(envelope.error.code.wireValue, envelope.error.retry.directive)
                }
            }
        } catch (failure: Throwable) {
            if (failure is CancellationException) throw failure
            if (failure is OnloException) throw failure
            if (failure is ProtocolViolation) {
                logger.log(SafeLogEvent(SafeLogCode.PROTOCOL_REJECTED, configuration.sdkVersion))
                throw OnloException.InvalidProtocol
            }
            if (failure is IOException) throw OnloException.Unavailable
            throw OnloException.Unavailable
        }
    }

    private fun publishFailure(failure: Throwable, phase: OnloPhase) {
        if (failure is CancellationException) throw failure
        mutableState.value = OnloState(phase, protectedSession.identityState(), failure.safeCodeOr("initialization_failed"))
    }

    private fun phaseForCurrentScope(): OnloPhase = when {
        pendingTransition is PendingSessionTransition.Identify -> OnloPhase.REAUTHENTICATION_REQUIRED
        else -> when (protectedSession?.identityClass) {
        IdentityClass.IDENTIFIED -> OnloPhase.REAUTHENTICATION_REQUIRED
        IdentityClass.ANONYMOUS, null -> OnloPhase.OFFLINE_READY
        }
    }

    private fun validateCompactJwt(value: String) {
        val parts = value.split('.')
        if (parts.size != 3 || parts.any { it.isEmpty() || it.any(Char::isWhitespace) }) {
            throw OnloException.InvalidUserJwt
        }
    }

    private fun ProtectedSession.ownerScope(): OwnerScope = when (identityClass) {
        IdentityClass.ANONYMOUS -> OwnerScope.Anonymous(ownerScopeId)
        IdentityClass.IDENTIFIED -> OwnerScope.Identified(ownerScopeId)
    }

    private fun ProtectedSession?.identityState(): OnloIdentityState = when (this?.identityClass) {
        IdentityClass.ANONYMOUS -> OnloIdentityState.ANONYMOUS
        IdentityClass.IDENTIFIED -> OnloIdentityState.IDENTIFIED
        null -> OnloIdentityState.UNKNOWN
    }

    private fun ProtectedSession?.identityClassOrUnknown(): OnloIdentityState = identityState()

    private fun Throwable.safeCodeOr(fallback: String): String = (this as? OnloException)?.safeCode ?: fallback

    private suspend fun identifyWithPending(
        stored: ProtectedSession,
        pending: PendingSessionTransition.Identify,
        userJwt: String,
    ): OnloState {
        if (stored.identityClass != IdentityClass.ANONYMOUS || stored.logoutPending) {
            throw OnloException.PendingTransitionUnavailable
        }
        requirePendingMatchesStoredSession(pending, stored)
        requireRetryPrerequisite(pending, hostSuppliedJwt = true)
        mutableState.value = OnloState(OnloPhase.IDENTIFYING, OnloIdentityState.ANONYMOUS)
        resetUnreadCount()
        // Persist the non-secret operation before retiring local anonymous data. If the response is
        // lost, only a subsequent host-supplied JWT can replay these exact wire fields.
        persist(stored, pending)
        invalidateConfigSession()
        inMemorySession = null
        outboxStore.blockAndPurgeOwner(stored.ownerScope())
        try {
            val result = exchange(pending.toOperation(userJwt), pending.installationId)
            if (result.identityClass != IdentityClass.IDENTIFIED) throw OnloException.InvalidProtocol
            applySession(result, ownerScopeId = newOpaqueOwnerScopeId())
            return state.value
        } catch (failure: Throwable) {
            if (failure is CancellationException) throw failure
            mutableState.value = OnloState(
                OnloPhase.REAUTHENTICATION_REQUIRED,
                OnloIdentityState.ANONYMOUS,
                failure.safeCodeOr("identity_exchange_failed"),
            )
            throw failure
        }
    }

    private suspend fun persist(session: ProtectedSession?, pending: PendingSessionTransition?) {
        if (session == null && pending == null) {
            credentialStore.clear()
        } else {
            credentialStore.save(ProtectedSessionState(session, pending))
        }
        protectedSession = session
        pendingTransition = pending
    }

    /** Reject corrupt or stale logical state before it can issue a credential-bearing request. */
    private fun requirePendingMatchesStoredSession(
        pending: PendingSessionTransition,
        stored: ProtectedSession?,
    ) {
        when (pending) {
            is PendingSessionTransition.Bootstrap -> if (stored != null) throw OnloException.PendingTransitionUnavailable
            is PendingSessionTransition.Resume -> requirePendingSessionFields(pending, stored)
            is PendingSessionTransition.Identify -> requirePendingSessionFields(pending, stored)
            is PendingSessionTransition.Logout -> requirePendingSessionFields(pending, stored)
        }
    }

    private fun requirePendingSessionFields(
        pending: PendingSessionTransition,
        stored: ProtectedSession?,
    ) {
        if (stored == null || pending.installationId != stored.installationId) {
            throw OnloException.PendingTransitionUnavailable
        }
        val expectedGeneration: Long
        val presentedCredential: String
        when (pending) {
            is PendingSessionTransition.Resume -> {
                expectedGeneration = pending.expectedGeneration
                presentedCredential = pending.presentedCredential
            }
            is PendingSessionTransition.Identify -> {
                expectedGeneration = pending.expectedGeneration
                presentedCredential = pending.presentedCredential
            }
            is PendingSessionTransition.Logout -> {
                expectedGeneration = pending.expectedGeneration
                presentedCredential = pending.presentedCredential
            }
            is PendingSessionTransition.Bootstrap -> throw OnloException.PendingTransitionUnavailable
        }
        if (expectedGeneration != stored.generation || presentedCredential != stored.credential) {
            throw OnloException.PendingTransitionUnavailable
        }
    }

    /** A decoded envelope is definitive; only contract-authorised session retries are retained. */
    private suspend fun resolveDefinitiveFailure(operation: SessionOperation, retry: ApiRetry) {
        val pending = pendingTransition ?: return
        if (pending.transitionId != operation.transitionId) return
        when (retry.directive) {
            RetryDirective.NEVER,
            RetryDirective.AFTER_FULL_SYNC,
            -> persist(protectedSession, null)
            RetryDirective.AFTER_TOKEN_REFRESH,
            RetryDirective.AFTER_ATTESTATION,
            RetryDirective.AFTER_BACKOFF,
            -> persist(protectedSession, pending.withRetryMetadata(retry.directive, retry.retryAfterMs))
        }
    }

    private fun PendingSessionTransition.withRetryMetadata(
        directive: RetryDirective,
        retryAfterMs: Long?,
    ): PendingSessionTransition {
        val nextAttempt = if (directive == RetryDirective.AFTER_BACKOFF) retryAttempt.coerceAtMost(Int.MAX_VALUE - 1) + 1 else 0
        val eligibleAt = retryEligibleAt(directive, retryAfterMs, retryAttempt)
        return when (this) {
            is PendingSessionTransition.Bootstrap -> copy(retryDirective = directive, retryEligibleAtMs = eligibleAt, retryAttempt = nextAttempt)
            is PendingSessionTransition.Resume -> copy(retryDirective = directive, retryEligibleAtMs = eligibleAt, retryAttempt = nextAttempt)
            is PendingSessionTransition.Identify -> copy(retryDirective = directive, retryEligibleAtMs = eligibleAt, retryAttempt = nextAttempt)
            is PendingSessionTransition.Logout -> copy(retryDirective = directive, retryEligibleAtMs = eligibleAt, retryAttempt = nextAttempt)
        }
    }

    private fun retryEligibleAt(directive: RetryDirective, retryAfterMs: Long?, attempt: Int): Long? {
        if (directive != RetryDirective.AFTER_BACKOFF) return null
        // A server-supplied value is authoritative. The fallback is capped exponential backoff
        // with bounded jitter, as permitted when retryAfterMs is absent.
        val delay = retryAfterMs ?: fallbackBackoffDelayMs(attempt)
        val current = nowMs()
        return if (Long.MAX_VALUE - current < delay) Long.MAX_VALUE else current + delay
    }

    private fun fallbackBackoffDelayMs(attempt: Int): Long {
        val exponent = attempt.coerceIn(0, MAX_BACKOFF_EXPONENT)
        val base = (DEFAULT_BACKOFF_MS shl exponent).coerceAtMost(MAX_BACKOFF_MS)
        val multiplier = 0.5 + (fallbackBackoffJitter().coerceIn(0.0, 1.0) * 0.5)
        return (base * multiplier).toLong().coerceIn(1L, MAX_BACKOFF_MS)
    }

    private fun requireRetryPrerequisite(
        pending: PendingSessionTransition,
        hostSuppliedJwt: Boolean,
    ) {
        when (pending.retryDirective) {
            null -> Unit
            RetryDirective.AFTER_BACKOFF -> if ((pending.retryEligibleAtMs ?: Long.MAX_VALUE) > nowMs()) {
                throw OnloException.PendingTransitionUnavailable
            }
            RetryDirective.AFTER_TOKEN_REFRESH -> if (pending !is PendingSessionTransition.Identify || !hostSuppliedJwt) {
                throw OnloException.PendingTransitionUnavailable
            }
            RetryDirective.AFTER_ATTESTATION -> throw OnloException.PendingTransitionUnavailable
            RetryDirective.NEVER,
            RetryDirective.AFTER_FULL_SYNC,
            -> throw OnloException.PendingTransitionUnavailable
        }
    }

    private fun PendingSessionTransition.toOperation(userJwt: String? = null): SessionOperation = when (this) {
        is PendingSessionTransition.Bootstrap -> SessionOperation.Bootstrap(transitionId, proposedCredential)
        is PendingSessionTransition.Resume -> SessionOperation.Resume(transitionId, expectedGeneration, presentedCredential, proposedCredential)
        is PendingSessionTransition.Identify -> SessionOperation.Identify(
            transitionId,
            expectedGeneration,
            presentedCredential,
            proposedCredential,
            userJwt ?: throw OnloException.IdentityRetryRequired,
        )
        is PendingSessionTransition.Logout -> SessionOperation.Logout(transitionId, expectedGeneration, presentedCredential, proposedCredential)
    }

    private data class InMemorySession(
        val sessionId: String,
        val chatToken: String,
    )

    private data class ConversationOpenAuthority(
        val session: ProtectedSession,
        val sessionId: String,
        val chatToken: String,
        val api: WidgetChatApi,
    )

    private data class PushPayloadCapture(
        val registry: PushRegistry,
        val authority: PushAuthority?,
    )

    private data class ForegroundAuthority(
        val token: String,
        val sessionId: String,
        val version: Long,
        val owner: OwnerScope,
    )

    private fun newUuid(): String = UUID.randomUUID().toString()

    private fun newOpaqueOwnerScopeId(): String = UUID.randomUUID().toString()

    private fun newCredential(): String = ByteArray(32).also(SecureRandom()::nextBytes).let {
        Base64.getUrlEncoder().withoutPadding().encodeToString(it)
    }

    private companion object {
        const val SDK_VERSION = "0.1.0"
        const val DEFAULT_BACKOFF_MS = 1_000L
        const val MAX_BACKOFF_MS = 30_000L
        const val MAX_BACKOFF_EXPONENT = 5
    }
}
