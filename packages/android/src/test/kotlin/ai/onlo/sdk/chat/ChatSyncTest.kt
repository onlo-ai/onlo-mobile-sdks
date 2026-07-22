package ai.onlo.sdk.chat

import ai.onlo.sdk.protocol.ConversationPageQuery
import ai.onlo.sdk.protocol.ChatAttachment
import ai.onlo.sdk.storage.OutboxEntry
import ai.onlo.sdk.storage.OutboxState
import ai.onlo.sdk.storage.OwnerScope
import ai.onlo.sdk.storage.OwnerScopedOutboxStore
import ai.onlo.sdk.transport.OnloHttpRequest
import ai.onlo.sdk.transport.OnloHttpResponse
import ai.onlo.sdk.transport.OnloTransport
import ai.onlo.sdk.transport.OnloSseTransport
import ai.onlo.sdk.transport.SseStreamResult
import ai.onlo.sdk.transport.ProtocolRequestFactory
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertTrue
import kotlinx.coroutines.runBlocking
import okhttp3.HttpUrl.Companion.toHttpUrl

class ChatSyncTest {
    @Test
    fun `accepted SSE acknowledges the durable row with its original client id`() = runBlocking {
        val transport = FixtureTransport(listOf(accepted()))
        val store = MemoryOutbox()
        val outbox = DurableChatOutbox(store, WidgetChatApi(transport, requests()), nowMs = { 10 })
        val owner = OwnerScope.Anonymous("owner")
        val entry = outbox.enqueue(owner, "conversation", "fixture message")

        outbox.flush(owner, "fixture-session", "fixture-bearer")

        assertEquals(entry.clientMessageId, store.acceptedId)
        assertEquals(OutboxState.ACCEPTED, store.rows.single().state)
    }

    @Test
    fun `enqueue preserves contract attachment data for durable send`() = runBlocking {
        val store = MemoryOutbox()
        val outbox = DurableChatOutbox(store, WidgetChatApi(FixtureTransport(emptyList()), requests()), nowMs = { 10 })
        val attachment = ChatAttachment(id = "fixture-id", url = "https://fixture.invalid/download", type = "image/png", name = "image.png", size = 1, receipt = "fixture-receipt")
        val entry = outbox.enqueue(OwnerScope.Anonymous("owner"), "conversation", "", listOf(attachment))
        assertEquals(listOf(attachment), entry.attachments)
        assertEquals(listOf(attachment), store.rows.single().attachments)
    }

    @Test
    fun `malformed SSE is terminal for the durable row`() = runBlocking {
        val store = MemoryOutbox(); val owner = OwnerScope.Anonymous("owner")
        val outbox = DurableChatOutbox(store, WidgetChatApi(FixtureTransport(listOf(OnloHttpResponse(200, emptyMap(), "data: {bad}\n"))), requests()), { 10 })
        outbox.enqueue(owner, "conversation", "fixture")
        outbox.flush(owner, "fixture-session", "fixture-bearer")
        assertEquals(OutboxState.FAILED_TERMINAL, store.rows.single().state)
    }

    @Test
    fun `non success widget body returns only declared error field`() = runBlocking {
        val api = WidgetChatApi(FixtureTransport(listOf(OnloHttpResponse(403, emptyMap(), "{\"error\":\"forbidden\"}"))), requests())
        val outcome = api.send("fixture-bearer", ai.onlo.sdk.protocol.ChatRequest("session", "00000000-0000-0000-0000-000000000001", "fixture"))
        assertEquals(ChatEvent.Error("forbidden", false), outcome.error)
    }

    @Test
    fun `duplicate acceptance reconciles without changing the durable id`() = runBlocking {
        var reconciled: String? = null; val store = MemoryOutbox(); val owner = OwnerScope.Anonymous("owner")
        val outbox = DurableChatOutbox(store, WidgetChatApi(FixtureTransport(listOf(accepted(duplicate = true))), requests()), { 10 }, { reconciled = it })
        val row = outbox.enqueue(owner, "conversation", "fixture"); outbox.flush(owner, "session", "bearer")
        assertEquals(row.clientMessageId, store.acceptedId); assertEquals("conversation", reconciled)
    }

