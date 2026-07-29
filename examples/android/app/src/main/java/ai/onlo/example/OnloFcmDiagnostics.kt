package ai.onlo.example

import android.text.format.DateFormat
import android.util.Log
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import java.util.Date

/**
 * Process-local, privacy-safe diagnostics for the example host UI and Logcat.
 * Never pass tokens, payload values, customer identifiers, or message content.
 */
object OnloFcmDiagnostics {
    private const val LOG_TAG = "OnloFCM"
    private const val MAX_LINES = 100
    private val lock = Any()
    private val mutableLines = MutableStateFlow<List<String>>(emptyList())

    val lines = mutableLines.asStateFlow()

    fun info(event: String) {
        Log.i(LOG_TAG, event)
        append("INFO", event)
    }

    fun warn(event: String) {
        Log.w(LOG_TAG, event)
        append("WARN", event)
    }

    fun clear() {
        synchronized(lock) {
            mutableLines.value = emptyList()
        }
    }

    private fun append(level: String, event: String) {
        val timestamp = DateFormat.format("HH:mm:ss", Date()).toString()
        synchronized(lock) {
            mutableLines.value = (mutableLines.value + "$timestamp $level $event").takeLast(MAX_LINES)
        }
    }
}
