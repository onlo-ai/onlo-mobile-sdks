package ai.onlo.sdk

import ai.onlo.sdk.logging.SafeLogEvent
import ai.onlo.sdk.logging.SafeLogger
import ai.onlo.sdk.config.MobileConfigController
import ai.onlo.sdk.config.ProtectedConfigStore
import ai.onlo.sdk.config.StoredMobileConfig
import ai.onlo.sdk.transport.OnloConfigApi
import ai.onlo.sdk.protocol.IdentityClass
import ai.onlo.sdk.protocol.PushProvider
import ai.onlo.sdk.protocol.RetryDirective
import ai.onlo.sdk.protocol.SessionResult
import ai.onlo.sdk.security.CredentialLoad
import ai.onlo.sdk.security.CredentialStore
import ai.onlo.sdk.security.ProtectedSession
import ai.onlo.sdk.security.ProtectedSessionState
import ai.onlo.sdk.storage.OutboxEntry
import ai.onlo.sdk.storage.OutboxEntryFactory
import ai.onlo.sdk.storage.OwnerBlockedException
import ai.onlo.sdk.storage.OwnerScope
import ai.onlo.sdk.storage.OwnerScopedOutboxStore
import ai.onlo.sdk.transport.OnloHttpRequest
import ai.onlo.sdk.transport.OnloHttpResponse
import ai.onlo.sdk.transport.OnloSessionApi
import ai.onlo.sdk.transport.OnloTransport
import ai.onlo.sdk.transport.OnloSseTransport
import ai.onlo.sdk.transport.ProtocolRequestFactory
import ai.onlo.sdk.transport.SseStreamResult
import ai.onlo.sdk.chat.ForegroundStream
import ai.onlo.sdk.chat.WidgetChatApi
import ai.onlo.sdk.push.PushRegistry
import ai.onlo.sdk.push.PushRegistrationOutcome
import ai.onlo.sdk.push.PushTokenStore
import ai.onlo.sdk.push.StoredPushToken
import ai.onlo.sdk.push.KeystorePushTokenStore
import ai.onlo.sdk.transport.OnloPushApi
import java.io.IOException
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertTrue
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.async
import kotlinx.coroutines.CompletableDeferred
import okhttp3.HttpUrl.Companion.toHttpUrl
import okio.Buffer

class OnloClientLifecycleTest {
    @Test
    fun `lifecycle recovery replays the stored resume transition exactly`() = runBlocking {
        val stored = protectedAnonymous()
        val pending = ai.onlo.sdk.security.PendingSessionTransition.Resume(
            installationId = stored.installationId,
            transitionId = "resume-transition",
            expectedGeneration = stored.generation,
            presentedCredential = stored.credential,
            proposedCredential = "synthetic-next-credential",
        )
        val credentials = FakeCredentials().apply { state = ProtectedSessionState(stored, pending) }
        val transport = FixtureTransport(listOf(sessionResult(IdentityClass.ANONYMOUS)), emptyList())
        val client = client(credentials, FakeOutbox(), transport = transport)

        client.recoverOfflineSessionForLifecycle()

        assertEquals(OnloPhase.ANONYMOUS_READY, client.state.value.phase)
        assertEquals(1, transport.sessionBodies.size)
        assertTrue(transport.sessionBodies.single().contains("resume-transition"))
    }

    @Test
    fun `lifecycle recovery never replays pending identify without a host jwt`() = runBlocking {
        val stored = protectedAnonymous()
        val pending = ai.onlo.sdk.security.PendingSessionTransition.Identify(
            installationId = stored.installationId,
            transitionId = "identify-transition",
            expectedGeneration = stored.generation,
            presentedCredential = stored.credential,
            proposedCredential = "synthetic-next-credential",
        )
        val credentials = FakeCredentials().apply { state = ProtectedSessionState(stored, pending) }
        val transport = FixtureTransport(emptyList(), emptyList())
        val client = client(credentials, FakeOutbox(), transport = transport)

        client.recoverOfflineSessionForLifecycle()

        assertEquals(OnloPhase.REAUTHENTICATION_REQUIRED, client.state.value.phase)
        assertTrue(transport.sessionBodies.isEmpty())
    }

    @Test
    fun `identification retires anonymous partition before persisting identified session`() = runBlocking {
        val credentials = FakeCredentials()
        val outbox = FakeOutbox()
        val client = client(
            credentials = credentials,
            outbox = outbox,
            responses = listOf(sessionResult(IdentityClass.ANONYMOUS), sessionResult(IdentityClass.IDENTIFIED)),
        )

        client.loginUnidentifiedUser()
        val anonymousOwner = checkNotNull(credentials.session).ownerScopeId
        client.loginIdentifiedUser("header.payload.signature")

        assertEquals(listOf("anonymous:$anonymousOwner"), outbox.blockedAndPurged)
        assertEquals(IdentityClass.IDENTIFIED, credentials.session?.identityClass)
        assertTrue(credentials.session?.ownerScopeId != anonymousOwner)
        assertEquals(OnloPhase.IDENTIFIED_READY, client.state.value.phase)
    }

    @Test
    fun `failed logout blocks old owner before another account can be used`() = runBlocking {
        val old = ProtectedSession(
            installationId = "00000000-0000-0000-0000-000000000001",
            credential = "synthetic-credential",
            generation = 1,
            ownerScopeId = "owner-a",
            identityClass = IdentityClass.IDENTIFIED,
            logoutPending = false,
        )
        val credentials = FakeCredentials(old)
        val outbox = FakeOutbox()
        val client = client(credentials, outbox, failures = listOf(IOException("synthetic transport failure")))

        val outcome = client.logout()

        assertEquals(LogoutOutcome.Pending("transport_unavailable"), outcome)
        assertEquals(listOf("identified:owner-a"), outbox.blocked)
        assertEquals(true, credentials.session?.logoutPending)
        assertFailsWith<OnloException.LogoutInProgress> { client.loginUnidentifiedUser() }
        Unit
    }