    @Test
    fun `wrong accepted id is terminal`() = runBlocking {
        val store = MemoryOutbox(); val owner = OwnerScope.Anonymous("owner")
        val outbox = DurableChatOutbox(store, WidgetChatApi(FixtureTransport(listOf(sse("accepted", "00000000-0000-0000-0000-000000000099"))), requests()), { 10 })
        outbox.enqueue(owner, "conversation", "fixture"); outbox.flush(owner, "session", "bearer")
        assertEquals(OutboxState.FAILED_TERMINAL, store.rows.single().state)
    }

    @Test
    fun `accepted before transport disconnect remains durable and is not sent again`() = runBlocking {
        val transport = ThrowingAfterResponseTransport(accepted(), java.io.IOException("synthetic_disconnect"))
        val store = MemoryOutbox(); val owner = OwnerScope.Anonymous("owner")
        val outbox = DurableChatOutbox(store, WidgetChatApi(transport, requests()), { 10 })
        val entry = outbox.enqueue(owner, "conversation", "fixture")

        outbox.flush(owner, "session", "bearer")
        outbox.flush(owner, "session", "bearer")

        assertEquals(OutboxState.ACCEPTED, store.rows.single().state)
        assertEquals(entry.clientMessageId, store.acceptedId)
        assertEquals(1, transport.requests.size)
    }

    @Test
    fun `accepted before malformed event stays accepted and FIFO advances`() = runBlocking {
        val firstResponse = accepted().let { it.copy(body = it.body + "data: {bad}\n\n") }
        val transport = FixtureTransport(listOf(firstResponse, accepted()))
        val store = MemoryOutbox(); val owner = OwnerScope.Anonymous("owner")
        val outbox = DurableChatOutbox(store, WidgetChatApi(transport, requests()), { 10 })
        val first = outbox.enqueue(owner, "conversation", "first")
        val second = outbox.enqueue(owner, "conversation", "second")

        outbox.flush(owner, "session", "bearer")
        outbox.flush(owner, "session", "bearer")

        assertEquals(listOf(first.clientMessageId, second.clientMessageId), store.sentIds)
        assertTrue(store.rows.all { it.state == OutboxState.ACCEPTED })
        assertEquals(2, transport.requests.size)
    }

    @Test
    fun `duplicate transcript failure cannot revert or resend accepted row`() = runBlocking {
        val transport = FixtureTransport(listOf(accepted(duplicate = true)))
        val store = MemoryOutbox(); val owner = OwnerScope.Anonymous("owner")
        val outbox = DurableChatOutbox(
            store,
            WidgetChatApi(transport, requests()),
            nowMs = { 10 },
            onDuplicateAccepted = { throw java.io.IOException("synthetic_transcript_failure") },
        )
        val entry = outbox.enqueue(owner, "conversation", "fixture")

        outbox.flush(owner, "session", "bearer")
        outbox.flush(owner, "session", "bearer")

        assertEquals(OutboxState.ACCEPTED, store.rows.single().state)
        assertEquals(entry.clientMessageId, store.acceptedId)
        assertEquals(1, transport.requests.size)
    }

    @Test
    fun `equal timestamp enqueues retain transactional per owner FIFO order`() = runBlocking {
        val store = MemoryOutbox(); val owner = OwnerScope.Anonymous("owner")
        val outbox = DurableChatOutbox(store, WidgetChatApi(FixtureTransport(listOf(
            accepted(),
            accepted(),
        )), requests()), nowMs = { 10 })

        val first = outbox.enqueue(owner, "conversation", "first")
        val second = outbox.enqueue(owner, "conversation", "second")
        outbox.flush(owner, "fixture-session", "fixture-bearer")

        assertEquals(listOf(first.clientMessageId, second.clientMessageId), store.sentIds)
        assertEquals(listOf(1L, 2L), store.rows.map(OutboxEntry::orderingKey))
    }

