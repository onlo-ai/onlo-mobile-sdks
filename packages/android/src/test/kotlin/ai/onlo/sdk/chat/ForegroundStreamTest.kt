package ai.onlo.sdk.chat

import ai.onlo.sdk.transport.OnloHttpRequest
import ai.onlo.sdk.transport.OnloSseTransport
import ai.onlo.sdk.transport.ProtocolRequestFactory
import ai.onlo.sdk.transport.SseStreamResult
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlinx.coroutines.runBlocking
import okhttp3.HttpUrl.Companion.toHttpUrl

class ForegroundStreamTest {
    @Test
    fun `only declared foreground hints are emitted and malformed data is ignored`() = runBlocking {
        val transport = FixtureSseTransport(
            listOf(
                "data: {\"type\":\"ready\"}", "",
                "data: {\"type\":\"config_changed\",\"revision\":\"r2\"}", "",
                "data: {\"type\":\"inbox.conversation\",\"conversationId\":\"c1\"}", "",
                "data: {\"type\":\"inbox.message\",\"conversationId\":\"c1\"}", "",
                "data: {\"type\":\"unknown\"}", "",
                "data: {\"type\":\"config_changed\"}", "",
                "data: {\"type\":\"config_changed\",\"revision\":\" \"}", "",
                "data: {\"type\":\"inbox.message\",\"conversationId\":\"\"}", "",
                "data: {bad}", "",
                "data: {\"type\":\"ready\",\"unexpected\":true}", "",
            ),
        )
        val hints = mutableListOf<ForegroundHint>()

        ForegroundStream(transport, ProtocolRequestFactory("https://onlo.ai/".toHttpUrl()))
            .collect("fixture-bearer") { hints += it }

        assertEquals(
            listOf(
                ForegroundHint.Ready,
                ForegroundHint.ConfigChanged("r2"),
                ForegroundHint.Conversation("c1"),
                ForegroundHint.Message("c1"),
            ),
            hints,
        )
    }

    private class FixtureSseTransport(private val lines: List<String>) : OnloSseTransport {
        override suspend fun stream(request: OnloHttpRequest, onLine: suspend (String) -> Unit): SseStreamResult {
            lines.forEach(onLine)
            return SseStreamResult.Success(200)
        }
    }
}
