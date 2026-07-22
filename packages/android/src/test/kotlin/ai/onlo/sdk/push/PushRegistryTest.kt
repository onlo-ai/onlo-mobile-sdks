package ai.onlo.sdk.push

import ai.onlo.sdk.protocol.PushProvider
import ai.onlo.sdk.protocol.NotificationPreference
import ai.onlo.sdk.transport.OnloHttpRequest
import ai.onlo.sdk.transport.OnloHttpResponse
import ai.onlo.sdk.transport.OnloPushApi
import ai.onlo.sdk.transport.OnloTransport
import ai.onlo.sdk.transport.ProtocolRequestFactory
import ai.onlo.sdk.storage.OwnerScope
import java.io.IOException
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue
import kotlinx.coroutines.runBlocking
import okhttp3.HttpUrl.Companion.toHttpUrl
import okio.Buffer

class PushRegistryTest {
    @Test fun `FCM registration has the exact contract body and is idempotent`() = runBlocking {
        val transport = FixtureTransport(listOf(registerResponse()))
        val registry = registry(transport)
        val authority = PushAuthority(OwnerScope.Identified("a"), "bearer-a")

        assertEquals(PushRegistrationOutcome.Registered, registry.register(authority, PushProvider.FCM, "fcm-token"))
        assertEquals(PushRegistrationOutcome.Registered, registry.register(authority, PushProvider.FCM, "fcm-token"))
        assertEquals(1, transport.requests.size)
        assertEquals("/api/sdk/v1/push-token", transport.requests.single().url.encodedPath)
        assertEquals("{\"action\":\"register\",\"provider\":\"fcm\",\"token\":\"fcm-token\"}", transport.requests.single().bodyText())
        assertEquals("Bearer bearer-a", transport.requests.single().headers["Authorization"])
    }

    @Test fun `Android rejects APNs without persistence or transport`() = runBlocking {
        val transport = FixtureTransport(emptyList()); val store = MemoryStore(); val registry = registry(transport, store)
        assertEquals(PushRegistrationOutcome.UnsupportedProvider, registry.register(PushAuthority(OwnerScope.Anonymous("a"), "bearer"), PushProvider.APNS, "apns-token"))
        assertEquals(null, store.value); assertTrue(transport.requests.isEmpty())
    }

    @Test fun `rotation and logout never reassociate a token to a different owner`() = runBlocking {
        val transport = FixtureTransport(listOf(registerResponse(), unregisterResponse()))
        val store = MemoryStore(); val registry = registry(transport, store)
        val userA = PushAuthority(OwnerScope.Identified("a"), "bearer-a")
        val userB = PushAuthority(OwnerScope.Identified("b"), "bearer-b")
        registry.register(userA, PushProvider.FCM, "rotated-token")
        assertEquals(PushRegistrationOutcome.BlockedByRetiringOwner, registry.register(userB, PushProvider.FCM, "user-b-token"))
        assertEquals("identified:a", store.value?.ownerScopeId)
        assertEquals(PushRegistrationOutcome.Unregistered, registry.retireOwner(userA))
        assertEquals(null, store.value)
        assertEquals("{\"action\":\"unregister\"}", transport.requests.last().bodyText())
    }

    @Test fun `payload is shape checked then refetched before navigation`() = runBlocking {
        val registry = registry(FixtureTransport(emptyList()))
        val authority = PushAuthority(OwnerScope.Anonymous("a"), "bearer")
        assertEquals(PushPayloadOutcome.NotOnlo, registry.handlePayload(mapOf("provider" to "other"), authority) { _, _, _ -> true })
        assertEquals(PushPayloadOutcome.Malformed, registry.handlePayload(mapOf("conversationId" to "c", "messageId" to "m", "notificationType" to "message_available", "extra" to "x"), authority) { _, _, _ -> true })
        assertEquals(PushPayloadOutcome.NotAuthorised, registry.handlePayload(payload(), authority) { _, _, _ -> false })
        assertEquals(PushPayloadOutcome.NavigationIntent("c", "m"), registry.handlePayload(payload(), authority) { _, conversation, message -> conversation == "c" && message == "m" })
    }