    @Test
    fun `not yet due retryable head blocks later queued rows`() = runBlocking {
        var clock = 10L
        val store = MemoryOutbox(); val owner = OwnerScope.Anonymous("owner")
        val outbox = DurableChatOutbox(store, WidgetChatApi(FixtureTransport(listOf(
            retryableError(), accepted(),
        )), requests()), nowMs = { clock })
        val first = outbox.enqueue(owner, "conversation", "first")
        val second = outbox.enqueue(owner, "conversation", "second")

        outbox.flush(owner, "session", "bearer")
        val persistedRetry = checkNotNull(store.rows.first { it.clientMessageId == first.clientMessageId }.nextAttemptAtMs)
        assertEquals(OutboxState.FAILED_RETRYABLE, store.rows.first { it.clientMessageId == first.clientMessageId }.state)
        assertEquals(OutboxState.QUEUED, store.rows.first { it.clientMessageId == second.clientMessageId }.state)

        clock = persistedRetry - 1
        outbox.flush(owner, "session", "bearer")
        assertEquals(listOf(first.clientMessageId), store.sentIds)
        assertEquals(OutboxState.QUEUED, store.rows.first { it.clientMessageId == second.clientMessageId }.state)
    }

    @Test
    fun `retry reuses persisted client id and body and persists backoff`() = runBlocking {
        var clock = 10L
        val store = MemoryOutbox(); val owner = OwnerScope.Anonymous("owner")
        val transport = FixtureTransport(listOf(retryableError(), accepted()))
        val outbox = DurableChatOutbox(store, WidgetChatApi(transport, requests()), nowMs = { clock })
        val entry = outbox.enqueue(owner, "conversation", "synthetic body")

        outbox.flush(owner, "session", "bearer")
        val retryAt = checkNotNull(store.rows.single().nextAttemptAtMs)
        assertTrue(retryAt > clock)
        assertEquals(OutboxState.FAILED_RETRYABLE, store.rows.single().state)
        clock = retryAt
        outbox.flush(owner, "session", "bearer")

        assertEquals(listOf(entry.clientMessageId, entry.clientMessageId), store.sentIds)
        assertEquals(listOf("synthetic body", "synthetic body"), transport.requests.map { requestBody(it).getString("message") })
        assertEquals(OutboxState.ACCEPTED, store.rows.single().state)
    }

    @Test
    fun `every unaccepted outcome stops FIFO before later rows`() = runBlocking {
        val cases = listOf(
            retryableError(),
            nonRetryableError(),
            OnloHttpResponse(200, emptyMap(), "data: {\"type\":\"done\",\"conversationId\":\"conversation\"}\n\n"),
            OnloHttpResponse(200, emptyMap(), "data: {bad}\n\n"),
        )
        cases.forEach { response ->
            val store = MemoryOutbox(); val owner = OwnerScope.Anonymous("owner")
            val outbox = DurableChatOutbox(store, WidgetChatApi(FixtureTransport(listOf(response)), requests()), { 10 })
            val first = outbox.enqueue(owner, "conversation", "first")
            val second = outbox.enqueue(owner, "conversation", "second")
            outbox.flush(owner, "session", "bearer")
            assertEquals(listOf(first.clientMessageId), store.sentIds)
            assertTrue(store.rows.first { it.clientMessageId == first.clientMessageId }.state in setOf(OutboxState.FAILED_RETRYABLE, OutboxState.FAILED_TERMINAL))
            assertEquals(OutboxState.QUEUED, store.rows.first { it.clientMessageId == second.clientMessageId }.state)
        }
    }