    @Test
    fun `lost bootstrap response is replayed exactly after process recovery`() = runBlocking {
        val credentials = FakeCredentials()
        val first = FixtureTransport(emptyList(), listOf(IOException("fixture")))
        assertFailsWith<OnloException.Unavailable> { client(credentials, FakeOutbox(), transport = first).loginUnidentifiedUser() }

        val replay = FixtureTransport(listOf(sessionResult(IdentityClass.ANONYMOUS)), emptyList())
        client(credentials, FakeOutbox(), transport = replay).loginUnidentifiedUser()

        assertEquals(first.sessionBodies.single(), replay.sessionBodies.single())
        assertEquals(null, credentials.state?.pendingTransition)
    }

    @Test
    fun `lost resume and logout responses preserve their exact requests`() = runBlocking {
        val old = protectedAnonymous()
        val credentials = FakeCredentials(old)
        val resumeFirst = FixtureTransport(emptyList(), listOf(IOException("fixture")))
        assertFailsWith<OnloException.Unavailable> { client(credentials, FakeOutbox(), transport = resumeFirst).loginUnidentifiedUser() }
        val resumeReplay = FixtureTransport(listOf(sessionResult(IdentityClass.ANONYMOUS)), emptyList())
        client(credentials, FakeOutbox(), transport = resumeReplay).loginUnidentifiedUser()
        assertEquals(resumeFirst.sessionBodies.single(), resumeReplay.sessionBodies.single())

        val logoutFirst = FixtureTransport(emptyList(), listOf(IOException("fixture")))
        assertEquals(LogoutOutcome.Pending("transport_unavailable"), client(credentials, FakeOutbox(), transport = logoutFirst).logout())
        val logoutReplay = FixtureTransport(listOf(sessionResult(IdentityClass.ANONYMOUS)), emptyList())
        assertEquals(LogoutOutcome.Completed, client(credentials, FakeOutbox(), transport = logoutReplay).logout())
        assertEquals(logoutFirst.sessionBodies.single(), logoutReplay.sessionBodies.single())
    }

    @Test
    fun `uncertain identify persists no jwt and replays fields only when host resupplies jwt`() = runBlocking {
        val credentials = FakeCredentials(protectedAnonymous())
        val first = FixtureTransport(emptyList(), listOf(IOException("fixture")))
        assertFailsWith<OnloException.Unavailable> {
            client(credentials, FakeOutbox(), transport = first).loginIdentifiedUser("header.fixture.signature")
        }
        assertTrue(credentials.state?.pendingTransition is ai.onlo.sdk.security.PendingSessionTransition.Identify)

        val replay = FixtureTransport(listOf(sessionResult(IdentityClass.IDENTIFIED)), emptyList())
        client(credentials, FakeOutbox(), transport = replay).loginIdentifiedUser("header.reissued.signature")
        assertEquals(operationFields(first.sessionBodies.single()), operationFields(replay.sessionBodies.single()))
        assertTrue(!replay.sessionBodies.single().contains("header.fixture.signature"))
    }

    @Test
    fun `definitive never responses clear pending while transport loss retains it`() = runBlocking {
        val bootstrapCredentials = FakeCredentials()
        assertFailsWith<OnloException.Server> {
            client(bootstrapCredentials, FakeOutbox(), transport = FixtureTransport(serverFailures = listOf(RetryDirective.NEVER))).loginUnidentifiedUser()
        }
        assertEquals(null, bootstrapCredentials.state)

        val resumeCredentials = FakeCredentials(protectedAnonymous())
        assertFailsWith<OnloException.Server> {
            client(resumeCredentials, FakeOutbox(), transport = FixtureTransport(serverFailures = listOf(RetryDirective.NEVER))).loginUnidentifiedUser()
        }
        assertEquals(null, resumeCredentials.state?.pendingTransition)

        val identifyCredentials = FakeCredentials(protectedAnonymous())
        assertFailsWith<OnloException.Server> {
            client(identifyCredentials, FakeOutbox(), transport = FixtureTransport(serverFailures = listOf(RetryDirective.NEVER))).loginIdentifiedUser("header.fixture.signature")
        }
        assertEquals(null, identifyCredentials.state?.pendingTransition)

        val logoutCredentials = FakeCredentials(protectedAnonymous())
        val outcome = client(logoutCredentials, FakeOutbox(), transport = FixtureTransport(serverFailures = listOf(RetryDirective.NEVER))).logout()
        assertEquals(LogoutOutcome.Pending("dependency_unavailable"), outcome)
        assertEquals(null, logoutCredentials.state?.pendingTransition)
        assertEquals(true, logoutCredentials.session?.logoutPending)
    }

    @Test
    fun `identity proof refresh retains only the non-secret pending transition`() = runBlocking {
        val credentials = FakeCredentials(protectedAnonymous())
        assertFailsWith<OnloException.Server> {
            client(
                credentials,
                FakeOutbox(),
                transport = FixtureTransport(serverFailures = listOf(RetryDirective.AFTER_TOKEN_REFRESH)),
            ).loginIdentifiedUser("header.fixture.signature")
        }

        assertTrue(credentials.state?.pendingTransition is ai.onlo.sdk.security.PendingSessionTransition.Identify)
    }

