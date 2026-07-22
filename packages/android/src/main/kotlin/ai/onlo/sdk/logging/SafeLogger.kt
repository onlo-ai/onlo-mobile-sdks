package ai.onlo.sdk.logging

import android.util.Log

/** Deliberately excludes credentials, proofs, message text, tokens, and attachment URLs. */
internal data class SafeLogEvent(
    val code: SafeLogCode,
    val sdkVersion: String,
    val runtimePlatform: String = "android",
    val requestId: String? = null,
    val durationMs: Long? = null,
)

internal enum class SafeLogCode {
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
        val fields = buildList {
            add("code=${event.code.name.lowercase()}")
            add("sdkVersion=${event.sdkVersion}")
            add("runtime=${event.runtimePlatform}")
            event.requestId?.let { add("requestId=$it") }
            event.durationMs?.let { add("durationMs=$it") }
        }
        Log.i(TAG, fields.joinToString(" "))
    }

    private companion object {
        const val TAG = "OnloSDK"
    }
}