    @Test
    fun `transcript payloads remain partitioned and purge removes only retired owner`() = runBlocking {
        val store = MemoryOutbox(); val a = OwnerScope.Anonymous("a"); val b = OwnerScope.Identified("b")
        store.replaceTranscript(a, "conversation", "a-payload"); store.replaceTranscript(b, "conversation", "b-payload")
        assertEquals("a-payload", store.transcript(a, "conversation")); assertEquals("b-payload", store.transcript(b, "conversation"))
        store.purgeOwner(a)
        assertEquals(null, store.transcript(a, "conversation")); assertEquals("b-payload", store.transcript(b, "conversation"))
    }

    @Test
    fun `full sync discards stale cursor before the dependent transcript retry`() = runBlocking {
        val transport = FixtureTransport(listOf(transcript(), transcript()))
        val convergence = TranscriptConvergence(WidgetChatApi(transport, requests()), MemoryOutbox())

        convergence.fetchAfterFullSync(OwnerScope.Anonymous("owner"), "fixture-bearer", "conversation", staleCursor = "stale", expectedSessionId = "fixture-session")

        assertEquals(2, transport.requests.size)
        assertEquals(null, transport.requests[0].url.queryParameter("after"))
        assertEquals(null, transport.requests[1].url.queryParameter("after"))
    }

    @Test
    fun `transcript convergence deduplicates ids and preserves raw attachments`() = runBlocking {
        val transport = FixtureTransport(listOf(transcriptWithMessage(), transcriptWithMessage()))
        val result = TranscriptConvergence(WidgetChatApi(transport, requests()), MemoryOutbox()).fetchAfterFullSync(OwnerScope.Anonymous("owner"), "fixture-bearer", "conversation", "stale", "fixture-session")
        assertEquals(1, result.messages.size)
        assertEquals("{\"id\":\"attachment\"}", result.messages.single().attachments.single())
    }

    @Test
    fun `malformed persisted transcript is rejected before sync`() = runBlocking {
        val store = MemoryOutbox(); val owner = OwnerScope.Anonymous("owner")
        store.replaceTranscript(owner, "conversation", "not-json")
        try { TranscriptConvergence(WidgetChatApi(FixtureTransport(listOf(transcript())), requests()), store).fetchAfterFullSync(owner, "fixture-bearer", "conversation", null, "fixture-session"); error("expected protocol violation") } catch (_: ai.onlo.sdk.protocol.ProtocolViolation) { }
    }

    @Test
    fun `persisted transcript merges full fields and fetched metadata wins`() = runBlocking {
        val store = MemoryOutbox(); val owner = OwnerScope.Anonymous("owner")
        store.replaceTranscript(owner, "conversation", "{\"id\":\"conversation\",\"sessionId\":\"old-session\",\"status\":\"old\",\"isHumanTakeover\":false,\"previousCursor\":\"old-prev\",\"nextCursor\":\"old-next\",\"limit\":10,\"messages\":[{\"id\":\"old\",\"externalId\":\"external\",\"role\":\"user\",\"senderType\":\"contact\",\"senderName\":\"name\",\"senderTeam\":null,\"text\":\"old text\",\"attachments\":[\"{\\\"id\\\":\\\"a\\\"}\"],\"timestamp\":1},{\"id\":\"overlap\",\"externalId\":null,\"role\":\"assistant\",\"senderType\":null,\"senderName\":null,\"senderTeam\":null,\"text\":\"old overlap\",\"attachments\":[],\"timestamp\":2}]}")
        val result = TranscriptConvergence(WidgetChatApi(FixtureTransport(listOf(transcriptChanged(), transcriptChanged())), requests()), store).fetchAfterFullSync(owner, "fixture", "conversation", null, "new-session")
        assertEquals("new", result.status); assertEquals(true, result.isHumanTakeover); assertEquals("new-next", result.nextCursor); assertEquals(50, result.limit)
        assertEquals(listOf("old", "overlap", "new"), result.messages.map { it.id }); assertEquals("new overlap", result.messages.first { it.id == "overlap" }.text); assertEquals("external", result.messages.first { it.id == "old" }.externalId)
        val stored = checkNotNull(store.transcript(owner, "conversation")); assertEquals(true, stored.contains("new overlap")); assertEquals(true, stored.contains("old text")); assertEquals(true, stored.contains("new-next"))
    }

