package ai.onlo.sdk.config

import ai.onlo.sdk.transport.OnloConfigApi
import ai.onlo.sdk.transport.OnloHttpRequest
import ai.onlo.sdk.transport.OnloHttpResponse
import ai.onlo.sdk.transport.OnloTransport
import ai.onlo.sdk.transport.ProtocolRequestFactory
import java.io.IOException
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertIs
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.async
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import okhttp3.HttpUrl.Companion.toHttpUrl

class MobileConfigControllerTest {
    @Test fun `fixture 200 persists validated etag and sends required conditional headers`() = runBlocking {
        val transport = FixtureTransport(OnloHttpResponse(200, mapOf("ETag" to "W/\"fixture\""), envelope(CONFIG)))
        val store = MemoryStore()
        val controller = controller(transport, store)
        assertIs<ConfigRefreshResult.Updated>(controller.refresh("synthetic-token", 0))
        assertEquals("W/\"fixture\"", store.value?.etag)
        assertEquals("1", transport.requests.single().headers["X-Onlo-Config-Schema"])
        assertEquals("Bearer synthetic-token", transport.requests.single().headers["Authorization"])
        assertEquals("fixture-revision", controller.snapshot.value.revision)
    }

    @Test fun `304 retains encrypted last known good and uses its etag`() = runBlocking {
        val store = MemoryStore(StoredMobileConfig("W/\"fixture\"", CONFIG))
        val transport = FixtureTransport(OnloHttpResponse(304, emptyMap(), ""))
        val controller = controller(transport, store)
        controller.restoreLastKnownGood()
        assertIs<ConfigRefreshResult.Unchanged>(controller.refresh("synthetic-token", 0))
        assertEquals("W/\"fixture\"", transport.requests.single().headers["If-None-Match"])
        assertEquals("fixture-revision", controller.snapshot.value.revision)
    }

    @Test fun `malformed config never replaces last known good`() = runBlocking {
        val store = MemoryStore(StoredMobileConfig("W/\"old\"", CONFIG))
        val controller = controller(FixtureTransport(OnloHttpResponse(200, emptyMap(), envelope(CONFIG.replace("\"sdk_interface\"", "\"invented\"")))), store)
        controller.restoreLastKnownGood()
        assertIs<ConfigRefreshResult.RetainedLastKnownGood>(controller.refresh("synthetic-token", 0))
        assertEquals("fixture-revision", controller.snapshot.value.revision)
        assertEquals("W/\"old\"", store.value?.etag)
    }

    @Test fun `offline retains LKG without writing plaintext or clearing it`() = runBlocking {
        val store = MemoryStore(StoredMobileConfig("W/\"fixture\"", CONFIG))
        val controller = controller(FixtureTransport(failure = IOException("synthetic")), store)
        controller.restoreLastKnownGood()
        assertIs<ConfigRefreshResult.RetainedLastKnownGood>(controller.refresh("synthetic-token", 0))
        assertEquals(CONFIG, store.value?.raw)
    }

    @Test fun `no LKG backoff survives restart and sends zero early requests`() = runBlocking {
        var now = 1_000L
        val store = MemoryStore()
        val first = FixtureTransport(OnloHttpResponse(503, emptyMap(), failure("config_unavailable", "after_backoff", 9_999_999L)))
        assertIs<ConfigRefreshResult.RetainedLastKnownGood>(MobileConfigController(OnloConfigApi(first, requests()), store, nowMs = { now }, fallbackBackoffJitter = { 0.0 }).refresh("synthetic-token", 0))
        assertEquals(null, store.value?.raw)
        val second = FixtureTransport(OnloHttpResponse(200, mapOf("ETag" to "W/\"fixture\""), envelope(CONFIG)))
        val restarted = MobileConfigController(OnloConfigApi(second, requests()), store, nowMs = { now })
        restarted.restoreLastKnownGood()
        assertIs<ConfigRefreshResult.RetainedLastKnownGood>(restarted.refresh("synthetic-token", 0))
        assertEquals(0, second.requests.size)
        now += 9_999_999L
        assertIs<ConfigRefreshResult.Updated>(restarted.refresh("synthetic-token", 0))
        assertEquals(1, second.requests.size)
    }

    @Test fun `late response after boundary is discarded`() = runBlocking {
        val gate = CompletableDeferred<OnloHttpResponse>()
        val started = CompletableDeferred<Unit>()
        val transport = object : OnloTransport {
            override suspend fun execute(request: OnloHttpRequest): OnloHttpResponse {
                started.complete(Unit)
                return gate.await()
            }
        }
        val controller = MobileConfigController(OnloConfigApi(transport, requests()), MemoryStore())
        val request = async(Dispatchers.Default) { controller.refresh("synthetic-token", 0) }
        started.await()
        controller.onSessionBoundary()
        gate.complete(OnloHttpResponse(200, mapOf("ETag" to "W/\"fixture\""), envelope(CONFIG)))
        assertIs<ConfigRefreshResult.SessionSuperseded>(request.await())
        assertEquals(null, controller.snapshot.value.config)
    }

