package ai.onlo.sdk.chat

import ai.onlo.sdk.protocol.ChatRequest
import ai.onlo.sdk.protocol.ChatAttachment
import ai.onlo.sdk.protocol.ConversationPageQuery
import ai.onlo.sdk.storage.OutboxEntry
import ai.onlo.sdk.storage.OutboxEntryFactory
import ai.onlo.sdk.storage.OwnerScope
import ai.onlo.sdk.storage.OwnerScopedOutboxStore
import ai.onlo.sdk.transport.OnloSseTransport
import ai.onlo.sdk.transport.SseStreamResult
import ai.onlo.sdk.transport.OnloTransport
import ai.onlo.sdk.transport.ProtocolRequestFactory
import org.json.JSONObject
import kotlin.math.min
import kotlin.random.Random
import kotlinx.coroutines.CancellationException

/** Parsed contract events only; neither tokens nor message content are logged by this layer. */
internal sealed interface ChatEvent {
    data class Accepted(val clientMessageId: String, val messageId: String, val conversationId: String, val acceptedAt: String, val duplicate: Boolean, val processingStatus: String) : ChatEvent
    data class Text(val content: String) : ChatEvent
    data class Done(val conversationId: String, val duplicate: Boolean?, val processingStatus: String?, val gated: Boolean?, val reason: String?) : ChatEvent
    data class Error(val error: String, val retryable: Boolean) : ChatEvent
}
internal data class SendOutcome(val accepted: ChatEvent.Accepted?, val error: ChatEvent.Error?)

internal data class TranscriptMessage(val id: String, val externalId: String?, val role: String, val senderType: String?, val senderName: String?, val senderTeam: String?, val text: String, val attachments: List<String>, val timestamp: Long)
internal data class ConversationDetail(val id: String, val sessionId: String, val status: String, val isHumanTakeover: Boolean, val messages: List<TranscriptMessage>, val previousCursor: String?, val nextCursor: String?, val limit: Int)
/** Contract-backed inbox summary. It is used only by the native messenger, never a bridge. */
internal data class ConversationSummary(
    val id: String,
    val sessionId: String,
    val title: String,
    val unread: Boolean,
    val unreadCount: Int,
    val status: String,
    val updatedAt: String,
    val messageCount: Int,
    val lastMessageRole: String?,
)

