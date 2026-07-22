package ai.onlo.sdk.protocol

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith

class ProtocolContractConformanceTest {
    @Test
    fun `client descriptor encodes only declared contract capabilities`() {
        val encoded = ProtocolJsonCodec.encodeSessionRequest(
            SessionRequest(
                sdkKey = "public-sdk-key",
                appIdentifier = "ai.onlo.fixture",
                client = SdkClientDescriptor(
                    installationId = "00000000-0000-0000-0000-000000000001",
                    sdkVersion = "0.1.0",
                    capabilities = listOf(Capability.SECURE_STORAGE, Capability.IDENTITY_JWT),
                ),
                operation = SessionOperation.Bootstrap("00000000-0000-0000-0000-000000000002", "synthetic-credential"),
            ),
        )

        assertEquals(true, encoded.contains("\"secure_storage\""))
        assertEquals(true, encoded.contains("\"identity_jwt\""))
    }

    @Test
    fun `undeclared retry directive is rejected as a protocol violation`() {
        val raw = """{"requestId":"fixture-request","serverTime":"2026-01-01T00:00:00Z","protocolVersion":1,"minimumProtocolVersion":1,"ok":false,"error":{"code":"dependency_unavailable","message":"fixture","retry":{"directive":"invented"}}}"""

        assertFailsWith<ProtocolViolation> { ProtocolJsonCodec.decodeSessionEnvelope(raw) }
    }

    @Test
    fun `negative retry delay is rejected as a protocol violation`() {
        val raw = """{"requestId":"fixture-request","serverTime":"2026-01-01T00:00:00Z","protocolVersion":1,"minimumProtocolVersion":1,"ok":false,"error":{"code":"dependency_unavailable","message":"fixture","retry":{"directive":"after_backoff","retryAfterMs":-1}}}"""

        assertFailsWith<ProtocolViolation> { ProtocolJsonCodec.decodeSessionEnvelope(raw) }
    }
}
