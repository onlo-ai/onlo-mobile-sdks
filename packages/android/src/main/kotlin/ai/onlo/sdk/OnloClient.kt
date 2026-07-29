package ai.onlo.sdk

import ai.onlo.sdk.logging.SafeLogCode
import ai.onlo.sdk.logging.SafeLogEvent
import ai.onlo.sdk.logging.SafeLogger
import ai.onlo.sdk.protocol.ApiFailure
import ai.onlo.sdk.protocol.ApiRetry
import ai.onlo.sdk.protocol.ApiSuccess
import ai.onlo.sdk.protocol.Capability
import ai.onlo.sdk.protocol.ChatAttachment
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
import ai.onlo.sdk.storage.PersistenceAuthority
import ai.onlo.sdk.storage.StagedAttachment
import ai.onlo.sdk.transport.OnloSessionApi
import ai.onlo.sdk.chat.DurableChatOutbox
import ai.onlo.sdk.chat.WidgetChatApi
import ai.onlo.sdk.chat.WidgetHttpFailure
import ai.onlo.sdk.chat.ConversationDetail
import ai.onlo.sdk.chat.ConversationList
import ai.onlo.sdk.chat.ConversationListCacheCodec
import ai.onlo.sdk.chat.ConversationSummary
import ai.onlo.sdk.chat.HelpCenterArticle
import ai.onlo.sdk.chat.HelpCenterTopic
import ai.onlo.sdk.chat.TranscriptConvergence
import ai.onlo.sdk.chat.ForegroundStream
import ai.onlo.sdk.chat.ForegroundHint
import ai.onlo.sdk.push.PushAuthority
import ai.onlo.sdk.push.PushPayloadOutcome
import ai.onlo.sdk.push.PushRegistrationOutcome
import ai.onlo.sdk.push.PushRegistry
import java.io.IOException
import java.io.File
import java.security.SecureRandom
import java.text.SimpleDateFormat
import java.util.Base64
import java.util.Locale
import java.util.TimeZone
import java.util.UUID
import kotlin.random.Random
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.delay
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withTimeoutOrNull
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import org.json.JSONObject

internal val SDK_VERSION: String = BuildConfig.ONLO_SDK_VERSION

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
        Capability.MEDIA_PICKER,
        Capability.ATTACHMENT_UPLOAD,
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
    /** Last authorised encrypted inbox index remains renderable while refresh is offline. */
    data class Stale(val conversations: List<ConversationSummary>) : MessengerInboxResult
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

internal sealed interface MessengerHelpCenterResult {
    data class Ready(val topics: List<HelpCenterTopic>) : MessengerHelpCenterResult
    data object NoActiveSession : MessengerHelpCenterResult
    data object Unavailable : MessengerHelpCenterResult
}

internal sealed interface MessengerHelpArticleResult {
    data class Ready(val article: HelpCenterArticle) : MessengerHelpArticleResult
    data object NoActiveSession : MessengerHelpArticleResult
    data object NotAuthorised : MessengerHelpArticleResult
    data object Unavailable : MessengerHelpArticleResult
}

/**
 * Native messenger rendering events. Message content remains inside the native SDK and is never
 * exposed by the React Native or Flutter bridges.
 */
internal sealed interface NativeMessengerEvent {
    val clientMessageId: String

    data class Accepted(
        override val clientMessageId: String,
        val conversationId: String,
        val duplicate: Boolean,
    ) : NativeMessengerEvent

    data class Text(
        override val clientMessageId: String,
        val content: String,
    ) : NativeMessengerEvent

    data class Done(
        override val clientMessageId: String,
        val conversationId: String,
    ) : NativeMessengerEvent