    @Test
    fun `after backoff resume retains and reuses the exact request on an explicit retry`() = runBlocking {
        val credentials = FakeCredentials(protectedAnonymous())
        var clock = 1_000L
        val first = FixtureTransport(
            serverFailures = listOf(RetryDirective.AFTER_BACKOFF),
            retryAfterMs = 500L,
        )
        assertFailsWith<OnloException.Server> {
            client(credentials, FakeOutbox(), transport = first, nowMs = { clock }).loginUnidentifiedUser()
        }
        assertTrue(credentials.state?.pendingTransition is ai.onlo.sdk.security.PendingSessionTransition.Resume)

        val replay = FixtureTransport(listOf(sessionResult(IdentityClass.ANONYMOUS)), emptyList())
        assertFailsWith<OnloException.PendingTransitionUnavailable> {
            client(credentials, FakeOutbox(), transport = replay, nowMs = { clock }).loginUnidentifiedUser()
        }
        assertEquals(emptyList(), replay.sessionBodies)

        clock = 1_500L
        client(credentials, FakeOutbox(), transport = replay, nowMs = { clock }).loginUnidentifiedUser()
        assertEquals(first.sessionBodies.single(), replay.sessionBodies.single())
    }

    @Test
    fun `attestation retry remains blocked before any transport call`() = runBlocking {
        val credentials = FakeCredentials(protectedAnonymous())
        assertFailsWith<OnloException.Server> {
            client(
                credentials,
                FakeOutbox(),
                transport = FixtureTransport(serverFailures = listOf(RetryDirective.AFTER_ATTESTATION)),
            ).loginUnidentifiedUser()
        }
        val transport = FixtureTransport()

        assertFailsWith<OnloException.PendingTransitionUnavailable> {
            client(credentials, FakeOutbox(), transport = transport).loginUnidentifiedUser()
        }
        assertEquals(emptyList(), transport.sessionBodies)
    }

    @Test
    fun `fallback backoff uses deterministic bounded jitter and increments after each response`() = runBlocking {
        val credentials = FakeCredentials(protectedAnonymous())
        var clock = 10_000L
        val first = FixtureTransport(serverFailures = listOf(RetryDirective.AFTER_BACKOFF))
        assertFailsWith<OnloException.Server> {
            client(
                credentials,
                FakeOutbox(),
                transport = first,
                nowMs = { clock },
                fallbackBackoffJitter = { 0.0 },
            ).loginUnidentifiedUser()
        }

        // First fallback is 1,000 ms × 0.5 jitter = 500 ms.
        clock = 10_499L
        val second = FixtureTransport()
        assertFailsWith<OnloException.PendingTransitionUnavailable> {
            client(credentials, FakeOutbox(), transport = second, nowMs = { clock }).loginUnidentifiedUser()
        }
        assertEquals(emptyList(), second.sessionBodies)

        clock = 10_500L
        val secondFailure = FixtureTransport(serverFailures = listOf(RetryDirective.AFTER_BACKOFF))
        assertFailsWith<OnloException.Server> {
            client(
                credentials,
                FakeOutbox(),
                transport = secondFailure,
                nowMs = { clock },
                fallbackBackoffJitter = { 0.0 },
            ).loginUnidentifiedUser()
        }
        val pending = credentials.state?.pendingTransition
        assertEquals(2, pending?.retryAttempt)
        assertEquals(11_500L, pending?.retryEligibleAtMs)
    }

    @Test
    fun `logout does not block an owner while a resume transition remains uncertain`() = runBlocking {
        val credentials = FakeCredentials(protectedAnonymous())
        val outbox = FakeOutbox()
        assertFailsWith<OnloException.Unavailable> {
            client(credentials, outbox, transport = FixtureTransport(failures = listOf(IOException("fixture")))).loginUnidentifiedUser()
        }

        assertFailsWith<OnloException.PendingTransitionUnavailable> { client(credentials, outbox).logout() }
        assertEquals(emptyList(), outbox.blocked)
        assertEquals(false, credentials.session?.logoutPending)
    }

    @Test
    fun `identified loginUnidentified revokes first and retires old owner`() = runBlocking {
        val credentials = FakeCredentials(protectedIdentified())
        val outbox = FakeOutbox()
        client(credentials, outbox, responses = listOf(sessionResult(IdentityClass.ANONYMOUS))).loginUnidentifiedUser()
        assertTrue(outbox.blocked.contains("identified:owner-a"))
        assertEquals(IdentityClass.ANONYMOUS, credentials.session?.identityClass)
    }

    @Test
    fun `identified loginIdentified revokes first before exchanging replacement proof`() = runBlocking {
        val credentials = FakeCredentials(protectedIdentified())
        val outbox = FakeOutbox()
        client(credentials, outbox, responses = listOf(sessionResult(IdentityClass.ANONYMOUS), sessionResult(IdentityClass.IDENTIFIED))).loginIdentifiedUser("header.synthetic.signature")
        assertTrue(outbox.blocked.contains("identified:owner-a"))
        assertEquals(IdentityClass.IDENTIFIED, credentials.session?.identityClass)
    }

    @Test
    fun `retired owner stays blocked after payload purge and cannot enqueue or read eligible work`() = runBlocking {
        val outbox = FakeOutbox()
        val retired = OwnerScope.Identified("owner-a")
        outbox.blockOwner(retired)
        outbox.purgeOwner(retired)
        assertFailsWith<OwnerBlockedException> {
            outbox.enqueue(OutboxEntryFactory.create(retired, "local", "synthetic", emptyList(), 1))
        }
        assertEquals(emptyList(), outbox.eligible(retired, 1, 10))
    }