/** Contract-exact widget routes. Widget errors are plain JSON, not v1 envelopes. */
internal class WidgetChatApi(
    private val transport: OnloTransport,
    private val requests: ProtocolRequestFactory,
    private val sseTransport: OnloSseTransport? = transport as? OnloSseTransport,
) {
    suspend fun send(
        chatToken: String,
        request: ChatRequest,
        onAccepted: suspend (ChatEvent.Accepted) -> Unit = {},
        onEvent: suspend (ChatEvent) -> Unit = {},
    ): SendOutcome {
        val streaming = sseTransport ?: throw java.io.IOException("sse_transport_unavailable")
        var accepted: ChatEvent.Accepted? = null; var error: ChatEvent.Error? = null
        val frame = StringBuilder()
        suspend fun dispatch(event: ChatEvent) {
            if (event is ChatEvent.Accepted) {
                accepted = event
                onAccepted(event)
            }
            if (event is ChatEvent.Error) error = event
            onEvent(event)
        }
        val result = streaming.stream(requests.chat(chatToken, request)) { line ->
            if (line.startsWith("data:")) {
                if (frame.isNotEmpty()) frame.append('\n')
                frame.append(line.removePrefix("data:").trimStart())
                if (frame.length > 64 * 1024) throw ai.onlo.sdk.protocol.ProtocolViolation("sse_frame")
            } else if (line.isEmpty() && frame.isNotEmpty()) {
                dispatch(parseEvent(frame.toString())); frame.clear()
            }
        }
        if (frame.isNotEmpty()) dispatch(parseEvent(frame.toString()))
        if (result is SseStreamResult.Success) return SendOutcome(accepted, error)
        result as SseStreamResult.Failure
        val error = try { JSONObject(result.errorBody).getString("error").filter { it.isLetterOrDigit() || it == '_' || it == '-' }.take(80).ifEmpty { throw IllegalArgumentException() } } catch (_: Exception) { throw ai.onlo.sdk.protocol.ProtocolViolation("widget_error") }
        return SendOutcome(null, ChatEvent.Error(error, false))
    }

    suspend fun transcript(chatToken: String, conversationId: String, page: ConversationPageQuery, expectedSessionId: String): ConversationDetail {
        val response = transport.execute(requests.transcript(chatToken, conversationId, page))
        if (response.status !in 200..299) throw WidgetFailure
        val root = try { JSONObject(response.body) } catch (_: Exception) { throw ai.onlo.sdk.protocol.ProtocolViolation("transcript") }; val conversation = try { root.getJSONObject("conversation") } catch (_: Exception) { throw ai.onlo.sdk.protocol.ProtocolViolation("transcript") }; val sync = try { root.getJSONObject("sync") } catch (_: Exception) { throw ai.onlo.sdk.protocol.ProtocolViolation("transcript") }
        if (conversation.optString("id") != conversationId) throw ai.onlo.sdk.protocol.ProtocolViolation("transcript_conversation")
        val messages = root.getJSONArray("messages")
        return ConversationDetail(conversation.getString("id"), conversation.getString("sessionId"), conversation.getString("status"), conversation.getBoolean("isHumanTakeover"), buildList {
            for (i in 0 until messages.length()) { val m = messages.getJSONObject(i); val rawAttachments = m.getJSONArray("attachments"); add(TranscriptMessage(m.getString("id"), m.optionalString("externalId"), m.getString("role"), m.optionalString("senderType"), m.optionalString("senderName"), m.optionalString("senderTeam"), m.getString("text"), buildList { for (j in 0 until rawAttachments.length()) add(rawAttachments.get(j).toString()) }, m.getLong("timestamp"))) }
        },
            previousCursor = sync.optString("previousCursor").takeUnless { it.isEmpty() || it == "null" },
            nextCursor = sync.optString("nextCursor").takeUnless { it.isEmpty() || it == "null" },
            limit = sync.getInt("limit"),
        ).also { if (it.sessionId != expectedSessionId) throw ai.onlo.sdk.protocol.ProtocolViolation("transcript_session") }
    }

    suspend fun conversations(chatToken: String, expectedSessionId: String, limit: Int = 50): List<ConversationSummary> {
        val response = transport.execute(requests.conversations(chatToken, limit))
        if (response.status !in 200..299) throw WidgetFailure
        val root = try { JSONObject(response.body) } catch (_: Exception) { throw ai.onlo.sdk.protocol.ProtocolViolation("conversation_list") }
        val values = try { root.getJSONArray("conversations") } catch (_: Exception) { throw ai.onlo.sdk.protocol.ProtocolViolation("conversation_list") }
        return buildList {
            for (index in 0 until values.length()) {
                val value = values.optJSONObject(index) ?: throw ai.onlo.sdk.protocol.ProtocolViolation("conversation_list")
                val summary = try {
                    ConversationSummary(
                        id = value.getString("id"),
                        sessionId = value.getString("sessionId"),
                        title = value.getString("title"),
                        unread = value.getBoolean("unread"),
                        unreadCount = value.getInt("unreadCount"),
                        status = value.getString("status"),
                        updatedAt = value.getString("updatedAt"),
                        messageCount = value.getInt("messageCount"),
                        lastMessageRole = value.optionalString("lastMessageRole"),
                    )
                } catch (_: Exception) { throw ai.onlo.sdk.protocol.ProtocolViolation("conversation_list") }
                if (summary.id.isBlank() || summary.sessionId != expectedSessionId || summary.unreadCount < 0 || summary.messageCount < 0) {
                    throw ai.onlo.sdk.protocol.ProtocolViolation("conversation_list")
                }
                add(summary)
            }
        }
    }
    private fun parseEvent(raw: String): ChatEvent {
        val event = try { JSONObject(raw) } catch (_: Exception) { throw ai.onlo.sdk.protocol.ProtocolViolation("chat_event") }
        return try { when (event.getString("type")) {
        "accepted" -> ChatEvent.Accepted(event.getString("clientMessageId"), event.getString("messageId"), event.getString("conversationId"), event.getString("acceptedAt"), event.getBoolean("duplicate"), event.getString("processingStatus"))
        "text" -> ChatEvent.Text(event.getString("content"))
        "done" -> ChatEvent.Done(event.getString("conversationId"), event.optionalBoolean("duplicate"), event.optionalString("processingStatus"), event.optionalBoolean("gated"), event.optionalString("reason"))
        "error" -> ChatEvent.Error(event.getString("error"), event.getBoolean("retryable"))
        else -> throw ai.onlo.sdk.protocol.ProtocolViolation("chat_event")
        } } catch (failure: ai.onlo.sdk.protocol.ProtocolViolation) { throw failure } catch (_: Exception) { throw ai.onlo.sdk.protocol.ProtocolViolation("chat_event") }
    }

    // Widget routes do not yet define a contract-safe HTTP error classification.
    // Treat a non-success status as transport unavailability so callers preserve
    // durable work and retry only from their existing recovery seams.
    private data object WidgetFailure : java.io.IOException("widget_failure")
}

