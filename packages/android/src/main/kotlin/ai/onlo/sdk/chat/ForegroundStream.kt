package ai.onlo.sdk.chat

import ai.onlo.sdk.protocol.ProtocolViolation
import ai.onlo.sdk.transport.OnloSseTransport
import ai.onlo.sdk.transport.ProtocolRequestFactory
import org.json.JSONObject

/** Foreground stream is hint-only: every inbox event requires an authorised transcript refetch. */
internal sealed interface ForegroundHint {
    data object Ready : ForegroundHint
    data class ConfigChanged(val revision: String) : ForegroundHint
    data class Conversation(val conversationId: String) : ForegroundHint
    data class Message(val conversationId: String) : ForegroundHint
}

internal class ForegroundStream(
    private val transport: OnloSseTransport,
    private val requests: ProtocolRequestFactory,
) {
    suspend fun collect(chatToken: String, onHint: suspend (ForegroundHint) -> Unit) {
        val frame = StringBuilder()
        val result = transport.stream(requests.stream(chatToken)) { line ->
            if (line.startsWith("data:")) {
                if (frame.isNotEmpty()) frame.append('\n')
                frame.append(line.removePrefix("data:").trimStart())
                if (frame.length > 64 * 1024) throw ProtocolViolation("stream_frame")
            } else if (line.isEmpty() && frame.isNotEmpty()) {
                val hint = parse(frame.toString())
                if (hint != null) onHint(hint)
                frame.clear()
            }
        }
        if (frame.isNotEmpty()) {
            val hint = parse(frame.toString())
            if (hint != null) onHint(hint)
        }
        if (result !is ai.onlo.sdk.transport.SseStreamResult.Success) throw java.io.IOException("stream_unavailable")
    }

    /** Invalid/unknown stream data is ignored: it is a hint channel, never authority. */
    private fun parse(raw: String): ForegroundHint? = try {
        val value = JSONObject(raw)
        when (value.getString("type")) {
            "ready" -> if (value.length() == 1) ForegroundHint.Ready else null
            "config_changed" -> value.getString("revision").takeIf(String::isNotBlank)?.let(ForegroundHint::ConfigChanged)
            "inbox.conversation" -> value.getString("conversationId").takeIf(String::isNotBlank)?.let(ForegroundHint::Conversation)
            "inbox.message" -> value.getString("conversationId").takeIf(String::isNotBlank)?.let(ForegroundHint::Message)
            else -> null
        }
    } catch (_: Exception) { null }
}