    @Test fun `payload rechecks authority after delayed refetch`() = runBlocking {
        val registry = registry(FixtureTransport(emptyList()))
        val authority = PushAuthority(OwnerScope.Anonymous("a"), "bearer")
        assertEquals(PushPayloadOutcome.NoActiveSession, registry.handlePayload(payload(), authority, { _, _, _ -> true }) { false })
    }

    @Test fun `server failure preserves pending state without automatic retry`() = runBlocking {
        val transport = FixtureTransport(listOf(failureEnvelope("after_token_refresh")))
        val store = MemoryStore(); val registry = registry(transport, store)
        val authority = PushAuthority(OwnerScope.Anonymous("a"), "bearer")
        assertEquals(PushRegistrationOutcome.PendingServer(ai.onlo.sdk.protocol.RetryDirective.AFTER_TOKEN_REFRESH), registry.register(authority, PushProvider.FCM, "fcm-token"))
        assertEquals(1, transport.requests.size)
        assertEquals(ai.onlo.sdk.protocol.RetryDirective.AFTER_TOKEN_REFRESH, store.value?.retryDirective)
        // Session restoration owns no push retry path; merely retaining this registry adds no request.
        assertEquals(1, transport.requests.size)
    }

    @Test fun `only eligible after backoff registration retries during lifecycle reconciliation`() = runBlocking {
        var now = 100L
        val transport = FixtureTransport(listOf(failureEnvelope("after_backoff", 50), registerResponse()))
        val registry = registry(transport, nowMs = { now })
        val authority = PushAuthority(OwnerScope.Anonymous("a"), "bearer")
        assertEquals(PushRegistrationOutcome.PendingServer(ai.onlo.sdk.protocol.RetryDirective.AFTER_BACKOFF), registry.register(authority, PushProvider.FCM, "fcm-token", NotificationPreference.MUTED, "en-IN"))
        assertEquals(PushRegistrationOutcome.PendingServer(ai.onlo.sdk.protocol.RetryDirective.AFTER_BACKOFF), registry.reconcileEligible(authority))
        assertEquals(1, transport.requests.size)
        now = 150L
        assertEquals(PushRegistrationOutcome.Registered, registry.reconcileEligible(authority))
        assertEquals(2, transport.requests.size)
        assertEquals(transport.requests.first().bodyText(), transport.requests.last().bodyText())
    }

    @Test fun `transport ambiguity survives reconstruction and retries the same registration intent`() = runBlocking {
        var now = 0L; val store = MemoryStore()
        val first = FixtureTransport(emptyList())
        val authority = PushAuthority(OwnerScope.Anonymous("a"), "bearer")
        assertEquals(PushRegistrationOutcome.QueuedForReconciliation, registry(first, store, { now }).register(authority, PushProvider.FCM, "fcm-token", NotificationPreference.ENABLED, "en-US"))
        now = 1_000L
        val replay = FixtureTransport(listOf(registerResponse()))
        assertEquals(PushRegistrationOutcome.Registered, registry(replay, store, { now }).reconcileEligible(authority))
        assertTrue(replay.requests.single().bodyText().contains("\"notificationPreference\":\"enabled\""))
        assertTrue(replay.requests.single().bodyText().contains("\"locale\":\"en-US\""))
    }

    @Test fun `never and gated directives never create lifecycle push traffic`() = runBlocking {
        val authority = PushAuthority(OwnerScope.Anonymous("a"), "bearer")
        listOf("never", "after_token_refresh", "after_attestation", "after_full_sync").forEach { directive ->
            val transport = FixtureTransport(listOf(failureEnvelope(directive)))
            val registry = registry(transport)
            registry.register(authority, PushProvider.FCM, "fcm-token")
            registry.reconcileEligible(authority)
            assertEquals(1, transport.requests.size, directive)
        }
    }