/** Sends only rows from the current owner partition, retaining the pre-persisted UUID on retry. */
internal class DurableChatOutbox(
    private val store: OwnerScopedOutboxStore,
    private val api: WidgetChatApi,
    private val nowMs: () -> Long,
    private val onDuplicateAccepted: suspend (String) -> Unit = {},
    private val onEvent: suspend (ChatEvent) -> Unit = {},
) {
    suspend fun enqueue(owner: OwnerScope, conversationId: String, message: String, attachments: List<ChatAttachment> = emptyList()): OutboxEntry {
        val entry = OutboxEntryFactory.create(owner, conversationId, message, attachments, nowMs())
        store.enqueue(entry)
        return entry
    }

    suspend fun flush(owner: OwnerScope, sessionId: String, chatToken: String) {
        for (entry in store.eligible(owner, nowMs(), 20)) {
            if (entry.nextAttemptAtMs != null && entry.nextAttemptAtMs > nowMs()) break
            if (!store.markSending(owner, entry.clientMessageId)) continue
            var acceptedPersisted = false
            val outcome = try {
                api.send(
                    chatToken = chatToken,
                    request = ChatRequest(sessionId, entry.clientMessageId, entry.message, entry.attachments),
                    onAccepted = { accepted ->
                        if (accepted.clientMessageId != entry.clientMessageId) {
                            throw ai.onlo.sdk.protocol.ProtocolViolation("accepted_client_message_id")
                        }
                        store.markAccepted(owner, entry.clientMessageId, accepted.messageId)
                        acceptedPersisted = true
                        if (accepted.duplicate) onDuplicateAccepted(accepted.conversationId)
                    },
                    onEvent = onEvent,
                )
            } catch (failure: CancellationException) {
                throw failure
            } catch (_: ai.onlo.sdk.protocol.ProtocolViolation) {
                if (acceptedPersisted) continue
                store.markTerminalFailure(owner, entry.clientMessageId, "protocol_violation")
                break
            } catch (_: java.io.IOException) {
                if (acceptedPersisted) continue
                store.markRetryableFailure(owner, entry.clientMessageId, "transport_unavailable", retryAt(entry))
                break
            } catch (failure: Exception) {
                if (acceptedPersisted) continue
                throw failure
            }
            if (acceptedPersisted) continue
            val accepted = outcome.accepted
            when {
                accepted != null -> throw IllegalStateException("accepted_callback_missing")
                outcome.error?.retryable == true -> { store.markRetryableFailure(owner, entry.clientMessageId, "widget_retryable", retryAt(entry)); break }
                else -> { store.markTerminalFailure(owner, entry.clientMessageId, "widget_rejected"); break }
            }
        }
    }

    /** Persisted next-attempt time; the body/UUID are reused from the stored row on every flush. */
    private fun retryAt(entry: OutboxEntry): Long {
        val base = min(30_000L, 500L shl min(entry.attemptCount.coerceAtLeast(1) - 1, 5))
        val jittered = (base * (0.75 + Random.nextDouble() * 0.5)).toLong()
        return nowMs() + jittered
    }
}