    @Test
    fun `config token refresh performs one session resume and one nonrecursive config retry`() = runBlocking {
        val transport = ConfigTokenRefreshTransport()
        val requests = ProtocolRequestFactory("https://onlo.ai/".toHttpUrl())
        val controller = MobileConfigController(OnloConfigApi(transport, requests), ConfigMemoryStore())
        val client = client(FakeCredentials(protectedAnonymous()), FakeOutbox(), transport = transport, configController = controller)
        client.loginUnidentifiedUser()
        // Unconfined test scope executes the post-lock config job deterministically.
        assertEquals(2, transport.sessionCalls)
        assertEquals(2, transport.configCalls)
        assertTrue(transport.sessionBodies.all { !it.contains("userJwt") })
    }

    @Test
    fun `foreground stream starts with refreshed bearer after token rotation`() = runBlocking {
        val transport = ConfigTokenRefreshTransport()
        val requests = ProtocolRequestFactory("https://onlo.ai/".toHttpUrl())
        val controller = MobileConfigController(OnloConfigApi(transport, requests), ConfigMemoryStore())
        val client = OnloClient(
            configuration = OnloConfiguration("public-sdk-key", "ai.onlo.fixture"), credentialStore = FakeCredentials(protectedAnonymous()), outboxStore = FakeOutbox(),
            sessionApi = OnloSessionApi(transport, requests), configController = controller, foregroundStream = ForegroundStream(transport, requests),
            logger = SafeLogger { _: SafeLogEvent -> }, scope = CoroutineScope(Dispatchers.Unconfined),
        )
        client.loginUnidentifiedUser()
        client.onAppForeground()
        assertEquals(listOf("Bearer synthetic-chat-token-2"), transport.streamAuthorizations)
    }

    @Test
    fun `mismatched pending resume is rejected before transport`() = runBlocking {
        val stored = protectedAnonymous()
        val credentials = FakeCredentials().apply {
            state = ProtectedSessionState(
                session = stored,
                pendingTransition = ai.onlo.sdk.security.PendingSessionTransition.Resume(
                    installationId = stored.installationId,
                    transitionId = "00000000-0000-0000-0000-000000000009",
                    expectedGeneration = stored.generation + 1,
                    presentedCredential = stored.credential,
                    proposedCredential = "synthetic-proposed",
                ),
            )
        }
        val transport = FixtureTransport()

        assertFailsWith<OnloException.PendingTransitionUnavailable> {
            client(credentials, FakeOutbox(), transport = transport).loginUnidentifiedUser()
        }
        assertEquals(emptyList(), transport.sessionBodies)
    }

    @Test
    fun `logout cancels foreground stream before the next account can be used`() = runBlocking {
        val transport = ForegroundCancellationTransport()
        val requests = ProtocolRequestFactory("https://onlo.ai/".toHttpUrl())
        val controller = MobileConfigController(OnloConfigApi(transport, requests), ConfigMemoryStore())
        val client = OnloClient(
            configuration = OnloConfiguration("public-sdk-key", "ai.onlo.fixture"),
            credentialStore = FakeCredentials(),
            outboxStore = FakeOutbox(),
            sessionApi = OnloSessionApi(transport, requests),
            logger = SafeLogger { _: SafeLogEvent -> },
            scope = CoroutineScope(Dispatchers.Unconfined),
            configController = controller,
            foregroundStream = ForegroundStream(transport, requests),
        )

        client.loginUnidentifiedUser()
        client.onAppForeground()
        assertTrue(transport.streamStarted)
        assertEquals(LogoutOutcome.Completed, client.logout())
        assertTrue(transport.streamCancelled)
    }

    @Test
    fun `delayed conversation fetch cannot present after logout switches authority`() = runBlocking {
        val transport = BlockingConversationTransport()
        val requests = ProtocolRequestFactory("https://onlo.ai/".toHttpUrl())
        val client = OnloClient(
            configuration = OnloConfiguration("public-sdk-key", "ai.onlo.fixture"),
            credentialStore = FakeCredentials(), outboxStore = FakeOutbox(),
            sessionApi = OnloSessionApi(transport, requests), widgetChatApi = WidgetChatApi(transport, requests),
            logger = SafeLogger { _: SafeLogEvent -> }, scope = CoroutineScope(Dispatchers.Unconfined),
        )
        client.loginUnidentifiedUser()
        val opening = async { client.openConversation("conversation-1") }
        transport.transcriptStarted.await()
        assertEquals(LogoutOutcome.Completed, client.logout())
        transport.releaseTranscript.complete(Unit)
        assertEquals(OpenConversationOutcome.NoActiveSession, opening.await())
        assertEquals(MessengerPresentationIntent.HIDDEN, client.presentationIntent.value)
        assertEquals(MessengerPresentationTarget.Inbox, client.presentationTarget.value)
    }

    @Test
    fun `authorised conversation fetch selects the native presentation target`() = runBlocking {
        val transport = BlockingConversationTransport()
        val requests = ProtocolRequestFactory("https://onlo.ai/".toHttpUrl())
        val client = OnloClient(
            configuration = OnloConfiguration("public-sdk-key", "ai.onlo.fixture"),
            credentialStore = FakeCredentials(), outboxStore = FakeOutbox(),
            sessionApi = OnloSessionApi(transport, requests), widgetChatApi = WidgetChatApi(transport, requests),
            logger = SafeLogger { _: SafeLogEvent -> }, scope = CoroutineScope(Dispatchers.Unconfined),
        )
        client.loginUnidentifiedUser()
        val opening = async { client.openConversation("conversation-1") }
        transport.transcriptStarted.await()
        transport.releaseTranscript.complete(Unit)

        assertEquals(OpenConversationOutcome.Opened, opening.await())
        assertEquals(MessengerPresentationIntent.PRESENT, client.presentationIntent.value)
        assertEquals(MessengerPresentationTarget.Conversation("conversation-1"), client.presentationTarget.value)
    }