    @Test fun `fallback jitter delays and backoff scheduler is capped at three attempts`() = runBlocking {
        var now = 1_000L
        val response = OnloHttpResponse(503, emptyMap(), failure("config_unavailable", "after_backoff", null))
        val transport = FixtureTransport(response)
        val controller = MobileConfigController(OnloConfigApi(transport, requests()), MemoryStore(), nowMs = { now }, fallbackBackoffJitter = { 0.0 })
        assertIs<ConfigRefreshResult.RetainedLastKnownGood>(controller.refresh("synthetic-token", 0))
        now = 1_374L
        assertIs<ConfigRefreshResult.RetainedLastKnownGood>(controller.refresh("synthetic-token", 0))
        assertEquals(1, transport.requests.size)
        now = 1_375L
        repeat(3) { controller.refresh("synthetic-token", 0); now += 30_000L }
    }

    @Test fun `scheduled backoff dispatches two retries for three total attempts`() = runBlocking {
        val transport = FixtureTransport(OnloHttpResponse(503, emptyMap(), failure("config_unavailable", "after_backoff", 1)))
        val controller = MobileConfigController(OnloConfigApi(transport, requests()), MemoryStore(), scope = CoroutineScope(Dispatchers.Default))
        controller.refresh("synthetic-token", 0)
        repeat(50) { if (transport.requests.size >= 3) return@repeat; delay(2) }
        assertEquals(3, transport.requests.size) // initial request + exactly two scheduled retries
    }

    private fun controller(transport: FixtureTransport, store: MemoryStore) = MobileConfigController(OnloConfigApi(transport, requests()), store, nowMs = { 1_000L })
    private fun requests() = ProtocolRequestFactory("https://onlo.ai/".toHttpUrl())
    private class MemoryStore(var value: StoredMobileConfig? = null) : ProtectedConfigStore { override suspend fun load() = value; override suspend fun save(value: StoredMobileConfig) { this.value = value }; override suspend fun clear() { value = null } }
    private class FixtureTransport(private val response: OnloHttpResponse? = null, private val failure: IOException? = null) : OnloTransport { val requests = mutableListOf<OnloHttpRequest>(); override suspend fun execute(request: OnloHttpRequest): OnloHttpResponse { requests += request; failure?.let { throw it }; return checkNotNull(response) } }
    private fun envelope(result: String) = """{"requestId":"fixture","serverTime":"2026-01-01T00:00:00Z","protocolVersion":1,"minimumProtocolVersion":1,"ok":true,"result":$result}"""
    private fun failure(code: String, directive: String, retryAfterMs: Long?) = """{"requestId":"fixture","serverTime":"2026-01-01T00:00:00Z","protocolVersion":1,"minimumProtocolVersion":1,"ok":false,"error":{"code":"$code","message":"synthetic","retry":{"directive":"$directive"${retryAfterMs?.let { ",\"retryAfterMs\":$it" }.orEmpty()}}}}"""

    private companion object { const val CONFIG = """{"schemaVersion":1,"revision":"fixture-revision","compatibility":{"requestedSchemaVersion":1,"appliedSchemaVersion":1,"capabilities":["config_schema_v1"],"unsupportedSettings":[]},"securityPolicy":{"minimumProtocolVersion":1,"minimumSdkVersion":null,"identityMode":"sdk_interface","anonymousScope":"installation_generation","nativePlacement":"host_app"},"appearance":{"accent":"#000000","botName":"Bot","botSubtitle":"Sub","greeting":"Hi","headerAvatar":{"mode":"initials","text":"B","data":null},"light":{"background":"#fff","outgoing":"#000","outgoingText":"#fff","incoming":"#eee","incomingText":"#000"},"dark":{"enabled":true,"background":"#000","outgoing":"#fff","outgoingText":"#000","incoming":"#111","incomingText":"#fff"}},"features":{"insertLink":false,"insertCode":false,"emoji":true,"gifs":false,"voice":false,"fileUpload":false,"transcriptDownload":false,"soundNotifications":false,"showTimestamps":true,"faqButton":{"enabled":false,"label":"Help"}},"mediaPolicy":{"enabled":false,"maximumImagesPerMessage":0,"maximumImageBytes":8388608},"content":{"faqs":[],"tabs":{"enabled":true,"tabs":[],"defaultTab":"home"},"search":{"enabled":true,"placeholder":"Search","showSearchInHome":true},"onboarding":{"enabled":false,"title":"Welcome","showProgress":false,"items":[]},"homeSections":[]},"identityMode":"sdk_interface","unsupportedWidgetSettings":[]}""" }
}