    @Test
    fun `cross session transcript is rejected before it can be persisted`() = runBlocking {
        val store = MemoryOutbox(); val owner = OwnerScope.Anonymous("owner")
        val convergence = TranscriptConvergence(WidgetChatApi(FixtureTransport(listOf(transcript())), requests()), store)

        try {
            convergence.fetchAfterFullSync(owner, "fixture-bearer", "conversation", null, "different-session")
            error("expected protocol violation")
        } catch (_: ai.onlo.sdk.protocol.ProtocolViolation) {
        }
        assertEquals(null, store.transcript(owner, "conversation"))
    }

    @Test
    fun `conversation inbox uses the exact contract list route and fields`() = runBlocking {
        val response = OnloHttpResponse(200, emptyMap(), "{\"conversations\":[{\"id\":\"conversation\",\"sessionId\":\"fixture-session\",\"title\":\"[redacted]\",\"unread\":true,\"unreadCount\":2,\"status\":\"open\",\"updatedAt\":\"2026-01-01T00:00:00Z\",\"messageCount\":3,\"lastMessageRole\":null}]}")
        val transport = FixtureTransport(listOf(response))

        val result = WidgetChatApi(transport, requests()).conversations("fixture-bearer", "fixture-session")

        assertEquals("conversation", result.single().id)
        assertEquals(2, result.single().unreadCount)
        assertEquals("/api/widget/conversations", transport.requests.single().url.encodedPath)
        assertEquals("50", transport.requests.single().url.queryParameter("limit"))
    }

    @Test
    fun `malformed conversation list is never rendered as authorised inbox data`() = runBlocking {
        val api = WidgetChatApi(FixtureTransport(listOf(OnloHttpResponse(200, emptyMap(), "{\"conversations\":[{\"id\":\"conversation\"}]}"))), requests())
        try {
            api.conversations("fixture-bearer", "fixture-session")
            error("expected protocol violation")
        } catch (_: ai.onlo.sdk.protocol.ProtocolViolation) {
        }
    }

    @Test
    fun `cross session inbox entry is rejected as unauthorised`() = runBlocking {
        val response = OnloHttpResponse(200, emptyMap(), "{\"conversations\":[{\"id\":\"conversation\",\"sessionId\":\"different-session\",\"title\":\"[redacted]\",\"unread\":false,\"unreadCount\":0,\"status\":\"open\",\"updatedAt\":\"2026-01-01T00:00:00Z\",\"messageCount\":0,\"lastMessageRole\":null}]}")
        val api = WidgetChatApi(FixtureTransport(listOf(response)), requests())
        try {
            api.conversations("fixture-bearer", "fixture-session")
            error("expected protocol violation")
        } catch (_: ai.onlo.sdk.protocol.ProtocolViolation) {
        }
    }

    @Test
    fun `widget inbox HTTP failure follows the unavailable transport path`() = runBlocking {
        val api = WidgetChatApi(
            FixtureTransport(listOf(OnloHttpResponse(503, emptyMap(), "{\"error\":\"synthetic\"}"))),
            requests(),
        )

        assertFailsWith<java.io.IOException> {
            api.conversations("fixture-bearer", "fixture-session")
        }
    }

    // SQLite ciphertext-corruption purge is Android/Keystore-dependent and must be covered by
    // Robolectric or instrumentation once the licensed Android platform is available.

    private fun requests() = ProtocolRequestFactory("https://onlo.ai/".toHttpUrl())

