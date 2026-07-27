package ai.onlo.flutter

import ai.onlo.sdk.LogoutOutcome
import ai.onlo.sdk.OnloClient
import ai.onlo.sdk.OnloException
import ai.onlo.sdk.OnloFlutterBridge
import ai.onlo.sdk.OnloIdentityState
import ai.onlo.sdk.OnloLogLevel
import ai.onlo.sdk.OnloPhase
import ai.onlo.sdk.OnloState
import ai.onlo.sdk.Onlo
import ai.onlo.sdk.OpenConversationOutcome
import ai.onlo.sdk.messenger.OnloMessenger
import ai.onlo.sdk.messenger.OnloMessengerOptions
import ai.onlo.sdk.messenger.OnloMessengerPresentationMode
import ai.onlo.sdk.protocol.NotificationPreference
import ai.onlo.sdk.protocol.PushProvider
import ai.onlo.sdk.push.PushPayloadOutcome
import ai.onlo.sdk.push.PushRegistrationOutcome
import android.app.Activity
import android.content.Context
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.launch

/**
 * A method/event-channel facade over the Android core. It does not retain a
 * Dart-visible copy of credentials, transcripts, outbox rows, or push tokens.
 */
public class OnloFlutterPlugin : FlutterPlugin, MethodChannel.MethodCallHandler,
    EventChannel.StreamHandler, ActivityAware {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private var applicationContext: Context? = null
    private var methodChannel: MethodChannel? = null
    private var eventChannel: EventChannel? = null
    private var activity: Activity? = null
    private var client: OnloClient? = null
    private var initializedSdkKey: String? = null
    private var stateCollector: Job? = null
    private var unreadCollector: Job? = null
    private var eventSink: EventChannel.EventSink? = null
    private var latestState: OnloState? = null
    private var latestUnreadCount: Int? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        applicationContext = binding.applicationContext
        methodChannel = MethodChannel(binding.binaryMessenger, METHOD_CHANNEL).also {
            it.setMethodCallHandler(this)
        }
        eventChannel = EventChannel(binding.binaryMessenger, STATE_CHANNEL).also {
            it.setStreamHandler(this)
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        eventSink = null
        stateCollector?.cancel()
        unreadCollector?.cancel()
        stateCollector = null
        unreadCollector = null
        methodChannel?.setMethodCallHandler(null)
        eventChannel?.setStreamHandler(null)
        methodChannel = null
        eventChannel = null
        applicationContext = null
        client = null
        initializedSdkKey = null
        latestState = null
        latestUnreadCount = null
        scope.cancel()
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) { activity = binding.activity }
    override fun onDetachedFromActivityForConfigChanges() { activity = null }
    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) { activity = binding.activity }
    override fun onDetachedFromActivity() { activity = null }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "setLogLevel" -> {
                val level = when (call.arguments as? String) {
                    "off" -> OnloLogLevel.OFF
                    "error" -> OnloLogLevel.ERROR
                    "info" -> OnloLogLevel.INFO
                    "verbose" -> OnloLogLevel.VERBOSE
                    else -> return result.safeError("invalid_argument")
                }
                Onlo.setLogLevel(level)
                result.success(null)
            }
            "initialize" -> initialize(call, result)
            "loginUnidentifiedUser" -> operation(result) { requireClient().loginUnidentifiedUser() }
            "loginIdentifiedUser" -> {
                val jwt = call.string("userJwt") ?: return result.safeError("invalid_argument")
                operation(result) { requireClient().loginIdentifiedUser(jwt) }
            }
            "logout" -> operation(result) {
                when (requireClient().logout()) {
                    LogoutOutcome.Completed, LogoutOutcome.AlreadyAnonymous -> Unit
                    is LogoutOutcome.Pending -> throw BridgeFailure("native_operation_failed")
                }
            }
            "present" -> present(call, result)
            "dismiss" -> operation(result) {
                requireClient().dismiss()
                OnloMessenger.dismiss()
            }
            "openConversation" -> {
                val conversationId = call.string("conversationId") ?: return result.safeError("invalid_argument")
                openConversation(conversationId, result)
            }
            "setPushToken" -> setPushToken(call, result)
            "handlePushNotification" -> handlePushNotification(call, result)
            else -> result.notImplemented()
        }
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
        eventSink = events
        client?.let(::collectState)
        latestState?.let(::emitState)
    }

    override fun onCancel(arguments: Any?) { eventSink = null }

    private fun initialize(call: MethodCall, result: MethodChannel.Result) {
        val sdkKey = call.string("sdkKey") ?: return result.safeError("invalid_argument")
        val existing = initializedSdkKey
        if (existing != null && existing != sdkKey) return result.safeError("native_operation_failed")
        operation(result) {
            val context = applicationContext ?: throw BridgeFailure("native_bridge_unavailable")
            val core = OnloFlutterBridge.initialize(context, sdkKey)
            client = core
            initializedSdkKey = sdkKey
            collectState(core)
        }
    }

    private fun present(call: MethodCall, result: MethodChannel.Result) {
        val rawConversationId = (call.arguments as? Map<*, *>)?.get("conversationId")
        if (rawConversationId != null && (rawConversationId !is String || rawConversationId.isBlank())) {
            return result.safeError("invalid_argument")
        }
        val conversationId = rawConversationId as? String
        val rawPresentationMode = call.optionalString("presentationMode")
        if (call.hasArgument("presentationMode") && rawPresentationMode == null) {
            return result.safeError("invalid_argument")
        }
        val presentationMode = when (rawPresentationMode) {
            null, "contained" -> OnloMessengerPresentationMode.CONTAINED
            "fullScreen" -> OnloMessengerPresentationMode.FULL_SCREEN
            else -> return result.safeError("invalid_argument")
        }
        val messengerOptions = OnloMessengerOptions(presentationMode = presentationMode)
        if (conversationId != null) {
            openConversation(conversationId, result, messengerOptions)
            return
        }
        operation(result) {
            val host = requireActivity()
            OnloMessenger.present(host, messengerOptions, requireClient())
        }
    }

    private fun openConversation(
        conversationId: String,
        result: MethodChannel.Result,
        options: OnloMessengerOptions = OnloMessengerOptions(),
    ) = operation(result) {
        val host = requireActivity()
        // This helper performs exactly one native authorization/refetch before
        // it attaches a native dialog. Dart receives no transcript content.
        when (OnloMessenger.openConversation(host, conversationId, options, requireClient())) {
            OpenConversationOutcome.NoActiveSession -> throw BridgeFailure("native_operation_failed")
            OpenConversationOutcome.NotAuthorised -> throw BridgeFailure("forbidden_principal")
            OpenConversationOutcome.Unavailable -> throw BridgeFailure("native_operation_failed")
            OpenConversationOutcome.Opened -> Unit
        }
    }

    private fun setPushToken(call: MethodCall, result: MethodChannel.Result) {
        val provider = when (call.string("provider")) {
            "fcm" -> PushProvider.FCM
            // APNs is never valid on the Android runtime.
            else -> return result.safeError("invalid_argument")
        }
        val token = call.string("token") ?: return result.safeError("invalid_argument")
        val preference = when (val value = call.optionalString("notificationPreference")) {
            null -> null
            "enabled" -> NotificationPreference.ENABLED
            "muted" -> NotificationPreference.MUTED
            else -> return result.safeError("invalid_argument")
        }
        val locale = call.optionalString("locale")
        if (call.hasArgument("locale") && locale == null) return result.safeError("invalid_argument")
        operation(result) {
            when (val outcome = requireClient().registerPushToken(provider, token, preference, locale)) {
                PushRegistrationOutcome.Registered,
                PushRegistrationOutcome.QueuedForReconciliation -> Unit
                PushRegistrationOutcome.UnsupportedProvider,
                PushRegistrationOutcome.InvalidToken -> throw BridgeFailure("invalid_argument")
                else -> throw BridgeFailure("native_operation_failed")
            }
        }
    }

    private fun handlePushNotification(call: MethodCall, result: MethodChannel.Result) {
        val conversationId = call.string("conversationId") ?: return result.safeError("invalid_argument")
        val messageId = call.string("messageId") ?: return result.safeError("invalid_argument")
        if (call.string("notificationType") != "message_available") return result.safeError("invalid_argument")
        resultOperation(result) {
            when (val outcome = requireClient().handlePushPayload(mapOf(
                "conversationId" to conversationId,
                "messageId" to messageId,
                "notificationType" to "message_available",
            ))) {
                PushPayloadOutcome.NotOnlo,
                PushPayloadOutcome.Malformed,
                PushPayloadOutcome.NotAuthorised -> "notOnlo"
                PushPayloadOutcome.NoActiveSession,
                PushPayloadOutcome.RefetchFailed -> "deferred"
                is PushPayloadOutcome.NavigationIntent -> {
                    val host = activity
                    if (host == null || host.isFinishing || host.isDestroyed) "deferred"
                    else when (OnloMessenger.openConversation(host, outcome.conversationId, requireClient())) {
                        OpenConversationOutcome.Opened -> "handled"
                        OpenConversationOutcome.NotAuthorised -> "notOnlo"
                        OpenConversationOutcome.NoActiveSession,
                        OpenConversationOutcome.Unavailable -> "deferred"
                    }
                }
            }
        }
    }

    private fun collectState(core: OnloClient) {
        if (stateCollector != null) return
        stateCollector = scope.launch {
            core.state.collect { state ->
                latestState = state
                emitState(state)
            }
        }
        unreadCollector = scope.launch {
            core.unreadCount.collect { count ->
                latestUnreadCount = count
                latestState?.let(::emitState)
            }
        }
    }

    private fun emitState(state: OnloState) {
        val sink = eventSink ?: return
        sink.success(buildMap<String, Any?> {
            put("session", state.phase.wireValue())
            put("identity", state.identity.wireValue())
            put("connection", state.phase.connectionValue())
            put("unreadCount", latestUnreadCount)
        })
    }

    private fun requireClient(): OnloClient = client ?: throw BridgeFailure("native_bridge_unavailable")
    private fun requireActivity(): Activity = activity
        ?.takeIf { !it.isFinishing && !it.isDestroyed }
        ?: throw BridgeFailure("native_operation_failed")

    private fun operation(result: MethodChannel.Result, block: suspend () -> Unit) {
        scope.launch {
            try {
                block()
                result.success(null)
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (failure: Throwable) {
                result.fromFailure(failure)
            }
        }
    }

    private fun resultOperation(result: MethodChannel.Result, block: suspend () -> String) {
        scope.launch {
            try {
                result.success(block())
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (failure: Throwable) {
                result.fromFailure(failure)
            }
        }
    }

    private companion object {
        const val METHOD_CHANNEL = "ai.onlo/onlo_flutter"
        const val STATE_CHANNEL = "ai.onlo/onlo_flutter/state"
    }
}

private data class BridgeFailure(val code: String) : IllegalStateException(code)

private fun MethodCall.optionalString(key: String): String? = (arguments as? Map<*, *>)?.get(key) as? String
private fun MethodCall.string(key: String): String? = optionalString(key)?.takeIf { it.isNotBlank() }
private fun MethodCall.hasArgument(key: String): Boolean = (arguments as? Map<*, *>)?.containsKey(key) == true

private fun MethodChannel.Result.safeError(code: String) = error(code, "Onlo operation failed ($code).", mapOf("code" to code))

private fun MethodChannel.Result.fromFailure(failure: Throwable) {
    val code = when (failure) {
        is BridgeFailure -> failure.code
        is OnloException.Server -> failure.code
        OnloException.InvalidUserJwt, is IllegalArgumentException -> "invalid_argument"
        else -> "native_operation_failed"
    }
    error(code, "Onlo operation failed ($code).", mapOf("code" to code))
}

private fun OnloPhase.wireValue(): String = when (this) {
    OnloPhase.RESTORING -> "restoring"
    OnloPhase.ANONYMOUS_READY -> "anonymousReady"
    OnloPhase.IDENTIFYING -> "identifying"
    OnloPhase.IDENTIFIED_READY -> "identifiedReady"
    OnloPhase.OFFLINE_READY -> "offlineReady"
    OnloPhase.REAUTHENTICATION_REQUIRED -> "reauthRequired"
    OnloPhase.LOGOUT_PENDING -> "logoutPending"
}

private fun OnloIdentityState.wireValue(): String = when (this) {
    OnloIdentityState.UNKNOWN -> "unknown"
    OnloIdentityState.ANONYMOUS -> "anonymous"
    OnloIdentityState.IDENTIFIED -> "identified"
}

private fun OnloPhase.connectionValue(): String = when (this) {
    OnloPhase.RESTORING -> "uninitialized"
    OnloPhase.ANONYMOUS_READY,
    OnloPhase.IDENTIFYING,
    OnloPhase.IDENTIFIED_READY -> "ready"
    OnloPhase.OFFLINE_READY -> "offline"
    OnloPhase.LOGOUT_PENDING, OnloPhase.REAUTHENTICATION_REQUIRED -> "unavailable"
}