    @Test fun `restored unlink preflight gates bearer acquisition by directive and eligibility`() = runBlocking {
        var now = 100L
        val owner = OwnerScope.Anonymous("a"); val authority = PushAuthority(owner, "resumed")
        listOf(ai.onlo.sdk.protocol.RetryDirective.NEVER, ai.onlo.sdk.protocol.RetryDirective.AFTER_ATTESTATION, ai.onlo.sdk.protocol.RetryDirective.AFTER_FULL_SYNC).forEach { directive ->
            val transport = FixtureTransport(emptyList()); val store = MemoryStore(StoredPushToken(owner.storageKey(), "fcm", false, true, retryDirective = directive))
            val registry = registry(transport, store, { now })
            assertEquals(false, registry.needsFreshBearerNow(owner.storageKey()))
            assertEquals(PushRegistrationOutcome.PendingServer(directive), registry.reconcileUnregister(authority, true))
            assertTrue(transport.requests.isEmpty())
        }
        val deferred = MemoryStore(StoredPushToken(owner.storageKey(), "fcm", false, true, retryDirective = ai.onlo.sdk.protocol.RetryDirective.AFTER_BACKOFF, retryEligibleAtMs = 101))
        val transport = FixtureTransport(listOf(unregisterResponse())); val registry = registry(transport, deferred, { now })
        assertEquals(false, registry.needsFreshBearerNow(owner.storageKey())); assertEquals(0, transport.requests.size)
        now = 101L; assertEquals(true, registry.needsFreshBearerNow(owner.storageKey())); assertEquals(PushRegistrationOutcome.Unregistered, registry.reconcileUnregister(authority, true)); assertEquals(1, transport.requests.size)
    }

    @Test fun `restored token refresh unlink uses fresh bearer once`() = runBlocking {
        val owner = OwnerScope.Anonymous("a"); val store = MemoryStore(StoredPushToken(owner.storageKey(), "fcm", false, true, retryDirective = ai.onlo.sdk.protocol.RetryDirective.AFTER_TOKEN_REFRESH, retryAttempt = 1))
        val transport = FixtureTransport(listOf(unregisterResponse())); val registry = registry(transport, store)
        assertEquals(true, registry.needsFreshBearerNow(owner.storageKey()))
        assertEquals(PushRegistrationOutcome.Unregistered, registry.reconcileUnregister(PushAuthority(owner, "resumed-bearer"), true))
        assertEquals("Bearer resumed-bearer", transport.requests.single().headers["Authorization"])
    }

    private fun registry(transport: FixtureTransport, store: MemoryStore = MemoryStore(), nowMs: () -> Long = { 0L }) = PushRegistry(store, OnloPushApi(transport, ProtocolRequestFactory("https://sdk.example.test/".toHttpUrl())), nowMs)
    private fun payload() = mapOf("conversationId" to "c", "messageId" to "m", "notificationType" to "message_available")
    private fun registerResponse() = OnloHttpResponse(200, emptyMap(), successEnvelope("{\"state\":\"active\",\"provider\":\"fcm\",\"environment\":\"production\",\"fingerprint\":\"fixture\",\"registeredAt\":\"2026-01-01T00:00:00Z\"}"))
    private fun unregisterResponse() = OnloHttpResponse(200, emptyMap(), successEnvelope("{\"state\":\"inactive\"}"))
    private fun successEnvelope(result: String) = "{\"requestId\":\"request-1\",\"serverTime\":\"2026-01-01T00:00:00Z\",\"protocolVersion\":1,\"minimumProtocolVersion\":1,\"ok\":true,\"result\":$result}"
    private fun failureEnvelope(directive: String, retryAfterMs: Long? = null) = "{\"requestId\":\"request-1\",\"serverTime\":\"2026-01-01T00:00:00Z\",\"protocolVersion\":1,\"minimumProtocolVersion\":1,\"ok\":false,\"error\":{\"code\":\"dependency_unavailable\",\"message\":\"fixture\",\"retry\":{\"directive\":\"$directive\"${retryAfterMs?.let { ",\\\"retryAfterMs\\\":$it" }.orEmpty()}}}"
    private class MemoryStore(var value: StoredPushToken? = null) : PushTokenStore { override suspend fun load() = value; override suspend fun save(value: StoredPushToken) { this.value = value }; override suspend fun clear() { value = null } }
    private class FixtureTransport(private val responses: List<OnloHttpResponse>) : OnloTransport {
        val requests = mutableListOf<OnloHttpRequest>(); private var index = 0
        override suspend fun execute(request: OnloHttpRequest): OnloHttpResponse { requests += request; return responses.getOrNull(index++) ?: throw IOException("fixture") }
    }
    private fun OnloHttpRequest.bodyText(): String = Buffer().use { buffer -> checkNotNull(body).writeTo(buffer); buffer.readUtf8() }
}