    private fun sse(type: String, clientId: String, duplicate: Boolean = false) = OnloHttpResponse(
        200, emptyMap(), "data: {\"type\":\"$type\",\"clientMessageId\":\"$clientId\",\"messageId\":\"server-message\",\"conversationId\":\"conversation\",\"acceptedAt\":\"2026-01-01T00:00:00Z\",\"duplicate\":$duplicate,\"processingStatus\":\"accepted\"}\n\n",
    )
    private fun accepted(duplicate: Boolean = false) = sse("accepted", "__request_client_message_id__", duplicate)
    private fun retryableError() = OnloHttpResponse(200, emptyMap(), "data: {\"type\":\"error\",\"error\":\"synthetic\",\"retryable\":true}\n\n")
    private fun nonRetryableError() = OnloHttpResponse(200, emptyMap(), "data: {\"type\":\"error\",\"error\":\"synthetic\",\"retryable\":false}\n\n")
    private fun requestBody(request: OnloHttpRequest): org.json.JSONObject = org.json.JSONObject(
        checkNotNull(request.body).let { body -> okio.Buffer().also(body::writeTo).readUtf8() },
    )

    private fun transcript() = OnloHttpResponse(200, emptyMap(), "{\"conversation\":{\"id\":\"conversation\",\"sessionId\":\"fixture-session\",\"status\":\"open\",\"isHumanTakeover\":false},\"messages\":[],\"sync\":{\"previousCursor\":null,\"nextCursor\":null,\"limit\":100}}")
    private fun transcriptWithMessage() = OnloHttpResponse(200, emptyMap(), "{\"conversation\":{\"id\":\"conversation\",\"sessionId\":\"fixture-session\",\"status\":\"open\",\"isHumanTakeover\":false},\"messages\":[{\"id\":\"message\",\"externalId\":null,\"role\":\"assistant\",\"senderType\":null,\"senderName\":null,\"senderTeam\":null,\"text\":\"fixture\",\"attachments\":[{\"id\":\"attachment\"}],\"timestamp\":1}],\"sync\":{\"previousCursor\":null,\"nextCursor\":null,\"limit\":100}}")
    private fun transcriptChanged() = OnloHttpResponse(200, emptyMap(), "{\"conversation\":{\"id\":\"conversation\",\"sessionId\":\"new-session\",\"status\":\"new\",\"isHumanTakeover\":true},\"messages\":[{\"id\":\"overlap\",\"externalId\":null,\"role\":\"assistant\",\"senderType\":null,\"senderName\":null,\"senderTeam\":null,\"text\":\"new overlap\",\"attachments\":[],\"timestamp\":3},{\"id\":\"new\",\"externalId\":null,\"role\":\"assistant\",\"senderType\":null,\"senderName\":null,\"senderTeam\":null,\"text\":\"new text\",\"attachments\":[],\"timestamp\":4}],\"sync\":{\"previousCursor\":\"new-prev\",\"nextCursor\":\"new-next\",\"limit\":50}}")

    private class FixtureTransport(private val responses: List<OnloHttpResponse>) : OnloTransport, OnloSseTransport {
        private var index = 0
        val requests = mutableListOf<OnloHttpRequest>()
        override suspend fun execute(request: OnloHttpRequest): OnloHttpResponse {
            requests += request
            return responses[index++]
        }
        override suspend fun stream(request: OnloHttpRequest, onLine: suspend (String) -> Unit): SseStreamResult {
            requests += request
            val response = responses[index++]
            val requestClientId = org.json.JSONObject(
                checkNotNull(request.body).let { body -> okio.Buffer().also(body::writeTo).readUtf8() },
            ).getString("clientMessageId")
            for (line in response.body.replace("__request_client_message_id__", requestClientId).lineSequence()) onLine(line)
            return if (response.status in 200..299) SseStreamResult.Success(response.status) else SseStreamResult.Failure(response.status, response.body)
        }
    }