    @Test
    fun `restoration resumes then unlinks push before sending a fresh logout`() = runBlocking {
        val old = protectedAnonymous().copy(logoutPending = true)
        val credentials = FakeCredentials().apply { state = ProtectedSessionState(old, ai.onlo.sdk.security.PendingSessionTransition.Logout(old.installationId, "old-logout", old.generation, old.credential, "unused")) }
        val transport = PushRecoveryTransport(unlinkSucceeds = true)
        val requests = ProtocolRequestFactory("https://onlo.ai/".toHttpUrl())
        val tokenStore = MemoryPushStore(StoredPushToken(OwnerScope.Anonymous(old.ownerScopeId).storageKey(), "fcm", registered = true, pendingUnregister = true))
        val client = OnloClient(OnloConfiguration("public-sdk-key", "ai.onlo.fixture"), credentials, FakeOutbox(), OnloSessionApi(transport, requests), SafeLogger { _: SafeLogEvent -> }, CoroutineScope(Dispatchers.Unconfined), pushRegistry = PushRegistry(tokenStore, OnloPushApi(transport, requests)))
        client.startRestoration()
        assertEquals(listOf("resume", "unregister", "logout"), transport.order)
        assertEquals("Bearer resumed-bearer", transport.pushAuthorization)
        assertEquals(OnloPhase.ANONYMOUS_READY, client.state.value.phase)
        assertEquals(null, tokenStore.value)
    }

    @Test
    fun `unresolved restored unlink stops before logout and remains blocked`() = runBlocking {
        val old = protectedAnonymous().copy(logoutPending = true)
        val credentials = FakeCredentials().apply { state = ProtectedSessionState(old, ai.onlo.sdk.security.PendingSessionTransition.Logout(old.installationId, "old-logout", old.generation, old.credential, "unused")) }
        val transport = PushRecoveryTransport(unlinkSucceeds = false)
        val requests = ProtocolRequestFactory("https://onlo.ai/".toHttpUrl())
        val tokenStore = MemoryPushStore(StoredPushToken(OwnerScope.Anonymous(old.ownerScopeId).storageKey(), "fcm", registered = true, pendingUnregister = true))
        val client = OnloClient(OnloConfiguration("public-sdk-key", "ai.onlo.fixture"), credentials, FakeOutbox(), OnloSessionApi(transport, requests), SafeLogger { _: SafeLogEvent -> }, CoroutineScope(Dispatchers.Unconfined), pushRegistry = PushRegistry(tokenStore, OnloPushApi(transport, requests)))
        client.startRestoration()
        assertEquals(listOf("resume", "unregister"), transport.order)
        assertEquals(OnloPhase.LOGOUT_PENDING, client.state.value.phase)
        assertEquals(true, credentials.session?.logoutPending)
    }

    @Test
    fun `anonymous session queues token locally without a server push association`() = runBlocking {
        val transport = IdentityPushTransport()
        val requests = ProtocolRequestFactory("https://onlo.ai/".toHttpUrl())
        val credentials = FakeCredentials()
        val store = MemoryPushStore(null)
        val client = OnloClient(OnloConfiguration("public-sdk-key", "ai.onlo.fixture"), credentials, FakeOutbox(), OnloSessionApi(transport, requests), SafeLogger { _: SafeLogEvent -> }, CoroutineScope(Dispatchers.Unconfined), pushRegistry = PushRegistry(store, OnloPushApi(transport, requests)))
        client.loginUnidentifiedUser()
        assertEquals(
            PushRegistrationOutcome.QueuedForReconciliation,
            client.registerPushToken(PushProvider.FCM, "synthetic-fcm-token"),
        )
        assertEquals(null, store.value)
        assertTrue(transport.order.isEmpty())
        client.loginIdentifiedUser("header.payload.signature")
        assertEquals(listOf("register"), transport.order)
        assertEquals(true, store.value?.registered)
    }

    @Test
    fun `mismatched protected push owner cannot drive pending logout traffic`() = runBlocking {
        val old = protectedAnonymous().copy(logoutPending = true)
        val credentials = FakeCredentials().apply { state = ProtectedSessionState(old, ai.onlo.sdk.security.PendingSessionTransition.Logout(old.installationId, "logout", old.generation, old.credential, "next")) }
        val transport = RetryPushTransport(); val requests = ProtocolRequestFactory("https://onlo.ai/".toHttpUrl())
        val store = MemoryPushStore(StoredPushToken(OwnerScope.Anonymous("different").storageKey(), "fcm", true, true))
        val client = OnloClient(OnloConfiguration("public-sdk-key", "ai.onlo.fixture"), credentials, FakeOutbox(), OnloSessionApi(transport, requests), SafeLogger { _: SafeLogEvent -> }, CoroutineScope(Dispatchers.Unconfined), pushRegistry = PushRegistry(store, OnloPushApi(transport, requests)))
        client.startRestoration()
        assertTrue(transport.order.isEmpty())
        assertEquals(OnloPhase.LOGOUT_PENDING, client.state.value.phase)
        assertEquals(MessengerPresentationIntent.HIDDEN, client.presentationIntent.value)
    }

    private fun client(
        credentials: FakeCredentials,
        outbox: FakeOutbox,
        responses: List<SessionResult> = emptyList(),
        failures: List<IOException> = emptyList(),
        transport: OnloTransport? = null,
        nowMs: () -> Long = { 1_000L },
        fallbackBackoffJitter: () -> Double = { 0.0 },
        configController: MobileConfigController? = null,
    ): OnloClient = OnloClient(
        configuration = OnloConfiguration("public-sdk-key", "ai.onlo.fixture"),
        credentialStore = credentials,
        outboxStore = outbox,
        sessionApi = OnloSessionApi(
            transport = transport ?: FixtureTransport(responses, failures),
            requests = ProtocolRequestFactory("https://onlo.ai/".toHttpUrl()),
        ),
        logger = SafeLogger { _: SafeLogEvent -> },
        scope = CoroutineScope(Dispatchers.Unconfined),
        configController = configController,
        nowMs = nowMs,
        fallbackBackoffJitter = fallbackBackoffJitter,
    )