    data class Failed(
        override val clientMessageId: String,
        val retryable: Boolean,
        val safeCode: String,
    ) : NativeMessengerEvent
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
    private val retryDelay: suspend (Long) -> Unit = { delay(it) },
    private val acceptedReconciliationDelayMs: Long = 5_000L,
    private val acceptedReconciliationBeforeEmptyCommit: suspend () -> Unit = {},
    private val attachmentCacheDir: File? = null,
) {
    private val operationMutex = Mutex()
    private var protectedSession: ProtectedSession? = null
    private var pendingTransition: PendingSessionTransition? = null
    private var inMemorySession: InMemorySession? = null
    /** Memory-only greeting data, populated only after the server accepts the
     * corresponding identify transition and cleared before account teardown. */
    internal var identifiedFirstName: String? = null
        private set
    private var configSessionVersion = 0L
    private var restorationJob: Job? = null
    private var chatFlushJob: Job? = null
    private var chatFlushOwner: OwnerScope? = null
    private var chatFlushId: UUID? = null
    private var chatFlushWakeRequested = false
    private enum class AcceptedReconciliationPhase { STOPPED, STARTING, RUNNING, WAITING, EXITING }
    private data class AcceptedReconciliationScheduler(
        var phase: AcceptedReconciliationPhase = AcceptedReconciliationPhase.STOPPED,
        var owner: OwnerScope? = null,
        var sessionVersion: Long? = null,
        var ownershipToken: UUID? = null,
        var workGeneration: Long = 0,
        var job: Job? = null,
        var wake: CompletableDeferred<Unit>? = null,
        var startCount: Long = 0,
    )
    private val acceptedReconciliation = AcceptedReconciliationScheduler()
    private var foregroundJob: Job? = null
    private enum class ForegroundPhase { STOPPED, STARTING, RUNNING }
    private var foregroundPhase = ForegroundPhase.STOPPED
    private var foregroundOwnershipToken: UUID? = null
    private var foregroundOwner: OwnerScope? = null
    private var foregroundVersion: Long? = null
    private data class PendingPushRegistration(
        val provider: ai.onlo.sdk.protocol.PushProvider,
        val token: String,
        val notificationPreference: ai.onlo.sdk.protocol.NotificationPreference?,
        val locale: String?,
    )
    private var pendingPushRegistration: PendingPushRegistration? = null
    private var conversationObservationGeneration = 0L
    private data class MessengerInboxCache(
        val owner: OwnerScope,
        val sessionId: String,
        val bearerVersion: Long,
        val conversations: List<ConversationSummary>,
        val totalUnreadCount: Int,
    )
    private var messengerInboxCache: MessengerInboxCache? = null

    private val mutableState = MutableStateFlow(
        OnloState(OnloPhase.RESTORING, OnloIdentityState.UNKNOWN),
    )
    private val mutablePresentation = MutableStateFlow(MessengerPresentationIntent.HIDDEN)
    private val mutablePresentationTarget = MutableStateFlow<MessengerPresentationTarget>(MessengerPresentationTarget.Inbox)
    private val mutableUnreadCount = MutableStateFlow<Int?>(null)
    private val mutablePlatformConnected = MutableStateFlow(false)
    private val mutableMessengerEvents = MutableSharedFlow<NativeMessengerEvent>(
        extraBufferCapacity = 32,
    )

    public val state: StateFlow<OnloState> = mutableState.asStateFlow()
    public val presentationIntent: StateFlow<MessengerPresentationIntent> = mutablePresentation.asStateFlow()
    public val presentationTarget: StateFlow<MessengerPresentationTarget> = mutablePresentationTarget.asStateFlow()
    /** Identified-customer unread total; `null` clears badges for anonymous/boundary states. */
    public val unreadCount: StateFlow<Int?> = mutableUnreadCount.asStateFlow()
    /** Live Onlo reachability for SDK-owned chrome; it contains no host or customer data. */
    internal val platformConnected: StateFlow<Boolean> = mutablePlatformConnected.asStateFlow()
    internal val messengerEvents: SharedFlow<NativeMessengerEvent> = mutableMessengerEvents.asSharedFlow()
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
            return@withLock state.value
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
        if (stored.logoutPending && pendingTransition is PendingSessionTransition.Resume) {
            resumeForPendingLogout(stored)
            return@withLock if (state.value.phase == OnloPhase.LOGOUT_PENDING) {
                LogoutOutcome.Pending("logout_pending")
            } else LogoutOutcome.Completed
        }
        logoutLocked(stored)
    }

    /** Optional-FCM adapter entry point. APNs is rejected on Android and tokens are never logged. */
    public suspend fun registerPushToken(
        provider: ai.onlo.sdk.protocol.PushProvider,
        token: String,
        notificationPreference: ai.onlo.sdk.protocol.NotificationPreference? = null,
        locale: String? = null,
    ): PushRegistrationOutcome {
        val registrationAuthority = operationMutex.withLock {
            val registry = pushRegistry ?: return PushRegistrationOutcome.NoActiveSession
            if (provider != ai.onlo.sdk.protocol.PushProvider.FCM) {
                return PushRegistrationOutcome.UnsupportedProvider
            }
            if (token.isBlank()) return PushRegistrationOutcome.InvalidToken
            pendingPushRegistration = PendingPushRegistration(provider, token, notificationPreference, locale)
            val authority = currentPushAuthority()
                ?: return PushRegistrationOutcome.QueuedForReconciliation
            registry to authority
        }
        val (registry, authority) = registrationAuthority
        try {
            return registry.register(authority, provider, token, notificationPreference, locale)
        } catch (failure: CancellationException) {
            throw failure
        } catch (_: Throwable) {
            return PushRegistrationOutcome.TerminalServerFailure
        }
    }

    /** FCM services pass their data map here; this emits no intent until the transcript authorises it. */
    public suspend fun handlePushPayload(payload: Map<String, String>): PushPayloadOutcome {
        return try {
            val capture = operationMutex.withLock {
                val registry = pushRegistry ?: return PushPayloadOutcome.NotOnlo
                val authority = currentPushAuthority()
                val protected = protectedSession
                val session = inMemorySession
                val persistence = if (authority != null && protected != null && session != null) {
                    persistenceAuthority(authority.owner, protected, session, configSessionVersion)
                } else null
                PushPayloadCapture(registry, authority, persistence)
            }
            capture.registry.handlePayload(payload, capture.authority, { authority, conversationId, messageId ->
                val api = widgetChatApi ?: return@handlePayload false
                val persistenceAuthority = capture.persistenceAuthority ?: return@handlePayload false
                val expectedSessionId = persistenceAuthority.sessionId
                val convergence = TranscriptConvergence(api, outboxStore)
                val transcript = convergence.fetchAfterFullSync(
                    authority.owner,
                    authority.chatToken,
                    conversationId,
                    null,
                    expectedSessionId,
                    isAuthorised = { operationMutex.withLock { currentPushAuthority() == authority } },
                    commit = { value ->
                        outboxStore.replaceTranscriptIfAuthorised(
                            persistenceAuthority,
                            conversationId,
                            convergence.encodeTranscript(value),
                        )
                    },
                )
                transcript.messages.any { it.id == messageId }
            }) { authority -> operationMutex.withLock { currentPushAuthority() == authority } }
        } catch (failure: CancellationException) {
            throw failure
        } catch (_: Throwable) {
            PushPayloadOutcome.RefetchFailed
        }
    }

    /** Refetches with current bearer authority before allowing a targeted native presentation. */
    public suspend fun openConversation(conversationId: String): OpenConversationOutcome {
        if (conversationId.isBlank()) return OpenConversationOutcome.NotAuthorised
        val capture = operationMutex.withLock {
            val session = inMemorySession ?: return@withLock null
            val protected = protectedSession ?: return@withLock null
            val api = widgetChatApi ?: return@withLock null
            if (protected.logoutPending) null else ConversationOpenAuthority(protected, session.sessionId, session.chatToken, configSessionVersion, api)
        } ?: return OpenConversationOutcome.NoActiveSession
        return try {
            val convergence = TranscriptConvergence(capture.api, outboxStore)
            val persistenceAuthority = persistenceAuthority(capture)
            convergence.fetchAfterFullSync(
                capture.session.ownerScope(),
                capture.chatToken,
                conversationId,
                null,
                capture.sessionId,
                isAuthorised = { operationMutex.withLock { matchesMessengerAuthority(capture) } },
                commit = { transcript ->
                    outboxStore.replaceTranscriptIfAuthorised(
                        persistenceAuthority,
                        conversationId,
                        convergence.encodeTranscript(transcript),
                    )
                },
            )
            operationMutex.withLock {
                if (protectedSession != capture.session || inMemorySession?.chatToken != capture.chatToken || inMemorySession?.sessionId != capture.sessionId || capture.session.logoutPending) OpenConversationOutcome.NoActiveSession
                else {
                    mutablePresentationTarget.value = MessengerPresentationTarget.Conversation(conversationId)
                    mutablePresentation.value = MessengerPresentationIntent.PRESENT
                    OpenConversationOutcome.Opened
                }
            }
        } catch (failure: CancellationException) {
            currentCoroutineContext().ensureActive()
            OpenConversationOutcome.NoActiveSession
        }
        catch (_: IOException) { OpenConversationOutcome.Unavailable }
        catch (_: ProtocolViolation) { OpenConversationOutcome.NotAuthorised }
        catch (_: ai.onlo.sdk.storage.OwnerBlockedException) { OpenConversationOutcome.NoActiveSession }
    }

    /** SDK messenger-only inbox fetch. The list route is contract-backed and bearer-authorised. */
    internal suspend fun loadMessengerInbox(): MessengerInboxResult =
        loadMessengerInbox(allowTokenRefresh = true)

    private suspend fun loadMessengerInbox(allowTokenRefresh: Boolean): MessengerInboxResult {
        val observation = operationMutex.withLock {
            val session = inMemorySession ?: return@withLock null
            val protected = protectedSession ?: return@withLock null
            val api = widgetChatApi ?: return@withLock null
            if (protected.logoutPending) null else {
                conversationObservationGeneration += 1
                ConversationObservation(
                    ConversationOpenAuthority(protected, session.sessionId, session.chatToken, configSessionVersion, api),
                    conversationObservationGeneration,
                )
            }
        } ?: return MessengerInboxResult.NoActiveSession
        val capture = observation.authority
        return try {
            val result = capture.api.conversations(capture.chatToken, capture.sessionId)
            mutablePlatformConnected.value = true
            operationMutex.withLock {
                if (!matchesMessengerAuthority(capture)) MessengerInboxResult.NoActiveSession
                else if (observation.generation != conversationObservationGeneration) {
                    currentInbox(capture)?.let { MessengerInboxResult.Ready(it.conversations) }
                        ?: MessengerInboxResult.Unavailable
                }
                else {
                    val identified = capture.session.identityClass == IdentityClass.IDENTIFIED
                    val conversations = if (identified) result.conversations
                    else result.conversations.map { it.copy(unread = false, unreadCount = 0) }
                    val totalUnreadCount = if (identified) result.totalUnreadCount else 0
                    try {
                        outboxStore.replaceConversationListIfAuthorised(
                            persistenceAuthority(capture),
                            ConversationListCacheCodec.encode(ConversationList(conversations, totalUnreadCount)),
                        )
                    } catch (failure: CancellationException) {
                        throw failure
                    } catch (_: Exception) {
                        // A cache write failure must not hide a fresh authorised server response.
                    }
                    mutableUnreadCount.value = if (identified) totalUnreadCount else null
                    messengerInboxCache = MessengerInboxCache(
                        owner = capture.session.ownerScope(),
                        sessionId = capture.sessionId,
                        bearerVersion = capture.version,
                        conversations = conversations,
                        totalUnreadCount = totalUnreadCount,
                    )
                    MessengerInboxResult.Ready(conversations)
                }
            }
        } catch (failure: WidgetHttpFailure) {
            if (allowTokenRefresh && failure.status == 401 && refreshMessengerBearer(capture)) {
                return loadMessengerInbox(allowTokenRefresh = false)
            }
            mutablePlatformConnected.value = false
            loadCachedMessengerInbox(capture)
        } catch (_: IOException) {
            mutablePlatformConnected.value = false
            loadCachedMessengerInbox(capture)
        }
        catch (_: ProtocolViolation) {
            mutablePlatformConnected.value = true
            loadCachedMessengerInbox(capture)
        }
    }

    /** SDK messenger-only transcript refresh. It never returns a result for a retired account. */
    internal suspend fun loadMessengerTranscript(conversationId: String): MessengerTranscriptResult {
        if (conversationId.isBlank()) return MessengerTranscriptResult.NotAuthorised
        val capture = operationMutex.withLock {
            val session = inMemorySession ?: return@withLock null
            val protected = protectedSession ?: return@withLock null
            val api = widgetChatApi ?: return@withLock null
            if (protected.logoutPending) null else ConversationOpenAuthority(protected, session.sessionId, session.chatToken, configSessionVersion, api)
        } ?: return MessengerTranscriptResult.NoActiveSession
        val convergence = TranscriptConvergence(capture.api, outboxStore)
        val persistenceAuthority = persistenceAuthority(capture)
        return try {
            val transcript = convergence.fetchAfterFullSync(
                capture.session.ownerScope(), capture.chatToken, conversationId, null, capture.sessionId,
                isAuthorised = { operationMutex.withLock { matchesMessengerAuthority(capture) } },
                commit = { value ->
                    outboxStore.replaceTranscriptIfAuthorised(
                        persistenceAuthority,
                        conversationId,
                        convergence.encodeTranscript(value),
                    )
                },
            )
            mutablePlatformConnected.value = true
            operationMutex.withLock {
                if (!matchesMessengerAuthority(capture)) MessengerTranscriptResult.NoActiveSession
                else MessengerTranscriptResult.Ready(transcript)
            }
        } catch (failure: CancellationException) {
            currentCoroutineContext().ensureActive()
            MessengerTranscriptResult.NoActiveSession
        } catch (_: IOException) {
            mutablePlatformConnected.value = false
            val cached = runCatching { convergence.cached(capture.session.ownerScope(), conversationId, capture.sessionId) }.getOrNull()
            operationMutex.withLock {
                if (!matchesMessengerAuthority(capture)) MessengerTranscriptResult.NoActiveSession
                else cached?.let(MessengerTranscriptResult::Stale) ?: MessengerTranscriptResult.Unavailable
            }
        }
        catch (_: ProtocolViolation) { MessengerTranscriptResult.NotAuthorised }
        catch (_: ai.onlo.sdk.storage.OwnerBlockedException) { MessengerTranscriptResult.NoActiveSession }
    }

    internal suspend fun loadMessengerHelpCenter(): MessengerHelpCenterResult {
        val capture = operationMutex.withLock {
            val session = inMemorySession ?: return@withLock null
            val protected = protectedSession ?: return@withLock null
            val api = widgetChatApi ?: return@withLock null
            if (protected.logoutPending) null else ConversationOpenAuthority(protected, session.sessionId, session.chatToken, configSessionVersion, api)
        } ?: return MessengerHelpCenterResult.NoActiveSession
        return try {
            val topics = capture.api.helpCenter(capture.chatToken)
            mutablePlatformConnected.value = true
            operationMutex.withLock {
                if (!matchesMessengerAuthority(capture)) MessengerHelpCenterResult.NoActiveSession
                else MessengerHelpCenterResult.Ready(topics)
            }
        } catch (_: IOException) {
            mutablePlatformConnected.value = false
            MessengerHelpCenterResult.Unavailable
        }
        catch (_: ProtocolViolation) { MessengerHelpCenterResult.Unavailable }
    }

    internal suspend fun loadMessengerHelpArticle(articleId: String): MessengerHelpArticleResult {
        if (articleId.isBlank()) return MessengerHelpArticleResult.NotAuthorised
        val capture = operationMutex.withLock {
            val session = inMemorySession ?: return@withLock null
            val protected = protectedSession ?: return@withLock null
            val api = widgetChatApi ?: return@withLock null
            if (protected.logoutPending) null else ConversationOpenAuthority(protected, session.sessionId, session.chatToken, configSessionVersion, api)
        } ?: return MessengerHelpArticleResult.NoActiveSession
        return try {
            val article = capture.api.helpCenterArticle(capture.chatToken, articleId)
            mutablePlatformConnected.value = true
            operationMutex.withLock {
                if (!matchesMessengerAuthority(capture)) MessengerHelpArticleResult.NoActiveSession
                else MessengerHelpArticleResult.Ready(article)
            }
        } catch (_: IOException) {
            mutablePlatformConnected.value = false
            MessengerHelpArticleResult.Unavailable
        }
        catch (_: ProtocolViolation) { MessengerHelpArticleResult.NotAuthorised }
    }

    /** Native UI calls this only after an authorised transcript is rendered. */
    internal suspend fun acknowledgeRenderedConversation(
        conversationId: String,
        throughMessageId: String,
    ) {
        if (conversationId.isBlank() || throughMessageId.isBlank()) return
        val capture = operationMutex.withLock {
            val session = inMemorySession ?: return@withLock null
            val protected = protectedSession ?: return@withLock null
            val api = widgetChatApi ?: return@withLock null
            if (protected.logoutPending ||
                state.value.phase !in setOf(OnloPhase.ANONYMOUS_READY, OnloPhase.IDENTIFIED_READY)
            ) null else {
                conversationObservationGeneration += 1
                ConversationOpenAuthority(protected, session.sessionId, session.chatToken, configSessionVersion, api)
            }
        } ?: return
        capture.api.acknowledgeRead(capture.chatToken, conversationId, throughMessageId)
        val observation = operationMutex.withLock {
            if (!matchesMessengerAuthority(capture)) return
            conversationObservationGeneration += 1
            ConversationObservation(capture, conversationObservationGeneration)
        }
        val list = capture.api.conversations(capture.chatToken, capture.sessionId)
        operationMutex.withLock {
            if (matchesMessengerAuthority(capture) &&
                observation.generation == conversationObservationGeneration
            ) {
                val identified = capture.session.identityClass == IdentityClass.IDENTIFIED
                val conversations = if (identified) list.conversations
                else list.conversations.map { it.copy(unread = false, unreadCount = 0) }
                val totalUnreadCount = if (identified) list.totalUnreadCount else 0
                try {
                    outboxStore.replaceConversationListIfAuthorised(
                        persistenceAuthority(capture),
                        ConversationListCacheCodec.encode(ConversationList(conversations, totalUnreadCount)),
                    )
                } catch (failure: CancellationException) {
                    throw failure
                } catch (_: Exception) {
                    // Read acknowledgement remains successful even if its local cache refresh fails.
                }
                mutableUnreadCount.value = if (identified) totalUnreadCount else null
                messengerInboxCache = MessengerInboxCache(
                    owner = capture.session.ownerScope(),
                    sessionId = capture.sessionId,
                    bearerVersion = capture.version,
                    conversations = conversations,
                    totalUnreadCount = totalUnreadCount,
                )
            }
        }
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
        outboxStore.blockOwner(oldOwner)
        mutablePresentation.value = MessengerPresentationIntent.HIDDEN
        mutablePresentationTarget.value = MessengerPresentationTarget.Inbox
        mutableUnreadCount.value = null
        mutablePlatformConnected.value = false
        identifiedFirstName = null
        pushRegistry?.activateAuthority(null)
        invalidateConfigSession()
        val blocked = stored.copy(logoutPending = true)
        // This must be durable before the server Logout can suspend.
        persist(blocked, pending)
        mutableState.value = OnloState(OnloPhase.LOGOUT_PENDING, OnloIdentityState.UNKNOWN)
        try {
            pushRegistry?.discardOwner(oldOwner.storageKey())
        } catch (_: Throwable) {
            // Push cleanup is best effort. The session transition atomically
            // clears the server registration and remains the security boundary.
        }
        inMemorySession = null

        return try {
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
    internal data class PendingNativeAttachment(
        val attachment: ChatAttachment,
        val staged: StagedAttachment,
    )

    internal suspend fun uploadImageFromNativeUi(
        conversationId: String?,
        bytes: ByteArray,
        mimeType: String,
        fileName: String,
        previousGrant: String? = null,
    ): PendingNativeAttachment = operationMutex.withLock {
        require(mimeType in setOf("image/jpeg", "image/png", "image/webp")) { "attachment_type" }
        val config = mobileConfig?.value?.config ?: throw OnloException.Unavailable
        if (!config.features.fileUpload || !config.mediaPolicy.enabled) {
            throw OnloException.Server("media_unavailable", RetryDirective.NEVER)
        }
        require(bytes.isNotEmpty() && bytes.size <= config.mediaPolicy.effectiveMaximumImageBytes) {
            "attachment_size"
        }
        val session = checkNotNull(inMemorySession) { "onlo_not_ready" }
        val api = checkNotNull(widgetChatApi) { "chat_unavailable" }
        val cacheDir = checkNotNull(attachmentCacheDir) { "attachment_cache_unavailable" }
        val authority = configSessionVersion
        val owner = checkNotNull(protectedSession).ownerScope()
        val file = File.createTempFile("onlo-upload-", ".img", cacheDir)
        try {
            file.writeBytes(bytes)
            val uploaded = api.upload(
                chatToken = session.chatToken,
                conversationId = conversationId,
                previousGrant = previousGrant,
                fileName = fileName,
                mimeType = mimeType,
                file = file,
            )
            if (
                configSessionVersion != authority ||
                protectedSession?.ownerScope() != owner ||
                inMemorySession != session
            ) throw CancellationException("stale_attachment_upload")
            val expiry = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss.SSS'Z'", Locale.US).apply {
                timeZone = TimeZone.getTimeZone("UTC")
            }.parse(uploaded.grantExpiresAt)?.time ?: throw ProtocolViolation("attachment_expiry")
            PendingNativeAttachment(
                attachment = ChatAttachment(
                    id = uploaded.id,
                    url = uploaded.url,
                    type = uploaded.type,
                    name = uploaded.name,
                    size = uploaded.size,
                    grant = uploaded.grant,
                ),
                staged = StagedAttachment(
                    dataBase64 = Base64.getEncoder().encodeToString(bytes),
                    mimeType = mimeType,
                    fileName = fileName,
                    conversationId = conversationId,
                    grantExpiresAtMs = expiry,
                ),
            )
        } finally {
            file.delete()
        }
    }

    internal suspend fun sendTextFromNativeUi(
        message: String,
        routingSessionId: String? = null,
        attachments: List<PendingNativeAttachment> = emptyList(),
        onEnqueued: (String) -> Unit = {},
    ): String = operationMutex.withLock {
        require(message.isNotBlank() || attachments.isNotEmpty()) { "message" }
        val session = checkNotNull(inMemorySession) { "onlo_not_ready" }
        val stored = checkNotNull(protectedSession) { "onlo_not_ready" }
        val owner = stored.ownerScope()
        val outbox = checkNotNull(widgetChatApi) { "chat_unavailable" }
        val version = configSessionVersion
        val durable = durableChatOutbox(owner, session, version, outbox)
        val entry = durable.enqueue(
            owner,
            routingSessionId ?: session.sessionId,
            message,
            attachments.map(PendingNativeAttachment::attachment),
            attachments.map(PendingNativeAttachment::staged),
        )
        // Let the native presenter render the durable row before transport can emit an event.
        onEnqueued(entry.clientMessageId)
        startChatFlushIfNeeded(owner, session, version, durable)
        entry.clientMessageId
    }

    private fun durableChatOutbox(
        owner: OwnerScope,
        session: InMemorySession,
        version: Long,
        api: WidgetChatApi,
    ): DurableChatOutbox = run {
        val dispatchProtected = checkNotNull(protectedSession).takeIf {
            it.ownerScope() == owner && !it.logoutPending
        } ?: throw IllegalStateException("stale_chat_dispatcher")
        val dispatchPersistence = persistenceAuthority(owner, dispatchProtected, session, version)
        DurableChatOutbox(
        outboxStore,
        api,
        nowMs,
        onDuplicateAccepted = { conversationId ->
            // Duplicate acknowledgement is durable but may have lost the original stream.
            val protected = operationMutex.withLock {
                protectedSession?.takeIf {
                    it.ownerScope() == owner &&
                        !it.logoutPending &&
                        it == dispatchProtected &&
                        inMemorySession == session &&
                        configSessionVersion == version
                }
            } ?: throw CancellationException("stale_chat_dispatcher")
            val convergence = TranscriptConvergence(api, outboxStore)
            convergence.fetchAfterFullSync(
                owner,
                session.chatToken,
                conversationId,
                null,
                session.sessionId,
                isAuthorised = {
                    operationMutex.withLock {
                        configSessionVersion == version &&
                            protectedSession == protected &&
                            inMemorySession == session &&
                            !protected.logoutPending
                    }
                },
                commit = { transcript ->
                    outboxStore.replaceTranscriptIfAuthorised(
                        dispatchPersistence,
                        conversationId,
                        convergence.encodeTranscript(transcript),
                    )
                },
            )
        },
        onEvent = { entry, event ->
            suspend fun requireEventAuthority() {
                val current = operationMutex.withLock {
                    configSessionVersion == version &&
                        protectedSession == dispatchProtected &&
                        !dispatchProtected.logoutPending &&
                        inMemorySession == session
                }
                if (!current) throw CancellationException("stale_chat_event")
            }
            requireEventAuthority()
            when (event) {
                is ai.onlo.sdk.chat.ChatEvent.Accepted -> {
                    operationMutex.withLock {
                        if (
                            protectedSession?.ownerScope() == owner &&
                            protectedSession?.logoutPending == false &&
                            protectedSession == dispatchProtected &&
                            inMemorySession == session &&
                            configSessionVersion == version
                        ) {
                            acceptedReconciliation.workGeneration += 1
                            ensureAcceptedReconciliationScheduler(
                                owner,
                                session,
                                version,
                                api,
                            )
                        }
                    }
                    mutableMessengerEvents.emit(
                        NativeMessengerEvent.Accepted(
                            entry.clientMessageId,
                            event.conversationId,
                            event.duplicate,
                        ),
                    )
                    requireEventAuthority()
                }
                is ai.onlo.sdk.chat.ChatEvent.Text -> {
                    mutableMessengerEvents.emit(
                        NativeMessengerEvent.Text(entry.clientMessageId, event.content),
                    )
                    requireEventAuthority()
                }
                is ai.onlo.sdk.chat.ChatEvent.Done -> {
                    if (!outboxStore.markReconciledIfAccepted(
                        dispatchPersistence,
                        entry.clientMessageId,
                        entry.attemptCount + 1,
                    )) throw CancellationException("stale_chat_done")
                    requireEventAuthority()
                    operationMutex.withLock {
                        acceptedReconciliation.wake?.complete(Unit)
                    }
                    mutableMessengerEvents.emit(
                        NativeMessengerEvent.Done(entry.clientMessageId, event.conversationId),
                    )
                    requireEventAuthority()
                }
                is ai.onlo.sdk.chat.ChatEvent.Error -> {
                    mutableMessengerEvents.emit(
                        NativeMessengerEvent.Failed(entry.clientMessageId, event.retryable, event.error),
                    )
                    requireEventAuthority()
                }
            }
        },
        refreshExpiredAttachments = { entry, _ ->
            val refreshed = entry.stagedAttachments.mapIndexed { index, staged ->
                val prior = entry.attachments.getOrNull(index)
                    ?: throw IllegalStateException("attachment_staging_mismatch")
                val pending = uploadImageFromNativeUi(
                    conversationId = staged.conversationId,
                    bytes = Base64.getDecoder().decode(staged.dataBase64),
                    mimeType = staged.mimeType,
                    fileName = staged.fileName,
                    previousGrant = prior.grant,
                )
                // The server reuses the attachment identity when previousGrant
                // is supplied; call through the lower-level adapter to retain it.
                if (pending.attachment.id != prior.id) {
                    throw IllegalStateException("attachment_identity_changed")
                }
                pending
            }
            entry.copy(
                attachments = refreshed.map(PendingNativeAttachment::attachment),
                stagedAttachments = refreshed.map(PendingNativeAttachment::staged),
            )
        },
        )
    }

    /** Called with [operationMutex] held. Enqueue only wakes the current owner dispatcher. */
    private suspend fun startChatFlushIfNeeded(
        owner: OwnerScope,
        session: InMemorySession,
        version: Long,
        durable: DurableChatOutbox,
        recoverInterrupted: Boolean = false,
    ) {
        if (chatFlushId != null) {
            if (chatFlushOwner == owner) chatFlushWakeRequested = true
            return
        }
        val protected = protectedSession?.takeIf {
            it.ownerScope() == owner && !it.logoutPending
        } ?: return
        val persistence = persistenceAuthority(owner, protected, session, version)
        if (recoverInterrupted) {
            if (!outboxStore.recoverInterruptedSendsIfAuthorised(persistence, nowMs())) return
        }
        val flushId = UUID.randomUUID()
        chatFlushOwner = owner
        chatFlushId = flushId
        chatFlushWakeRequested = false
        chatFlushJob = scope.launch {
            try {
                while (true) {
                val authorised = operationMutex.withLock {
                    chatFlushId == flushId &&
                        version == configSessionVersion &&
                        protectedSession?.ownerScope() == owner &&
                        protectedSession?.logoutPending == false &&
                        inMemorySession == session
                }
                if (!authorised) return@launch
                val nextAttemptAtMs = durable.flush(
                    owner,
                    session.sessionId,
                    session.chatToken,
                    persistenceAuthority = persistence,
                    isAuthorised = {
                        operationMutex.withLock {
                            chatFlushId == flushId &&
                                version == configSessionVersion &&
                                protectedSession?.ownerScope() == owner &&
                                protectedSession?.logoutPending == false &&
                                inMemorySession == session
                        }
                    },
                )
                val delayMs = operationMutex.withLock {
                    if (chatFlushId != flushId) {
                        null
                    } else if (
                        version != configSessionVersion ||
                        protectedSession?.ownerScope() != owner ||
                        protectedSession?.logoutPending != false ||
                        inMemorySession != session
                    ) {
                        chatFlushJob = null
                        chatFlushOwner = null
                        chatFlushId = null
                        chatFlushWakeRequested = false
                        null
                    } else if (nextAttemptAtMs != null) {
                        chatFlushWakeRequested = false
                        (nextAttemptAtMs - nowMs()).coerceAtLeast(0)
                    } else if (chatFlushWakeRequested &&
                        version == configSessionVersion
                    ) {
                        chatFlushWakeRequested = false
                        0L
                    } else {
                        chatFlushJob = null
                        chatFlushOwner = null
                        chatFlushId = null
                        chatFlushWakeRequested = false
                        null
                    }
                }
                if (delayMs == null) return@launch
                if (delayMs > 0) retryDelay(delayMs)
                }
            } finally {
                operationMutex.withLock {
                    if (chatFlushId == flushId) {
                        chatFlushJob = null
                        chatFlushOwner = null
                        chatFlushId = null
                        chatFlushWakeRequested = false
                    }
                }
            }
        }
    }

    private suspend fun restoreOrBootstrap() = operationMutex.withLock {
        val stored = loadProtectedSession()
        if (stored?.logoutPending == true) {
            if (pendingTransition is PendingSessionTransition.Resume) {
                resumeForPendingLogout(stored)
            } else {
                logoutLocked(stored, allowRetryablePending = false)
            }
        } else {
            restoreOrBootstrapLocked(stored, allowRetryablePending = false)
        }
    }

    /** Completes a legacy pending Resume, then continues the session Logout. */
    private suspend fun resumeForPendingLogout(stored: ProtectedSession) {
        val resume = PendingSessionTransition.Resume(
            installationId = stored.installationId, transitionId = newUuid(), expectedGeneration = stored.generation,
            presentedCredential = stored.credential, proposedCredential = newCredential(),
        )
        persist(stored, resume)
        val result = exchange(resume.toOperation(), resume.installationId)
        if (result.identityClass != stored.identityClass) throw OnloException.InvalidProtocol
        val rotated = stored.copy(credential = result.proposedCredential, generation = result.generation, logoutPending = true)
        // The Resume is complete; the authoritative Logout below clears the
        // server registration together with the old customer association.
        persist(rotated, null)
        protectedSession = rotated
        inMemorySession = InMemorySession(result.sessionId, result.chatToken)
        try {
            pushRegistry?.discardOwner(rotated.ownerScope().storageKey())
        } catch (_: Throwable) {
            // Local push cleanup is best effort and cannot block logout.
        }
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
        }
        applySession(result, ownerScopeId = ownerScopeId, refreshConfigAfterSession = refreshConfigAfterSession)
    }

    private suspend fun applySession(
        result: SessionResult,
        ownerScopeId: String,
        refreshConfigAfterSession: Boolean = true,
    ) {
        val previousOwner = protectedSession?.ownerScope()
        val next = ProtectedSession(
            installationId = result.installationId,
            credential = result.proposedCredential,
            generation = result.generation,
            ownerScopeId = ownerScopeId,
            identityClass = result.identityClass,
            logoutPending = false,
        )
        persist(next, null)
        val nextSession = InMemorySession(result.sessionId, result.chatToken)
        outboxStore.revokeAuthority(previousOwner ?: next.ownerScope())
        pushRegistry?.activateAuthority(null)
        invalidateConfigSession()
        inMemorySession = nextSession
        outboxStore.activateAuthority(
            persistenceAuthority(next.ownerScope(), next, nextSession, configSessionVersion),
        )
        if (previousOwner != null && previousOwner != next.ownerScope()) {
            try {
                pushRegistry?.discardOwner(previousOwner.storageKey())
            } catch (_: Throwable) {
                // The server session transition already cleared the old
                // registration. A local push-store failure cannot block chat.
            }
        }
        pushRegistry?.activateAuthority(
            PushAuthority(
                owner = next.ownerScope(),
                chatToken = nextSession.chatToken,
                sessionGeneration = next.generation,
                sessionId = nextSession.sessionId,
                bearerVersion = configSessionVersion,
            ),
        )
        mutableState.value = when (result.identityClass) {
            IdentityClass.ANONYMOUS -> OnloState(OnloPhase.ANONYMOUS_READY, OnloIdentityState.ANONYMOUS)
            IdentityClass.IDENTIFIED -> OnloState(OnloPhase.IDENTIFIED_READY, OnloIdentityState.IDENTIFIED)
        }
        widgetChatApi?.let { api ->
            ensureAcceptedReconciliationScheduler(
                next.ownerScope(),
                nextSession,
                configSessionVersion,
                api,
            )
            startChatFlushIfNeeded(
                next.ownerScope(),
                nextSession,
                configSessionVersion,
                durableChatOutbox(next.ownerScope(), nextSession, configSessionVersion, api),
                recoverInterrupted = true,
            )
        }
        if (refreshConfigAfterSession) scheduleConfigRefresh(result.chatToken, configSessionVersion)
        if (result.identityClass == IdentityClass.ANONYMOUS) mutableUnreadCount.value = null
        schedulePendingPushRegistration()
    }

    /** Called with [operationMutex] held. Ownership never depends on [Job.isActive]. */
    private fun ensureAcceptedReconciliationScheduler(
        owner: OwnerScope,
        session: InMemorySession,
        version: Long,
        api: WidgetChatApi,
    ) {
        if (acceptedReconciliation.phase != AcceptedReconciliationPhase.STOPPED) {
            check(
                acceptedReconciliation.owner == owner &&
                    acceptedReconciliation.sessionVersion == version,
            ) { "accepted_reconciliation_authority" }
            acceptedReconciliation.wake?.complete(Unit)
            return
        }
        val token = UUID.randomUUID()
        acceptedReconciliation.phase = AcceptedReconciliationPhase.STARTING
        acceptedReconciliation.owner = owner
        acceptedReconciliation.sessionVersion = version
        acceptedReconciliation.ownershipToken = token
        acceptedReconciliation.wake = null
        acceptedReconciliation.startCount += 1
        val job = scope.launch(start = CoroutineStart.LAZY) {
            try {
                runAcceptedReconciliationScheduler(owner, session, version, token, api)
            } finally {
                operationMutex.withLock {
                    if (acceptedReconciliation.ownershipToken == token) {
                        clearAcceptedReconciliationOwnership()
                    }
                }
            }
        }
        acceptedReconciliation.job = job
        job.start()
    }

    private suspend fun runAcceptedReconciliationScheduler(
        owner: OwnerScope,
        session: InMemorySession,
        version: Long,
        token: UUID,
        api: WidgetChatApi,
    ) {
        while (true) {
            val generation = operationMutex.withLock {
                if (!acceptedReconciliationAuthorityMatches(owner, version, token)) return
                acceptedReconciliation.phase = AcceptedReconciliationPhase.RUNNING
                acceptedReconciliation.wake = null
                acceptedReconciliation.workGeneration
            }
            val empty = reconcileAcceptedOutbox(owner, session, version, token, api)
            if (empty) {
                acceptedReconciliationBeforeEmptyCommit()
                val continueRunning = operationMutex.withLock {
                    if (!acceptedReconciliationAuthorityMatches(owner, version, token)) {
                        false
                    } else {
                        acceptedReconciliation.phase = AcceptedReconciliationPhase.EXITING
                        if (acceptedReconciliation.workGeneration != generation) {
                            acceptedReconciliation.phase = AcceptedReconciliationPhase.RUNNING
                            true
                        } else {
                            clearAcceptedReconciliationOwnership()
                            false
                        }
                    }
                }
                if (!continueRunning) return
                continue
            }
            val wake = CompletableDeferred<Unit>()
            val wait = operationMutex.withLock {
                if (!acceptedReconciliationAuthorityMatches(owner, version, token)) {
                    false
                } else if (acceptedReconciliation.workGeneration != generation) {
                    acceptedReconciliation.phase = AcceptedReconciliationPhase.RUNNING
                    false
                } else {
                    acceptedReconciliation.phase = AcceptedReconciliationPhase.WAITING
                    acceptedReconciliation.wake = wake
                    true
                }
            }
            if (wait) withTimeoutOrNull(acceptedReconciliationDelayMs) { wake.await() }
        }
    }

    /** Called with [operationMutex] held. */
    private fun acceptedReconciliationAuthorityMatches(
        owner: OwnerScope,
        version: Long,
        token: UUID,
    ): Boolean =
        acceptedReconciliation.ownershipToken == token &&
            acceptedReconciliation.owner == owner &&
            acceptedReconciliation.sessionVersion == version &&
            version == configSessionVersion &&
            protectedSession?.ownerScope() == owner &&
            protectedSession?.logoutPending == false

    /** Called with [operationMutex] held. */
    private fun clearAcceptedReconciliationOwnership() {
        acceptedReconciliation.phase = AcceptedReconciliationPhase.STOPPED
        acceptedReconciliation.owner = null
        acceptedReconciliation.sessionVersion = null
        acceptedReconciliation.ownershipToken = null
        acceptedReconciliation.job = null
        acceptedReconciliation.wake = null
    }

    internal data class AcceptedReconciliationDebugState(
        val phase: String,
        val workGeneration: Long,
        val ownershipToken: UUID?,
        val startCount: Long,
    )

    internal suspend fun acceptedReconciliationDebugState(): AcceptedReconciliationDebugState =
        operationMutex.withLock {
            AcceptedReconciliationDebugState(
                acceptedReconciliation.phase.name,
                acceptedReconciliation.workGeneration,
                acceptedReconciliation.ownershipToken,
                acceptedReconciliation.startCount,
            )
        }

    private suspend fun reconcileAcceptedOutbox(
        owner: OwnerScope,
        session: InMemorySession,
        version: Long,
        token: UUID,
        api: WidgetChatApi,
    ): Boolean {
        suspend fun authority(): PersistenceAuthority? = operationMutex.withLock {
            val protected = protectedSession
            if (!acceptedReconciliationAuthorityMatches(owner, version, token) ||
                protected == null ||
                inMemorySession != session
            ) null else persistenceAuthority(owner, protected, session, version)
        }
        val persistenceAuthority = authority() ?: throw CancellationException("stale_accepted_reconciler")
        val entries = outboxStore.acceptedAwaitingReconciliation(owner)
        if (authority() != persistenceAuthority) throw CancellationException("stale_accepted_reconciler")
        for (entry in entries) {
            val conversationId = entry.serverConversationId ?: continue
            val serverMessageId = entry.serverMessageId ?: continue
            if (authority() != persistenceAuthority) throw CancellationException("stale_accepted_reconciler")
            val transcript = try {
                api.transcript(
                    session.chatToken,
                    conversationId,
                    ai.onlo.sdk.protocol.ConversationPageQuery.Latest(limit = 100),
                    session.sessionId,
                )
            } catch (failure: kotlinx.coroutines.CancellationException) {
                throw failure
            } catch (_: Exception) {
                continue
            }
            if (authority() != persistenceAuthority) throw CancellationException("stale_accepted_reconciler")
            val acceptedIndex = transcript.messages.indexOfFirst { it.id == serverMessageId }
            if (acceptedIndex >= 0 && transcript.messages.drop(acceptedIndex + 1).any {
                    it.role != "user" && it.role != "customer"
                }
            ) {
                val payload =
                    org.json.JSONObject().apply {
                        put("id", transcript.id)
                        put("sessionId", transcript.sessionId)
                        put("status", transcript.status)
                        put("isHumanTakeover", transcript.isHumanTakeover)
                        put("previousCursor", transcript.previousCursor)
                        put("nextCursor", transcript.nextCursor)
                        put("limit", transcript.limit)
                        put("messages", org.json.JSONArray().apply {
                            transcript.messages.forEach { message ->
                                put(org.json.JSONObject().apply {
                                    put("id", message.id)
                                    put("externalId", message.externalId)
                                    put("role", message.role)
                                    put("senderType", message.senderType)
                                    put("senderName", message.senderName)
                                    put("senderTeam", message.senderTeam)
                                    put("text", message.text)
                                    put("attachments", org.json.JSONArray(message.attachments))
                                    put("timestamp", message.timestamp)
                                })
                            }
                        })
                    }.toString()
                if (authority() != persistenceAuthority) {
                    throw CancellationException("stale_accepted_reconciler")
                }
                if (!outboxStore.reconcileAcceptedIfAuthorised(
                    persistenceAuthority,
                    entry.clientMessageId,
                    serverMessageId,
                    conversationId,
                    payload,
                )) throw CancellationException("stale_accepted_commit")
            }
        }
        if (authority() != persistenceAuthority) throw CancellationException("stale_accepted_reconciler")
        val empty = outboxStore.acceptedAwaitingReconciliation(owner).isEmpty()
        if (authority() != persistenceAuthority) throw CancellationException("stale_accepted_reconciler")
        return empty
    }

    private fun schedulePendingPushRegistration() {
        val pending = pendingPushRegistration ?: return
        val registry = pushRegistry ?: return
        val authority = currentPushAuthority() ?: return
        scope.launch {
            try {
                registry.register(
                    authority,
                    pending.provider,
                    pending.token,
                    pending.notificationPreference,
                    pending.locale,
                )
            } catch (failure: CancellationException) {
                throw failure
            } catch (_: Throwable) {
                // Push recovery is isolated from session, chat, and UI state.
            }
        }
    }

    /** Host lifecycle seam; a conditional refresh uses only the in-memory bearer token. */
    public fun onAppForeground() {
        scope.launch {
            // Account-boundary recovery has priority and must not be queued behind ordinary
            // foreground refresh work for an owner that is already retiring.
            if (state.value.phase == OnloPhase.LOGOUT_PENDING) {
                retryPendingLogoutFromLifecycle()
                return@launch
            }
            val recovered = recoverOfflineSessionForLifecycle()
            if (recovered) startForegroundStreamFromLifecycle()
            else refreshConfigFromLifecycle()
            dispatchDurableOutboxFromLifecycle()
            reconcilePushFromLifecycle()
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
            try {
                val authority = operationMutex.withLock { currentPushAuthority() }
                registry.reconcileEligible(authority)
            } catch (failure: CancellationException) {
                throw failure
            } catch (_: Throwable) {
                // A later token refresh or lifecycle recovery may retry push.
            }
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
            val outbox = durableChatOutbox(capture.first, capture.second, capture.third, api)
            operationMutex.withLock {
                if (
                    protectedSession?.ownerScope() == capture.first &&
                        configSessionVersion == capture.third &&
                        protectedSession?.logoutPending == false
                ) {
                    startChatFlushIfNeeded(
                        capture.first,
                        capture.second,
                        capture.third,
                        outbox,
                        recoverInterrupted = true,
                    )
                    ensureAcceptedReconciliationScheduler(
                        capture.first,
                        capture.second,
                        capture.third,
                        api,
                    )
                }
            }
        }
    }

    private suspend fun retryPendingLogoutFromLifecycle() {
        if (state.value.phase != OnloPhase.LOGOUT_PENDING) return
        logout()
    }

    private suspend fun startForegroundStream(token: String, version: Long) = operationMutex.withLock {
        val stream = foregroundStream ?: return
        val session = inMemorySession ?: return
        val protected = protectedSession ?: return
        val owner = protected.ownerScope()
        if (protected.logoutPending ||
            session.chatToken != token ||
            configSessionVersion != version
        ) return
        if (foregroundPhase != ForegroundPhase.STOPPED) {
            check(
                foregroundOwner == owner &&
                    foregroundVersion == version,
            ) { "foreground_stream_authority" }
            return
        }
        val ownershipToken = UUID.randomUUID()
        foregroundPhase = ForegroundPhase.STARTING
        foregroundOwnershipToken = ownershipToken
        foregroundOwner = owner
        foregroundVersion = version
        foregroundJob = scope.launch {
            try {
                operationMutex.withLock {
                    if (foregroundOwnershipToken != ownershipToken ||
                        !matchesForegroundAuthority(
                            ForegroundAuthority(token, session.sessionId, version, owner),
                        )
                    ) return@launch
                    foregroundPhase = ForegroundPhase.RUNNING
                }
                stream.collect(token) { hint ->
                    val authority = foregroundAuthority(token, version)
                        ?: throw CancellationException("stale_foreground_stream")
                    when (hint) {
                        ForegroundHint.Ready -> mutablePlatformConnected.value = true
                        is ForegroundHint.ConfigChanged -> refreshConfigWithSessionRecovery(authority.token, authority.version)
                        is ForegroundHint.Conversation -> {
                            operationMutex.withLock {
                                acceptedReconciliation.wake?.complete(Unit)
                            }
                            convergeHintTranscript(hint.conversationId, authority)
                            refetchUnreadAfterHint(authority)
                        }
                        is ForegroundHint.Message -> {
                            operationMutex.withLock {
                                acceptedReconciliation.wake?.complete(Unit)
                            }
                            convergeHintTranscript(hint.conversationId, authority)
                            refetchUnreadAfterHint(authority)
                        }
                    }
                }
            } catch (failure: CancellationException) {
                throw failure
            } catch (_: IOException) {
                // Foreground hints are best effort; lifecycle/network recovery starts a new stream.
            } finally {
                operationMutex.withLock {
                    if (foregroundOwnershipToken == ownershipToken) {
                        mutablePlatformConnected.value = false
                        foregroundPhase = ForegroundPhase.STOPPED
                        foregroundOwnershipToken = null
                        foregroundOwner = null
                        foregroundVersion = null
                        foregroundJob = null
                    }
                }
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
        if (protected.logoutPending || state.value.phase !in setOf(
                OnloPhase.ANONYMOUS_READY,
                OnloPhase.IDENTIFIED_READY,
            )
        ) return null
        return PushAuthority(
            owner = protected.ownerScope(),
            chatToken = session.chatToken,
            sessionGeneration = protected.generation,
            sessionId = session.sessionId,
            bearerVersion = configSessionVersion,
        )
    }

    private fun matchesMessengerAuthority(capture: ConversationOpenAuthority): Boolean =
        protectedSession == capture.session &&
            configSessionVersion == capture.version &&
            inMemorySession?.chatToken == capture.chatToken &&
            inMemorySession?.sessionId == capture.sessionId &&
            !capture.session.logoutPending

    private fun currentInbox(capture: ConversationOpenAuthority): MessengerInboxCache? =
        messengerInboxCache?.takeIf {
            it.owner == capture.session.ownerScope() &&
                it.sessionId == capture.sessionId &&
                it.bearerVersion == capture.version
        }

    private suspend fun loadCachedMessengerInbox(capture: ConversationOpenAuthority): MessengerInboxResult =
        operationMutex.withLock {
            if (!matchesMessengerAuthority(capture)) return@withLock MessengerInboxResult.NoActiveSession
            val cached = currentInbox(capture)?.let {
                ConversationList(it.conversations, it.totalUnreadCount)
            } ?: try {
                outboxStore.conversationListIfAuthorised(persistenceAuthority(capture))
                    ?.let(ConversationListCacheCodec::decode)
            } catch (failure: CancellationException) {
                throw failure
            } catch (_: Exception) {
                null
            } ?: return@withLock MessengerInboxResult.Unavailable

            val identified = capture.session.identityClass == IdentityClass.IDENTIFIED
            val conversations = if (identified) cached.conversations else {
                cached.conversations.map { it.copy(unread = false, unreadCount = 0) }
            }
            val totalUnreadCount = if (identified) cached.totalUnreadCount else 0
            mutableUnreadCount.value = if (identified) totalUnreadCount else null
            messengerInboxCache = MessengerInboxCache(
                owner = capture.session.ownerScope(),
                sessionId = capture.sessionId,
                bearerVersion = capture.version,
                conversations = conversations,
                totalUnreadCount = totalUnreadCount,
            )
            MessengerInboxResult.Stale(conversations)
        }

    /** One bounded session refresh for a rejected Widget bearer; Operator JWT is not involved. */
    private suspend fun refreshMessengerBearer(capture: ConversationOpenAuthority): Boolean =
        operationMutex.withLock {
            if (!matchesMessengerAuthority(capture)) {
                return@withLock protectedSession?.ownerScope() == capture.session.ownerScope() &&
                    !capture.session.logoutPending &&
                    state.value.phase in setOf(OnloPhase.ANONYMOUS_READY, OnloPhase.IDENTIFIED_READY)
            }
            val stored = loadProtectedSession() ?: return@withLock false
            if (stored.logoutPending || stored.ownerScope() != capture.session.ownerScope()) return@withLock false
            try {
                restoreOrBootstrapLocked(stored)
                protectedSession?.ownerScope() == capture.session.ownerScope() &&
                    state.value.phase in setOf(OnloPhase.ANONYMOUS_READY, OnloPhase.IDENTIFIED_READY)
            } catch (failure: CancellationException) {
                throw failure
            } catch (failure: Throwable) {
                mutablePlatformConnected.value = false
                publishFailure(failure, phaseForCurrentScope())
                false
            }
        }

    private fun matchesForegroundAuthority(capture: ForegroundAuthority): Boolean {
        val session = inMemorySession ?: return false
        val protected = protectedSession ?: return false
        return configSessionVersion == capture.version &&
            session.chatToken == capture.token &&
            session.sessionId == capture.sessionId &&
            protected.ownerScope() == capture.owner &&
            !protected.logoutPending
    }

    private fun persistenceAuthority(
        owner: OwnerScope,
        protected: ProtectedSession,
        session: InMemorySession,
        version: Long,
    ): PersistenceAuthority = PersistenceAuthority(
        ownerScope = owner,
        sessionGeneration = protected.generation,
        sessionId = session.sessionId,
        bearerContext = "$version:${session.chatToken}",
    )

    private fun persistenceAuthority(capture: ConversationOpenAuthority): PersistenceAuthority =
        PersistenceAuthority(
            ownerScope = capture.session.ownerScope(),
            sessionGeneration = capture.session.generation,
            sessionId = capture.sessionId,
            bearerContext = "${capture.version}:${capture.chatToken}",
        )

    /** Only logout recovery may use this retained bearer; ordinary APIs remain blocked by logoutPending. */
    private fun blockedOwnerAuthority(stored: ProtectedSession): PushAuthority? {
        val session = inMemorySession ?: return null
        val current = protectedSession ?: return null
        if (!current.logoutPending || current.ownerScopeId != stored.ownerScopeId) return null
        return PushAuthority(
            owner = stored.ownerScope(),
            chatToken = session.chatToken,
            sessionGeneration = stored.generation,
            sessionId = session.sessionId,
            bearerVersion = configSessionVersion,
        )
    }

    private suspend fun convergeHintTranscript(conversationId: String, authority: ForegroundAuthority) {
        val api = widgetChatApi ?: return
        val persistenceAuthority = operationMutex.withLock {
            val protected = protectedSession
            val session = inMemorySession
            if (protected == null || session == null || !matchesForegroundAuthority(authority)) null
            else persistenceAuthority(authority.owner, protected, session, authority.version)
        } ?: return
        val convergence = TranscriptConvergence(api, outboxStore)
        try {
            convergence.fetchAfterFullSync(
                authority.owner,
                authority.token,
                conversationId,
                null,
                authority.sessionId,
                isAuthorised = { operationMutex.withLock { matchesForegroundAuthority(authority) } },
                commit = { transcript ->
                    outboxStore.replaceTranscriptIfAuthorised(
                        persistenceAuthority,
                        conversationId,
                        convergence.encodeTranscript(transcript),
                    )
                },
            )
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

    private suspend fun refetchUnreadAfterHint(authority: ForegroundAuthority) {
        val api = widgetChatApi ?: return
        val observation = operationMutex.withLock {
            if (!matchesForegroundAuthority(authority) ||
                protectedSession?.identityClass != IdentityClass.IDENTIFIED
            ) null else {
                conversationObservationGeneration += 1
                conversationObservationGeneration
            }
        }
        if (observation == null) return
        try {
            val result = api.conversations(authority.token, authority.sessionId)
            operationMutex.withLock {
                if (matchesForegroundAuthority(authority) &&
                    observation == conversationObservationGeneration
                ) {
                    val protected = checkNotNull(protectedSession)
                    val session = checkNotNull(inMemorySession)
                    try {
                        outboxStore.replaceConversationListIfAuthorised(
                            persistenceAuthority(authority.owner, protected, session, authority.version),
                            ConversationListCacheCodec.encode(result),
                        )
                    } catch (failure: CancellationException) {
                        throw failure
                    } catch (_: Exception) {
                        // Hint-driven unread refresh remains best effort when cache storage fails.
                    }
                    mutableUnreadCount.value = result.totalUnreadCount
                    messengerInboxCache = MessengerInboxCache(
                        owner = authority.owner,
                        sessionId = authority.sessionId,
                        bearerVersion = authority.version,
                        conversations = result.conversations,
                        totalUnreadCount = result.totalUnreadCount,
                    )
                }
            }
        } catch (_: IOException) {
        } catch (_: ProtocolViolation) {
        }
    }

    /** This job waits for any current session mutation before it starts network work. */
    private fun scheduleConfigRefresh(token: String, version: Long) {
        if (configController == null) return
        scope.launch {
            refreshConfigWithSessionRecovery(token, version)
            val refreshed = operationMutex.withLock {
                val protected = protectedSession
                val session = inMemorySession
                if (protected == null || session == null || protected.logoutPending ||
                    state.value.phase !in setOf(OnloPhase.ANONYMOUS_READY, OnloPhase.IDENTIFIED_READY)
                ) null else session.chatToken to configSessionVersion
            } ?: return@launch
            startForegroundStream(refreshed.first, refreshed.second)
        }
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
        chatFlushOwner = null
        chatFlushId = null
        chatFlushWakeRequested = false
        val reconciliationJob = acceptedReconciliation.job
        clearAcceptedReconciliationOwnership()
        reconciliationJob?.cancel()
        val oldForegroundJob = foregroundJob
        foregroundPhase = ForegroundPhase.STOPPED
        foregroundOwnershipToken = null
        foregroundOwner = null
        foregroundVersion = null
        foregroundJob = null
        oldForegroundJob?.cancel()
        configSessionVersion = configController?.onSessionBoundary() ?: (configSessionVersion + 1)
    }

    private suspend fun loadProtectedSession(): ProtectedSession? = when (val loaded = credentialStore.load()) {
        CredentialLoad.Empty -> {
            protectedSession = null
            pendingTransition = null
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
            outboxStore.clearAll()
            logger.log(SafeLogEvent(SafeLogCode.CREDENTIAL_INVALIDATED, configuration.sdkVersion))
            null
        }
    }

    private suspend fun exchange(operation: SessionOperation, installationId: String): SessionResult {
        val startedAt = nowMs()
        logger.log(SafeLogEvent(SafeLogCode.SESSION_EXCHANGE_STARTED, configuration.sdkVersion))
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
                            detailCode = envelope.error.code.wireValue,
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
        mutableUnreadCount.value = null
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
            identifiedFirstName = firstNameClaim(userJwt)
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

    private fun firstNameClaim(jwt: String): String? = runCatching {
        val encoded = jwt.split('.')[1]
        val decoded = Base64.getUrlDecoder().decode(encoded)
        val name = JSONObject(String(decoded, Charsets.UTF_8)).optString("name").trim()
        require(name.isNotEmpty() && name.length <= 200 && name.none(Char::isISOControl))
        name.split(Regex("\\s+")).first()
    }.getOrNull()

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
        val version: Long,
        val api: WidgetChatApi,
    )

    private data class ConversationObservation(
        val authority: ConversationOpenAuthority,
        val generation: Long,
    )

    private data class PushPayloadCapture(
        val registry: PushRegistry,
        val authority: PushAuthority?,
        val persistenceAuthority: PersistenceAuthority?,
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
        const val DEFAULT_BACKOFF_MS = 1_000L
        const val MAX_BACKOFF_MS = 30_000L
        const val MAX_BACKOFF_EXPONENT = 5
    }
}