    private class ThrowingAfterResponseTransport(
        private val response: OnloHttpResponse,
        private val failure: java.io.IOException,
    ) : OnloTransport, OnloSseTransport {
        val requests = mutableListOf<OnloHttpRequest>()
        override suspend fun execute(request: OnloHttpRequest): OnloHttpResponse = error("unexpected_execute")
        override suspend fun stream(request: OnloHttpRequest, onLine: suspend (String) -> Unit): SseStreamResult {
            requests += request
            val requestClientId = org.json.JSONObject(
                checkNotNull(request.body).let { body -> okio.Buffer().also(body::writeTo).readUtf8() },
            ).getString("clientMessageId")
            for (line in response.body.replace("__request_client_message_id__", requestClientId).lineSequence()) onLine(line)
            throw failure
        }
    }

    private class MemoryOutbox : OwnerScopedOutboxStore {
        val rows = mutableListOf<OutboxEntry>()
        var acceptedId: String? = null
        val sentIds = mutableListOf<String>()
        private val transcripts = mutableMapOf<String, MutableMap<String, String>>()
        override suspend fun enqueue(entry: OutboxEntry) {
            val nextOrderingKey = (rows.filter { it.ownerScope == entry.ownerScope }.maxOfOrNull(OutboxEntry::orderingKey) ?: 0L) + 1L
            rows += entry.copy(orderingKey = nextOrderingKey)
        }
        override suspend fun eligible(ownerScope: OwnerScope, nowMs: Long, limit: Int) = rows.filter { it.ownerScope == ownerScope && it.state in setOf(OutboxState.QUEUED, OutboxState.FAILED_RETRYABLE) }.sortedBy(OutboxEntry::orderingKey).take(limit)
        override suspend fun markSending(ownerScope: OwnerScope, clientMessageId: String): Boolean {
            val existing = rows.singleOrNull { it.ownerScope == ownerScope && it.clientMessageId == clientMessageId && it.state in setOf(OutboxState.QUEUED, OutboxState.FAILED_RETRYABLE) } ?: return false
            sentIds += clientMessageId
            rows.replaceAll { if (it === existing) it.copy(state = OutboxState.SENDING, attemptCount = it.attemptCount + 1, nextAttemptAtMs = null) else it }
            return true
        }
        override suspend fun markAccepted(ownerScope: OwnerScope, clientMessageId: String, serverMessageId: String) { acceptedId = clientMessageId; rows.replaceAll { if (it.clientMessageId == clientMessageId) it.copy(state = OutboxState.ACCEPTED) else it } }
        override suspend fun markRetryableFailure(ownerScope: OwnerScope, clientMessageId: String, errorCode: String, nextAttemptAtMs: Long) { rows.replaceAll { if (it.ownerScope == ownerScope && it.clientMessageId == clientMessageId) it.copy(state = OutboxState.FAILED_RETRYABLE, lastErrorCode = errorCode, nextAttemptAtMs = nextAttemptAtMs) else it } }
        override suspend fun markTerminalFailure(ownerScope: OwnerScope, clientMessageId: String, errorCode: String) { rows.replaceAll { if (it.clientMessageId == clientMessageId) it.copy(state = OutboxState.FAILED_TERMINAL) else it } }
        override suspend fun recoverInterruptedSends(ownerScope: OwnerScope, nowMs: Long) = Unit
        override suspend fun blockOwner(ownerScope: OwnerScope) = Unit
        override suspend fun blockAndPurgeOwner(ownerScope: OwnerScope) { transcripts.remove(ownerScope.storageKey()) }
        override suspend fun purgeOwner(ownerScope: OwnerScope) { transcripts.remove(ownerScope.storageKey()) }
        override suspend fun clearAll() { transcripts.clear() }
        override suspend fun replaceTranscript(ownerScope: OwnerScope, conversationId: String, payload: String) { transcripts.getOrPut(ownerScope.storageKey()) { mutableMapOf() }[conversationId] = payload }
        override suspend fun transcript(ownerScope: OwnerScope, conversationId: String): String? = transcripts[ownerScope.storageKey()]?.get(conversationId)
    }
}