    private fun sessionResult(identity: IdentityClass): SessionResult = SessionResult(
        sessionId = "synthetic-session",
        chatToken = "synthetic-chat-token",
        installationId = "00000000-0000-0000-0000-000000000001",
        generation = 1,
        proposedCredential = "synthetic-rotated-credential",
        identityClass = identity,
        publicationState = ai.onlo.sdk.protocol.PublicationState.TESTING,
        attestationState = "not_required",
        configRevision = "fixture-revision",
        configSchemaVersion = 1,
        configEtag = "fixture-etag",
    )

    private fun protectedAnonymous() = ProtectedSession(
        installationId = "00000000-0000-0000-0000-000000000001",
        credential = "synthetic-credential",
        generation = 1,
        ownerScopeId = "owner-a",
        identityClass = IdentityClass.ANONYMOUS,
        logoutPending = false,
    )

    private fun protectedIdentified() = protectedAnonymous().copy(identityClass = IdentityClass.IDENTIFIED)

    private fun operationFields(body: String): String = org.json.JSONObject(body).getJSONObject("operation").apply {
        remove("userJwt")
    }.toString()

    private class FakeCredentials(session: ProtectedSession? = null) : CredentialStore {
        var state: ProtectedSessionState? = session?.let { ProtectedSessionState(it, null) }
        val session: ProtectedSession? get() = state?.session
        override suspend fun load(): CredentialLoad = state?.let(CredentialLoad::Found) ?: CredentialLoad.Empty
        override suspend fun save(state: ProtectedSessionState) { this.state = state }
        override suspend fun clear() { state = null }
    }

    private class FakeOutbox : OwnerScopedOutboxStore {
        val blocked = mutableListOf<String>()
        val blockedAndPurged = mutableListOf<String>()
        private val blockedKeys = mutableSetOf<String>()
        override suspend fun enqueue(entry: OutboxEntry) { if (entry.ownerScope.storageKey() in blockedKeys) throw OwnerBlockedException() }
        override suspend fun eligible(ownerScope: OwnerScope, nowMs: Long, limit: Int): List<OutboxEntry> = if (ownerScope.storageKey() in blockedKeys) emptyList() else emptyList()
        override suspend fun markSending(ownerScope: OwnerScope, clientMessageId: String) = false
        override suspend fun markAccepted(ownerScope: OwnerScope, clientMessageId: String, serverMessageId: String) = Unit
        override suspend fun markRetryableFailure(ownerScope: OwnerScope, clientMessageId: String, errorCode: String, nextAttemptAtMs: Long) = Unit
        override suspend fun markTerminalFailure(ownerScope: OwnerScope, clientMessageId: String, errorCode: String) = Unit
        override suspend fun recoverInterruptedSends(ownerScope: OwnerScope, nowMs: Long) = Unit
        override suspend fun blockOwner(ownerScope: OwnerScope) { blocked += ownerScope.storageKey(); blockedKeys += ownerScope.storageKey() }
        override suspend fun blockAndPurgeOwner(ownerScope: OwnerScope) { blockedAndPurged += ownerScope.storageKey(); blockedKeys += ownerScope.storageKey() }
        override suspend fun purgeOwner(ownerScope: OwnerScope) = Unit
        override suspend fun clearAll() = Unit
        override suspend fun replaceTranscript(ownerScope: OwnerScope, conversationId: String, payload: String) = Unit
        override suspend fun transcript(ownerScope: OwnerScope, conversationId: String): String? = null
    }

    private class ConfigMemoryStore : ProtectedConfigStore {
        override suspend fun load(): StoredMobileConfig? = null
        override suspend fun save(value: StoredMobileConfig) = Unit
        override suspend fun clear() = Unit
    }

    /** First config response requests bearer refresh; the retry is terminal to prove no recursion. */
    private class ConfigTokenRefreshTransport : OnloTransport, OnloSseTransport {
        var sessionCalls = 0
        var configCalls = 0
        val sessionBodies = mutableListOf<String>()
        val streamAuthorizations = mutableListOf<String>()
        override suspend fun execute(request: OnloHttpRequest): OnloHttpResponse {
            val path = request.url.encodedPath
            if (path.endsWith("/config")) {
                configCalls += 1
                val retry = if (configCalls == 1) "after_token_refresh" else "never"
                return OnloHttpResponse(401, emptyMap(), """{"requestId":"fixture","serverTime":"2026-01-01T00:00:00Z","protocolVersion":1,"minimumProtocolVersion":1,"ok":false,"error":{"code":"session_expired","message":"synthetic","retry":{"directive":"$retry"}}}""")
            }
            sessionCalls += 1
            val body = request.body?.let { Buffer().also(it::writeTo).readUtf8() }.orEmpty()
            sessionBodies += body
            val proposed = org.json.JSONObject(body).getJSONObject("operation").getString("proposedCredential")
            return OnloHttpResponse(200, emptyMap(), """{"requestId":"fixture","serverTime":"2026-01-01T00:00:00Z","protocolVersion":1,"minimumProtocolVersion":1,"ok":true,"result":{"sessionId":"synthetic-session","chatToken":"synthetic-chat-token-$sessionCalls","installationId":"00000000-0000-0000-0000-000000000001","generation":$sessionCalls,"proposedCredential":"$proposed","identityClass":"anonymous","publicationState":"testing","attestationState":"not_required","configRevision":"fixture","configSchemaVersion":1,"configEtag":"fixture"}}""")
        }