/** A stale transcript cursor is discarded before one bounded dependent sync retry. */
internal class TranscriptConvergence(private val api: WidgetChatApi, private val store: OwnerScopedOutboxStore) {
    suspend fun cached(owner: OwnerScope, conversationId: String, expectedSessionId: String): ConversationDetail? =
        store.transcript(owner, conversationId)?.let(::decodeTranscript)?.also {
            if (it.sessionId != expectedSessionId) throw ai.onlo.sdk.protocol.ProtocolViolation("transcript_session")
        }

    suspend fun fetchAfterFullSync(owner: OwnerScope, chatToken: String, conversationId: String, staleCursor: String?, expectedSessionId: String): ConversationDetail {
        val persisted = cached(owner, conversationId, expectedSessionId)
        val baseline = if (staleCursor != null) api.transcript(chatToken, conversationId, ConversationPageQuery.Latest(limit = 100), expectedSessionId) else persisted
        val retried = api.transcript(chatToken, conversationId, ConversationPageQuery.Latest(limit = 100), expectedSessionId)
        val merged = retried.copy(messages = ((persisted?.messages.orEmpty() + baseline?.messages.orEmpty() + retried.messages).associateBy(TranscriptMessage::id).values.sortedBy(TranscriptMessage::timestamp)))
        store.replaceTranscript(owner, conversationId, encodeTranscript(merged))
        return merged
    }

    private fun encodeTranscript(value: ConversationDetail): String = org.json.JSONObject().apply {
        put("id", value.id); put("sessionId", value.sessionId); put("status", value.status); put("isHumanTakeover", value.isHumanTakeover); put("previousCursor", value.previousCursor); put("nextCursor", value.nextCursor); put("limit", value.limit)
        put("messages", org.json.JSONArray().apply { value.messages.forEach { message -> put(org.json.JSONObject().apply { put("id", message.id); put("externalId", message.externalId); put("role", message.role); put("senderType", message.senderType); put("senderName", message.senderName); put("senderTeam", message.senderTeam); put("text", message.text); put("attachments", org.json.JSONArray(message.attachments)); put("timestamp", message.timestamp) }) } })
    }.toString()

    private fun decodeTranscript(raw: String): ConversationDetail = try {
        val value = org.json.JSONObject(raw); val messages = value.getJSONArray("messages")
        ConversationDetail(value.getString("id"), value.getString("sessionId"), value.getString("status"), value.getBoolean("isHumanTakeover"), buildList { for (i in 0 until messages.length()) { val m = messages.getJSONObject(i); val attachments = m.getJSONArray("attachments"); add(TranscriptMessage(m.getString("id"), m.optionalString("externalId"), m.getString("role"), m.optionalString("senderType"), m.optionalString("senderName"), m.optionalString("senderTeam"), m.getString("text"), buildList { for (j in 0 until attachments.length()) add(attachments.getString(j)) }, m.getLong("timestamp"))) } }, value.optionalString("previousCursor"), value.optionalString("nextCursor"), value.getInt("limit"))
    } catch (_: Exception) { throw ai.onlo.sdk.protocol.ProtocolViolation("transcript_cache") }
}

private fun JSONObject.optionalBoolean(name: String): Boolean? = if (has(name) && !isNull(name)) getBoolean(name) else null
private fun JSONObject.optionalString(name: String): String? = if (has(name) && !isNull(name)) getString(name) else null
