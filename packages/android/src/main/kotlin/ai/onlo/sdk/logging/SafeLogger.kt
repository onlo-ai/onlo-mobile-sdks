package ai.onlo.sdk.logging

import ai.onlo.sdk.OnloLogLevel
import android.util.Log

/** Deliberately excludes credentials, proofs, message text, tokens, and attachment URLs. */
internal data class SafeLogEvent(
    val code: SafeLogCode,
    val sdkVersion: String,
    val runtimePlatform: String = "android",
    val requestId: String? = null,
    val detailCode: String? = null,
    val durationMs: Long? = null,
)

internal enum class SafeLogCode {
    SESSION_EXCHANGE_STARTED,
    SESSION_EXCHANGE_SUCCEEDED,
    SESSION_EXCHANGE_FAILED,
    CREDENTIAL_INVALIDATED,
    PROTOCOL_REJECTED,
    LOGOUT_PENDING,
}

internal fun interface SafeLogger {
    fun log(event: SafeLogEvent)
}

internal class AndroidSafeLogger : SafeLogger {
    override fun log(event: SafeLogEvent) {
        val required = event.requiredLevel()
        if (configuredLevel.ordinal < required.ordinal) return
        val fields = buildList {
            add("code=${event.code.name.lowercase()}")
            add("sdkVersion=${event.sdkVersion.safeLogField()}")
            add("runtime=${event.runtimePlatform.safeLogField()}")
            event.requestId?.let { add("requestId=${it.safeLogField()}") }
            event.detailCode?.let { add("detailCode=${it.safeLogField()}") }
            event.durationMs?.let { add("durationMs=${it.coerceAtLeast(0)}") }
        }
        val message = fields.joinToString(" ")
        when (required) {
            OnloLogLevel.ERROR -> Log.e(TAG, message)
            OnloLogLevel.INFO -> Log.i(TAG, message)
            OnloLogLevel.VERBOSE -> Log.d(TAG, message)
            OnloLogLevel.OFF -> Unit
        }
    }

    internal companion object {
        const val TAG = "OnloSDK"

        @Volatile
        private var configuredLevel: OnloLogLevel = OnloLogLevel.OFF

        fun setLevel(level: OnloLogLevel) {
            configuredLevel = level
        }
    }
}

internal fun SafeLogEvent.requiredLevel(): OnloLogLevel = when (code) {
    SafeLogCode.SESSION_EXCHANGE_STARTED -> OnloLogLevel.VERBOSE
    SafeLogCode.SESSION_EXCHANGE_SUCCEEDED -> OnloLogLevel.INFO
    SafeLogCode.SESSION_EXCHANGE_FAILED,
    SafeLogCode.CREDENTIAL_INVALIDATED,
    SafeLogCode.PROTOCOL_REJECTED,
    SafeLogCode.LOGOUT_PENDING -> OnloLogLevel.ERROR
}

internal fun String.safeLogField(): String = take(128).map { character ->
    if (character.isLetterOrDigit() || character in "._:-") character else '_'
}.joinToString("")