        override suspend fun stream(request: OnloHttpRequest, onLine: suspend (String) -> Unit): SseStreamResult {
            streamAuthorizations += checkNotNull(request.headers["Authorization"])
            return SseStreamResult.Success(200)
        }
    }

    private class ForegroundCancellationTransport : OnloTransport, OnloSseTransport {
        var streamStarted = false
        var streamCancelled = false
        private var sessionCalls = 0

        override suspend fun execute(request: OnloHttpRequest): OnloHttpResponse {
            if (request.url.encodedPath.endsWith("/config")) {
                return OnloHttpResponse(503, emptyMap(), """{"requestId":"fixture","serverTime":"2026-01-01T00:00:00Z","protocolVersion":1,"minimumProtocolVersion":1,"ok":false,"error":{"code":"config_unavailable","message":"synthetic","retry":{"directive":"never"}}}""")
            }
            sessionCalls += 1
            val body = request.body?.let { Buffer().also(it::writeTo).readUtf8() }.orEmpty()
            val proposed = org.json.JSONObject(body).getJSONObject("operation").getString("proposedCredential")
            return OnloHttpResponse(200, emptyMap(), """{"requestId":"fixture","serverTime":"2026-01-01T00:00:00Z","protocolVersion":1,"minimumProtocolVersion":1,"ok":true,"result":{"sessionId":"synthetic-session","chatToken":"synthetic-chat-token","installationId":"00000000-0000-0000-0000-000000000001","generation":1,"proposedCredential":"$proposed","identityClass":"anonymous","publicationState":"testing","attestationState":"not_required","configRevision":"fixture","configSchemaVersion":1,"configEtag":"fixture"}}""")
        }

        override suspend fun stream(request: OnloHttpRequest, onLine: suspend (String) -> Unit): SseStreamResult {
            streamStarted = true
            try {
                awaitCancellation()
            } finally {
                streamCancelled = true
            }
        }
    }

    private class FixtureTransport(
        private val results: List<SessionResult> = emptyList(),
        private val failures: List<IOException> = emptyList(),
        private val serverFailures: List<RetryDirective> = emptyList(),
        private val retryAfterMs: Long? = null,
    ) : OnloTransport {
        private var call = 0
        val sessionBodies = mutableListOf<String>()
        override suspend fun execute(request: OnloHttpRequest): OnloHttpResponse {
            val body = request.body?.let { requestBody -> Buffer().also(requestBody::writeTo).readUtf8() }.orEmpty()
            sessionBodies += body
            failures.getOrNull(call++)?.let { throw it }
            serverFailures.getOrNull(call - 1)?.let { directive ->
                return OnloHttpResponse(200, emptyMap(), failureEnvelope(directive, retryAfterMs))
            }
            val result = checkNotNull(results.getOrNull(call - failures.size - 1))
            val proposedCredential = org.json.JSONObject(body).getJSONObject("operation").getString("proposedCredential")
            return OnloHttpResponse(200, emptyMap(), envelope(result.copy(proposedCredential = proposedCredential)))
        }

        private fun envelope(result: SessionResult): String = """{"requestId":"fixture-request","serverTime":"2026-01-01T00:00:00Z","protocolVersion":1,"minimumProtocolVersion":1,"ok":true,"result":{"sessionId":"${result.sessionId}","chatToken":"${result.chatToken}","installationId":"${result.installationId}","generation":${result.generation},"proposedCredential":"${result.proposedCredential}","identityClass":"${result.identityClass.wireValue}","publicationState":"${result.publicationState.wireValue}","attestationState":"${result.attestationState}","configRevision":"${result.configRevision}","configSchemaVersion":${result.configSchemaVersion},"configEtag":"${result.configEtag}"}}"""
        private fun failureEnvelope(directive: RetryDirective, retryAfterMs: Long?): String {
            val retryAfter = retryAfterMs?.let { ",\"retryAfterMs\":$it" }.orEmpty()
            return """{"requestId":"fixture-request","serverTime":"2026-01-01T00:00:00Z","protocolVersion":1,"minimumProtocolVersion":1,"ok":false,"error":{"code":"dependency_unavailable","message":"fixture","retry":{"directive":"${directive.wireValue}"$retryAfter}}}"""
        }
    }

    private class BlockingConversationTransport : OnloTransport {
        val transcriptStarted = CompletableDeferred<Unit>()
        val releaseTranscript = CompletableDeferred<Unit>()
        override suspend fun execute(request: OnloHttpRequest): OnloHttpResponse {
            if (request.url.encodedPath.contains("/conversations/")) {
                transcriptStarted.complete(Unit); releaseTranscript.await()
                return OnloHttpResponse(200, emptyMap(), """{"conversation":{"id":"conversation-1","sessionId":"synthetic-session","status":"open","isHumanTakeover":false},"messages":[],"sync":{"previousCursor":null,"nextCursor":null,"limit":100}}""")
            }
            val body = request.body?.let { Buffer().also(it::writeTo).readUtf8() }.orEmpty()
            val proposed = org.json.JSONObject(body).getJSONObject("operation").getString("proposedCredential")
            return OnloHttpResponse(200, emptyMap(), """{"requestId":"fixture","serverTime":"2026-01-01T00:00:00Z","protocolVersion":1,"minimumProtocolVersion":1,"ok":true,"result":{"sessionId":"synthetic-session","chatToken":"synthetic-chat-token","installationId":"00000000-0000-0000-0000-000000000001","generation":1,"proposedCredential":"$proposed","identityClass":"anonymous","publicationState":"testing","attestationState":"not_required","configRevision":"fixture","configSchemaVersion":1,"configEtag":"fixture"}}""")
        }
    }

