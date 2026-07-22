package ai.onlo.sdk.protocol

import ai.onlo.sdk.transport.ProtocolRequestFactory
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue
import okhttp3.HttpUrl.Companion.toHttpUrl
import okio.Buffer

class ProtocolRequestFactoryTest {
    private val requests = ProtocolRequestFactory("https://sdk.example.test/".toHttpUrl())

    @Test
    fun `session request uses the v1 endpoint and no bearer token`() {
        val request = requests.session(
            SessionRequest(
                sdkKey = "public-sdk-key",
                appIdentifier = "ai.onlo.example",
                client = SdkClientDescriptor(
                    installationId = "installation-1",
                    sdkVersion = "0.1.0",
                    capabilities = listOf(Capability.SECURE_STORAGE),
                ),
                operation = SessionOperation.Bootstrap(
                    transitionId = "00000000-0000-0000-0000-000000000001",
                    proposedCredential = "opaque-credential",
                ),
            ),
        )

        assertEquals("POST", request.method)
        assertEquals("/api/sdk/v1/session", request.url.encodedPath)
        assertFalse(request.headers.containsKey("Authorization"))
        assertTrue(request.bodyText().contains("\"type\":\"bootstrap\""))
    }

    @Test
    fun `adapter sdk family changes without changing Android runtime platform`() {
        val request = requests.session(
            SessionRequest(
                sdkKey = "public-sdk-key",
                appIdentifier = "ai.onlo.example",
                client = SdkClientDescriptor(
                    installationId = "installation-1",
                    sdkFamily = SdkFamily.REACT_NATIVE,
                    sdkVersion = "0.1.0",
                    capabilities = listOf(Capability.SECURE_STORAGE),
                ),
                operation = SessionOperation.Bootstrap("transition-1", "opaque-credential"),
            ),
        )

        assertTrue(request.bodyText().contains("\"runtimePlatform\":\"android\""))
        assertTrue(request.bodyText().contains("\"sdkFamily\":\"react-native\""))
    }

    @Test
    fun `foreground stream capability uses its exact manifest descriptor value`() {
        val request = requests.session(
            SessionRequest("public-sdk-key", "ai.onlo.example", SdkClientDescriptor(
                installationId = "installation-1", sdkVersion = "0.1.0",
                capabilities = listOf(Capability.FOREGROUND_STREAM),
            ), SessionOperation.Bootstrap("transition-1", "opaque-credential")),
        )
        assertTrue(request.bodyText().contains("\"capabilities\":[\"foreground_stream\"]"))
    }

    @Test
    fun `transcript uses only one supported cursor direction`() {
        val request = requests.transcript(
            chatToken = "memory-token",
            conversationId = "conversation-1",
            page = ConversationPageQuery.After(after = "opaque-cursor", limit = 25),
        )

        assertEquals("/api/widget/conversations/conversation-1", request.url.encodedPath)
        assertEquals("opaque-cursor", request.url.queryParameter("after"))
        assertEquals("25", request.url.queryParameter("limit"))
        assertEquals(null, request.url.queryParameter("before"))
    }

    @Test
    fun `chat request retains caller supplied stable id`() {
        val request = requests.chat(
            chatToken = "memory-token",
            value = ChatRequest(
                sessionId = "session-1",
                clientMessageId = "00000000-0000-0000-0000-000000000010",
                message = "test message",
            ),
        )

        assertTrue(request.bodyText().contains("\"clientMessageId\":\"00000000-0000-0000-0000-000000000010\""))
        assertEquals("text/event-stream", request.headers["Accept"])
    }

    private fun ai.onlo.sdk.transport.OnloHttpRequest.bodyText(): String = Buffer().use { buffer ->
        checkNotNull(body).writeTo(buffer)
        buffer.readUtf8()
    }
}
