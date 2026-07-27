package ai.onlo.reactnative

import ai.onlo.sdk.LogoutOutcome
import ai.onlo.sdk.OnloClient
import ai.onlo.sdk.OnloException
import ai.onlo.sdk.OnloIdentityState
import ai.onlo.sdk.OnloLogLevel
import ai.onlo.sdk.OnloPhase
import ai.onlo.sdk.OnloReactNativeBridge
import ai.onlo.sdk.Onlo
import ai.onlo.sdk.OpenConversationOutcome
import ai.onlo.sdk.protocol.NotificationPreference
import ai.onlo.sdk.protocol.PushProvider
import ai.onlo.sdk.protocol.RetryDirective
import ai.onlo.sdk.push.PushPayloadOutcome
import ai.onlo.sdk.push.PushRegistrationOutcome
import ai.onlo.sdk.messenger.OnloMessenger
import ai.onlo.sdk.messenger.OnloMessengerOptions
import ai.onlo.sdk.messenger.OnloMessengerPresentationMode
import android.app.Activity
import com.facebook.react.bridge.Arguments
import com.facebook.react.bridge.Promise
import com.facebook.react.bridge.ReactApplicationContext
import com.facebook.react.bridge.ReactMethod
import com.facebook.react.bridge.ReadableMap
import com.facebook.react.bridge.ReadableType
import com.facebook.react.bridge.WritableMap
import com.facebook.react.module.annotations.ReactModule
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.launch

/**
 * Thin Android TurboModule. It owns no credential, transcript, outbox, token, or message state;
 * every operation is delegated to the Android native core.
 */