    private class MemoryPushStore(var value: StoredPushToken?) : PushTokenStore {
        override suspend fun load() = value
        override suspend fun save(value: StoredPushToken) { this.value = value }
        override suspend fun clear() { value = null }
    }

    private class PushRecoveryTransport(private val unlinkSucceeds: Boolean) : OnloTransport {
        val order = mutableListOf<String>(); var pushAuthorization: String? = null
        override suspend fun execute(request: OnloHttpRequest): OnloHttpResponse {
            if (request.url.encodedPath.endsWith("push-token")) {
                order += "unregister"; pushAuthorization = request.headers["Authorization"]
                return if (unlinkSucceeds) OnloHttpResponse(200, emptyMap(), envelope("{\"state\":\"inactive\"}"))
                else OnloHttpResponse(503, emptyMap(), failure("after_backoff"))
            }
            val body = request.body?.let { Buffer().also(it::writeTo).readUtf8() }.orEmpty()
            val operation = org.json.JSONObject(body).getJSONObject("operation")
            val type = operation.getString("type"); order += type
            val proposed = operation.getString("proposedCredential")
            return OnloHttpResponse(200, emptyMap(), envelope("{\"sessionId\":\"session-$type\",\"chatToken\":\"${if (type == "resume") "resumed-bearer" else "anonymous-bearer"}\",\"installationId\":\"00000000-0000-0000-0000-000000000001\",\"generation\":2,\"proposedCredential\":\"$proposed\",\"identityClass\":\"anonymous\",\"publicationState\":\"testing\",\"attestationState\":\"not_required\",\"configRevision\":\"fixture\",\"configSchemaVersion\":1,\"configEtag\":\"fixture\"}"))
        }
        private fun envelope(result: String) = "{\"requestId\":\"fixture\",\"serverTime\":\"2026-01-01T00:00:00Z\",\"protocolVersion\":1,\"minimumProtocolVersion\":1,\"ok\":true,\"result\":$result}"
        private fun failure(directive: String) = "{\"requestId\":\"fixture\",\"serverTime\":\"2026-01-01T00:00:00Z\",\"protocolVersion\":1,\"minimumProtocolVersion\":1,\"ok\":false,\"error\":{\"code\":\"dependency_unavailable\",\"message\":\"fixture\",\"retry\":{\"directive\":\"$directive\"}}}"
    }

    private class RetryPushTransport : OnloTransport {
        val order = mutableListOf<String>(); val unlinkAuthorizations = mutableListOf<String>(); private var unlinkCalls = 0
        override suspend fun execute(request: OnloHttpRequest): OnloHttpResponse {
            if (request.url.encodedPath.endsWith("push-token")) {
                order += "unregister"; unlinkAuthorizations += checkNotNull(request.headers["Authorization"]); unlinkCalls += 1
                if (unlinkCalls == 1) throw IOException("fixture")
                return OnloHttpResponse(200, emptyMap(), "{\"requestId\":\"r\",\"serverTime\":\"t\",\"protocolVersion\":1,\"minimumProtocolVersion\":1,\"ok\":true,\"result\":{\"state\":\"inactive\"}}")
            }
            val operation = org.json.JSONObject(checkNotNull(request.body).let { Buffer().also(it::writeTo).readUtf8() }).getJSONObject("operation")
            val type = operation.getString("type"); if (type == "logout") order += "logout"
            val proposed = operation.getString("proposedCredential")
            return OnloHttpResponse(200, emptyMap(), "{\"requestId\":\"r\",\"serverTime\":\"t\",\"protocolVersion\":1,\"minimumProtocolVersion\":1,\"ok\":true,\"result\":{\"sessionId\":\"s\",\"chatToken\":\"initial-bearer\",\"installationId\":\"00000000-0000-0000-0000-000000000001\",\"generation\":1,\"proposedCredential\":\"$proposed\",\"identityClass\":\"anonymous\",\"publicationState\":\"testing\",\"attestationState\":\"x\",\"configRevision\":\"x\",\"configSchemaVersion\":1,\"configEtag\":\"x\"}}")
        }
    }

    private class IdentityPushTransport : OnloTransport {
        val order = mutableListOf<String>()

        override suspend fun execute(request: OnloHttpRequest): OnloHttpResponse {
            if (request.url.encodedPath.endsWith("push-token")) {
                order += "register"
                return OnloHttpResponse(
                    200,
                    emptyMap(),
                    "{\"requestId\":\"r\",\"serverTime\":\"t\",\"protocolVersion\":1,\"minimumProtocolVersion\":1,\"ok\":true,\"result\":{\"state\":\"active\",\"provider\":\"fcm\",\"environment\":\"sandbox\",\"fingerprint\":\"redacted\",\"registeredAt\":\"t\"}}",
                )
            }
            val operation = org.json.JSONObject(
                checkNotNull(request.body).let { Buffer().also(it::writeTo).readUtf8() },
            ).getJSONObject("operation")
            val type = operation.getString("type")
            val proposed = operation.getString("proposedCredential")
            val identity = if (type == "identify") "identified" else "anonymous"
            val generation = if (type == "identify") 2 else 1
            return OnloHttpResponse(
                200,
                emptyMap(),
                "{\"requestId\":\"r\",\"serverTime\":\"t\",\"protocolVersion\":1,\"minimumProtocolVersion\":1,\"ok\":true,\"result\":{\"sessionId\":\"session-$generation\",\"chatToken\":\"bearer-$generation\",\"installationId\":\"00000000-0000-0000-0000-000000000001\",\"generation\":$generation,\"proposedCredential\":\"$proposed\",\"identityClass\":\"$identity\",\"publicationState\":\"testing\",\"attestationState\":\"x\",\"configRevision\":\"x\",\"configSchemaVersion\":1,\"configEtag\":\"x\"}}",
            )
        }
    }
}