@ReactModule(name = OnloSDKModule.NAME)
public class OnloSDKModule(
    reactContext: ReactApplicationContext,
) : NativeOnloSDKSpec(reactContext) {
    private val moduleScope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private var client: OnloClient? = null
    private var initializedSdkKey: String? = null
    private var stateCollector: Job? = null
    private var unreadCollector: Job? = null
    private var emittedConnection: String? = null

    override fun getName(): String = NAME

    @ReactMethod
    override fun setLogLevel(level: String, promise: Promise) {
        val parsed = when (level) {
            "off" -> OnloLogLevel.OFF
            "error" -> OnloLogLevel.ERROR
            "info" -> OnloLogLevel.INFO
            "verbose" -> OnloLogLevel.VERBOSE
            else -> return promise.rejectSafe("invalid_argument")
        }
        Onlo.setLogLevel(parsed)
        promise.resolve(null)
    }

    @ReactMethod
    override fun initialize(options: ReadableMap, promise: Promise) {
        val sdkKey = options.requiredNonBlankString("sdkKey")
            ?: return promise.rejectSafe("invalid_argument")
        val previous = initializedSdkKey
        if (previous != null && previous != sdkKey) {
            promise.rejectSafe("native_operation_failed")
            return
        }
        runOperation(promise) {
            val initialized = OnloReactNativeBridge.initialize(reactApplicationContext, sdkKey)
            client = initialized
            initializedSdkKey = sdkKey
            collectCoreState(initialized)
        }
    }

    @ReactMethod
    override fun loginUnidentifiedUser(promise: Promise) = runOperation(promise) {
        requireClient().loginUnidentifiedUser()
    }

    @ReactMethod
    override fun loginIdentifiedUser(options: ReadableMap, promise: Promise) {
        val userJwt = options.requiredNonBlankString("userJwt")
            ?: return promise.rejectSafe("invalid_argument")
        runOperation(promise) { requireClient().loginIdentifiedUser(userJwt) }
    }

    @ReactMethod
    override fun logout(promise: Promise) = runOperation(promise) {
        when (val outcome = requireClient().logout()) {
            LogoutOutcome.Completed, LogoutOutcome.AlreadyAnonymous -> Unit
            is LogoutOutcome.Pending -> throw BridgeFailure("native_operation_failed")
        }
    }

    @ReactMethod
    override fun present(options: ReadableMap?, promise: Promise) {
        val presentationMode = when (val value = options?.optionalString("presentationMode")) {
            null -> {
                if (options?.hasKey("presentationMode") == true) {
                    promise.rejectSafe("invalid_argument")
                    return
                }
                OnloMessengerPresentationMode.CONTAINED
            }
            "contained" -> OnloMessengerPresentationMode.CONTAINED
            "fullScreen" -> OnloMessengerPresentationMode.FULL_SCREEN
            else -> {
                promise.rejectSafe("invalid_argument")
                return
            }
        }
        val messengerOptions = OnloMessengerOptions(presentationMode = presentationMode)
        if (options != null && options.hasKey("conversationId")) {
            val conversationId = options.requiredNonBlankString("conversationId")
                ?: return promise.rejectSafe("invalid_argument")
            openConversationInternal(conversationId, messengerOptions, promise)
            return
        }
        runOperation(promise) {
            OnloMessenger.present(requireCurrentActivity(), messengerOptions, requireClient())
        }
    }

    @ReactMethod
    override fun dismiss(promise: Promise) = runOperation(promise) {
        // Preserve the core intent even when no dialog is currently attached.
        requireClient().dismiss()
        OnloMessenger.dismiss()
    }

    @ReactMethod
    override fun openConversation(conversationId: String, promise: Promise) {
        if (conversationId.isBlank()) {
            promise.rejectSafe("invalid_argument")
            return
        }
        openConversationInternal(conversationId, OnloMessengerOptions(), promise)
    }

    @ReactMethod
    override fun setPushToken(options: ReadableMap, promise: Promise) {
        val provider = when (options.requiredNonBlankString("provider")) {
            "fcm" -> PushProvider.FCM
            "apns" -> PushProvider.APNS
            else -> return promise.rejectSafe("invalid_argument")
        }
        val token = options.requiredNonBlankString("token")
            ?: return promise.rejectSafe("invalid_argument")
        val preference = when (val value = options.optionalString("notificationPreference")) {
            null -> null
            "enabled" -> NotificationPreference.ENABLED
            "muted" -> NotificationPreference.MUTED
            else -> return promise.rejectSafe("invalid_argument")
        }
        val locale = options.optionalString("locale")
        if (options.hasKey("locale") && locale.isNullOrBlank()) {
            promise.rejectSafe("invalid_argument")
            return
        }
        runOperation(promise) {
            when (val outcome = requireClient().registerPushToken(provider, token, preference, locale)) {
                PushRegistrationOutcome.Registered,
                PushRegistrationOutcome.QueuedForReconciliation -> Unit
                PushRegistrationOutcome.UnsupportedProvider,
                PushRegistrationOutcome.InvalidToken -> throw BridgeFailure("invalid_argument")
                is PushRegistrationOutcome.PendingServer ->
                    throw BridgeFailure("native_operation_failed", outcome.directive)
                PushRegistrationOutcome.TerminalServerFailure ->
                    throw BridgeFailure("native_operation_failed", RetryDirective.NEVER)
                PushRegistrationOutcome.NoToken,
                PushRegistrationOutcome.NoActiveSession,
                PushRegistrationOutcome.InvalidResponse,
                PushRegistrationOutcome.BlockedByRetiringOwner,
                PushRegistrationOutcome.Unregistered -> throw BridgeFailure("native_operation_failed")
            }
        }
    }

    @ReactMethod
    override fun handlePushNotification(payload: ReadableMap, promise: Promise) {
        val conversationId = payload.requiredNonBlankString("conversationId")
            ?: return promise.rejectSafe("invalid_argument")
        val messageId = payload.requiredNonBlankString("messageId")
            ?: return promise.rejectSafe("invalid_argument")
        if (payload.requiredNonBlankString("notificationType") != "message_available") {
            promise.rejectSafe("invalid_argument")
            return
        }
        runResultOperation(promise) {
            val core = requireClient()
            when (val outcome = core.handlePushPayload(
                mapOf(
                    "conversationId" to conversationId,
                    "messageId" to messageId,
                    "notificationType" to "message_available",
                ),
            )) {
                PushPayloadOutcome.NotOnlo,
                PushPayloadOutcome.Malformed,
                PushPayloadOutcome.NotAuthorised -> "notOnlo"
                PushPayloadOutcome.NoActiveSession,
                PushPayloadOutcome.RefetchFailed -> "deferred"
                is PushPayloadOutcome.NavigationIntent -> {
                    val activity = availableCurrentActivity() ?: return@runResultOperation "deferred"
                    when (OnloMessenger.openConversation(activity, outcome.conversationId, core)) {
                        OpenConversationOutcome.Opened -> "handled"
                        OpenConversationOutcome.Unavailable,
                        OpenConversationOutcome.NoActiveSession -> "deferred"
                        OpenConversationOutcome.NotAuthorised -> "notOnlo"
                    }
                }
            }
        }
    }

    override fun invalidate() {
        stateCollector?.cancel()
        unreadCollector?.cancel()
        moduleScope.cancel()
        client = null
        initializedSdkKey = null
        super.invalidate()
    }

    private fun openConversationInternal(
        conversationId: String,
        options: OnloMessengerOptions,
        promise: Promise,
    ) = runOperation(promise) {
        when (OnloMessenger.openConversation(requireCurrentActivity(), conversationId, options, requireClient())) {
            OpenConversationOutcome.Opened -> Unit
            OpenConversationOutcome.NoActiveSession -> throw BridgeFailure("native_operation_failed")
            OpenConversationOutcome.NotAuthorised -> throw BridgeFailure("native_operation_failed")
            OpenConversationOutcome.Unavailable -> throw BridgeFailure("native_operation_failed")
        }
    }

    private fun collectCoreState(core: OnloClient) {
        if (stateCollector != null) return
        emittedConnection = null
        stateCollector = moduleScope.launch {
            core.state.collect { value ->
                emitOnOnloEvent(Arguments.createMap().apply {
                    putString("type", "stateChanged")
                    putString("state", value.phase.bridgeValue())
                })
                emitOnOnloEvent(Arguments.createMap().apply {
                    putString("type", "identityChanged")
                    putString("identity", value.identity.bridgeValue())
                })
                val connection = value.phase.connectionValue()
                if (emittedConnection != connection) {
                    emittedConnection = connection
                    emitOnOnloEvent(Arguments.createMap().apply {
                        putString("type", "connectionChanged")
                        putString("connection", connection)
                    })
                }
                value.safeErrorCode?.let {
                    emitOnOnloEvent(Arguments.createMap().apply {
                        putString("type", "error")
                        putMap("error", bridgeErrorMap("native_operation_failed"))
                    })
                }
            }
        }
        unreadCollector = moduleScope.launch {
            core.unreadCount.collect { count ->
                emitOnOnloEvent(Arguments.createMap().apply {
                    putString("type", "unreadCountChanged")
                    if (count == null) putNull("unreadCount") else putInt("unreadCount", count)
                })
            }
        }
    }

    private fun requireClient(): OnloClient = client ?: throw BridgeFailure("native_bridge_unavailable")

    private fun availableCurrentActivity(): Activity? = currentActivity?.takeUnless {
        it.isFinishing || it.isDestroyed
    }

    private fun requireCurrentActivity(): Activity =
        availableCurrentActivity() ?: throw BridgeFailure("native_operation_failed")

    private fun runOperation(promise: Promise, operation: suspend () -> Unit) {
        moduleScope.launch {
            try {
                operation()
                promise.resolve(null)
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (failure: Throwable) {
                promise.rejectFailure(failure)
            }
        }
    }

    private fun runResultOperation(promise: Promise, operation: suspend () -> String) {
        moduleScope.launch {
            try {
                promise.resolve(operation())
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (failure: Throwable) {
                promise.rejectFailure(failure)
            }
        }
    }

    public companion object {
        public const val NAME: String = "OnloSDK"
    }
}

private data class BridgeFailure(
    val code: String,
    val retry: RetryDirective? = null,
) : IllegalStateException(code)

private data class FailureDescriptor(val code: String, val retry: RetryDirective? = null)

private fun Throwable.descriptor(): FailureDescriptor = when (this) {
    is BridgeFailure -> FailureDescriptor(code, retry)
    is OnloException.Server -> FailureDescriptor(code, retry)
    OnloException.InvalidUserJwt -> FailureDescriptor("invalid_argument")
    is IllegalArgumentException -> FailureDescriptor("invalid_argument")
    else -> FailureDescriptor("native_operation_failed")
}

private fun Promise.rejectFailure(failure: Throwable) {
    val descriptor = failure.descriptor()
    reject(
        descriptor.code,
        "Onlo operation failed (${descriptor.code}).",
        bridgeErrorMap(descriptor.code, descriptor.retry),
    )
}

private fun Promise.rejectSafe(code: String) {
    reject(code, "Onlo operation failed ($code).", bridgeErrorMap(code))
}

private fun bridgeErrorMap(code: String, retry: RetryDirective? = null): WritableMap =
    Arguments.createMap().apply {
        putString("code", code)
        retry?.let { directive ->
            putMap("retry", Arguments.createMap().apply {
                putString("directive", directive.wireValue)
            })
        }
    }

private fun ReadableMap.requiredNonBlankString(key: String): String? =
    optionalString(key)?.takeIf { it.isNotBlank() }

private fun ReadableMap.optionalString(key: String): String? =
    if (hasKey(key) && !isNull(key) && getType(key) == ReadableType.String) getString(key) else null

private fun OnloPhase.bridgeValue(): String = when (this) {
    OnloPhase.RESTORING -> "restoring"
    OnloPhase.ANONYMOUS_READY -> "anonymousReady"
    OnloPhase.IDENTIFYING -> "identifying"
    OnloPhase.IDENTIFIED_READY -> "identifiedReady"
    OnloPhase.OFFLINE_READY -> "offlineReady"
    OnloPhase.REAUTHENTICATION_REQUIRED -> "reauthRequired"
    OnloPhase.LOGOUT_PENDING -> "logoutPending"
}

private fun OnloIdentityState.bridgeValue(): String = when (this) {
    OnloIdentityState.UNKNOWN -> "unknown"
    OnloIdentityState.ANONYMOUS -> "anonymous"
    OnloIdentityState.IDENTIFIED -> "identified"
}

/** This is a phase projection, not a second connection/session state machine. */
private fun OnloPhase.connectionValue(): String = when (this) {
    OnloPhase.RESTORING -> "uninitialized"
    OnloPhase.ANONYMOUS_READY,
    OnloPhase.IDENTIFYING,
    OnloPhase.IDENTIFIED_READY -> "ready"
    OnloPhase.OFFLINE_READY -> "offline"
    OnloPhase.REAUTHENTICATION_REQUIRED,
    OnloPhase.LOGOUT_PENDING -> "unavailable"
}
