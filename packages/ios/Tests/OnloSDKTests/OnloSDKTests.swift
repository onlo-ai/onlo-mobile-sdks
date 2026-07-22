import Foundation
import CryptoKit
import XCTest
@testable import OnloSDK

final class OnloSDKTests: XCTestCase {
    override func setUp() {
        super.setUp()
        // Async fixture signals must fail visibly rather than leaving Xcode's
        // runner blocked forever when a producer misses its continuation.
        executionTimeAllowance = 10
    }

    func testPublicConfigurationUsesCanonicalProductionOriginAndImplementedCapabilities() {
        XCTAssertEqual(OnloSDK.productionOrigin.absoluteString, "https://onlo.ai")
        XCTAssertEqual(OnloSDK.implementedCapabilities, ["secure_storage", "persistent_outbox", "foreground_stream", "apns", "identity_jwt", "config_schema_v1"])
    }

    func testInstallationCredentialMatchesServerContract() {
        let first = InstallationCredential.generate()
        let second = InstallationCredential.generate()

        XCTAssertEqual(first.count, 43)
        XCTAssertNotEqual(first, second)
        XCTAssertNotNil(first.range(of: #"^[A-Za-z0-9_-]{43}$"#, options: .regularExpression))
    }

    func testSessionRequestEncodesContractOperationWithoutBearer() throws {
        let factory = try OnloRequestFactory(baseURL: URL(string: "https://sdk.example.test")!)
        let request = try factory.session(
            SessionRequest(
                sdkKey: "public-key",
                appIdentifier: "com.example.host",
                client: SDKClientDescriptor(
                    installationId: "installation-1",
                    sdkVersion: "0.1.0",
                    capabilities: ["secure_storage"]
                ),
                operation: .identify(
                    transitionId: "transition-1",
                    expectedGeneration: 2,
                    presentedCredential: "current-credential",
                    proposedCredential: "next-credential",
                    userJwt: "header.payload.signature"
                )
            )
        )

        XCTAssertEqual(request.url?.path, "/api/sdk/v1/session")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        let body = try XCTUnwrap(request.httpBody)
        let decoded = try JSONDecoder().decode(SessionRequest.self, from: body)
        XCTAssertEqual(decoded.client.protocolVersion, 1)
        XCTAssertEqual(decoded.client.runtimePlatform, .ios)
        XCTAssertEqual(decoded.client.sdkFamily, .ios)
        XCTAssertEqual(
            decoded.operation,
            .identify(
                transitionId: "transition-1",
                expectedGeneration: 2,
                presentedCredential: "current-credential",
                proposedCredential: "next-credential",
                userJwt: "header.payload.signature"
            )
        )
    }

    func testInternalAdapterFamilyKeepsIOSRuntimePlatform() throws {
        let descriptor = SDKClientDescriptor(
            installationId: "installation-1",
            runtimePlatform: .ios,
            sdkFamily: .reactNative,
            sdkVersion: "0.1.0",
            capabilities: []
        )
        let decoded = try JSONDecoder().decode(SDKClientDescriptor.self, from: JSONEncoder().encode(descriptor))
        XCTAssertEqual(decoded.runtimePlatform, .ios)
        XCTAssertEqual(decoded.sdkFamily, .reactNative)
    }

    func testUnknownRemoteErrorAndRetryDirectiveFailProtocolDecoding() {
        let unknownCode = Data("{\"requestId\":\"r\",\"serverTime\":\"2026-01-01T00:00:00Z\",\"protocolVersion\":1,\"minimumProtocolVersion\":1,\"ok\":false,\"error\":{\"code\":\"not_a_contract_code\",\"message\":\"safe\",\"retry\":{\"directive\":\"never\"}}}".utf8)
        let unknownRetry = Data("{\"requestId\":\"r\",\"serverTime\":\"2026-01-01T00:00:00Z\",\"protocolVersion\":1,\"minimumProtocolVersion\":1,\"ok\":false,\"error\":{\"code\":\"config_unavailable\",\"message\":\"safe\",\"retry\":{\"directive\":\"future_retry\"}}}".utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(APIEnvelope<SessionResult>.self, from: unknownCode))
        XCTAssertThrowsError(try JSONDecoder().decode(APIEnvelope<SessionResult>.self, from: unknownRetry))
    }

    func testNegativeRetryAfterMsFailsProtocolDecoding() {
        let negativeDelay = Data("{\"requestId\":\"r\",\"serverTime\":\"2026-01-01T00:00:00Z\",\"protocolVersion\":1,\"minimumProtocolVersion\":1,\"ok\":false,\"error\":{\"code\":\"dependency_unavailable\",\"message\":\"safe\",\"retry\":{\"directive\":\"after_backoff\",\"retryAfterMs\":-1}}}".utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(APIEnvelope<SessionResult>.self, from: negativeDelay))
    }

    func testBootstrapLostResponseReplaysExactProtectedPendingTransition() async throws {
        let credentials = InMemoryCredentialStore()
        let transport = LostBootstrapResponseTransport(response: sessionResponse(identityClass: "anonymous", generation: 1, sessionId: "session-1", credential: "credential-1"))
        let configuration = OnloSDK.Configuration(sdkKey: "public-key", appIdentifier: "com.example.host", apiBaseURL: URL(string: "https://sdk.example.test")!)
        let first = OnloSDK(credentialStore: credentials, ownerStore: InMemoryOwnerScopedStore(), transport: transport, hostAppIdentifier: "com.example.host")
        await XCTAssertThrowsErrorAsync {
            try await first.initialize(configuration)
        }

        let recoveredPending = try await credentials.loadState().pendingTransition
        let pending = try XCTUnwrap(recoveredPending)
        let encodedPending = try String(decoding: JSONEncoder().encode(pending), as: UTF8.self)
        XCTAssertFalse(encodedPending.contains("userJwt"))
        XCTAssertFalse(encodedPending.contains("header.payload.signature"))

        let restarted = OnloSDK(credentialStore: credentials, ownerStore: InMemoryOwnerScopedStore(), transport: transport, hostAppIdentifier: "com.example.host")
        let restoredState = try await restarted.initialize(configuration)
        XCTAssertEqual(restoredState, .offlineReady)
        let restartedState = try await restarted.loginUnidentifiedUser()
        XCTAssertEqual(restartedState, .anonymousReady)
        let requests = await transport.requests()
        let sessionRequests = requests.filter { $0.url?.path == "/api/sdk/v1/session" }
        XCTAssertEqual(sessionRequests.count, 2)
        guard sessionRequests.count == 2 else { return }
        try XCTAssertEqualSessionRequestBodies(sessionRequests[0], sessionRequests[1])
        let clearedPending = try await credentials.loadState().pendingTransition
        XCTAssertNil(clearedPending)
    }

    func testResumeLostResponseReplaysExactProtectedPendingTransition() async throws {
        let scope = OwnerScope(kind: .anonymous)
        let credential = StoredSessionCredential(installationId: "installation-1", generation: 7, proposedCredential: "credential-7", identityClass: .anonymous, ownerScope: scope)
        let credentials = InMemoryCredentialStore(credential)
        let transport = LostBootstrapResponseTransport(response: sessionResponse(identityClass: "anonymous", generation: 8, sessionId: "session-8", credential: "credential-8"))
        let configuration = OnloSDK.Configuration(sdkKey: "public-key", appIdentifier: "com.example.host", apiBaseURL: URL(string: "https://sdk.example.test")!)
        let first = OnloSDK(credentialStore: credentials, ownerStore: InMemoryOwnerScopedStore(), transport: transport, hostAppIdentifier: "com.example.host")
        let firstState = try await first.initialize(configuration)
        XCTAssertEqual(firstState, .offlineReady)
        let restarted = OnloSDK(credentialStore: credentials, ownerStore: InMemoryOwnerScopedStore(), transport: transport, hostAppIdentifier: "com.example.host")
        let restoredState = try await restarted.initialize(configuration)
        XCTAssertEqual(restoredState, .offlineReady)
        let restartedState = try await restarted.loginUnidentifiedUser()
        XCTAssertEqual(restartedState, .anonymousReady)
        let requests = await transport.requests()
        let sessionRequests = requests.filter { $0.url?.path == "/api/sdk/v1/session" }
        XCTAssertEqual(sessionRequests.count, 2)
        guard sessionRequests.count == 2 else { return }
        try XCTAssertEqualSessionRequestBodies(sessionRequests[0], sessionRequests[1])
    }

    func testLogoutLostResponseReplaysExactProtectedPendingTransition() async throws {
        let transport = ScriptedSessionTransport(steps: [
            .success(sessionResponse(identityClass: "anonymous", generation: 1, sessionId: "session-1", credential: "credential-1")),
            .failure(.transport(code: "network_unavailable")),
            .success(sessionResponse(identityClass: "anonymous", generation: 2, sessionId: "session-2", credential: "credential-2")),
        ])
        let credentials = InMemoryCredentialStore()
        let configStore = InMemoryConfigStore()
        let pushStore = InMemoryPushIntentStore()
        let configuration = OnloSDK.Configuration(sdkKey: "public-key", appIdentifier: "com.example.host", apiBaseURL: URL(string: "https://sdk.example.test")!)
        let first = OnloSDK(credentialStore: credentials, configStore: configStore, pushIntentStore: pushStore, ownerStore: InMemoryOwnerScopedStore(), transport: transport, hostAppIdentifier: "com.example.host")
        let initializedState = try await first.initialize(configuration)
        XCTAssertEqual(initializedState, .anonymousReady)
        await XCTAssertThrowsErrorAsync {
            try await first.logout()
        }
        let restarted = OnloSDK(credentialStore: credentials, configStore: configStore, pushIntentStore: pushStore, ownerStore: InMemoryOwnerScopedStore(), transport: transport, hostAppIdentifier: "com.example.host")
        let restartedState = try await restarted.initialize(configuration)
        XCTAssertEqual(restartedState, .anonymousReady)
        let requests = await transport.requests()
        let sessionRequests = requests.filter { $0.url?.path == "/api/sdk/v1/session" }
        XCTAssertEqual(sessionRequests.count, 3)
        guard sessionRequests.count == 3 else { return }
        try XCTAssertEqualSessionRequestBodies(sessionRequests[1], sessionRequests[2])
    }

    func testDefinitiveNeverFailureClearsIdentifyAndResumeTransitions() async throws {
        let configuration = OnloSDK.Configuration(sdkKey: "public-key", appIdentifier: "com.example.host", apiBaseURL: URL(string: "https://sdk.example.test")!)

        let identifyCredentials = InMemoryCredentialStore()
        let identifyTransport = ScriptedSessionTransport(steps: [
            .success(sessionResponse(identityClass: "anonymous", generation: 1, sessionId: "session-1", credential: "credential-1")),
            .success(sessionFailure(code: "identity_disabled", directive: "never")),
        ])
        let identifySDK = OnloSDK(credentialStore: identifyCredentials, ownerStore: InMemoryOwnerScopedStore(), transport: identifyTransport, hostAppIdentifier: "com.example.host")
        _ = try await identifySDK.initialize(configuration)
        await XCTAssertThrowsErrorAsync {
            try await identifySDK.loginIdentifiedUser(userJwt: "header.payload.signature")
        }
        let identifyState = try await identifyCredentials.loadState()
        XCTAssertNil(identifyState.pendingTransition)
        XCTAssertEqual(identifyState.credential?.identityClass, .anonymous)

        let scope = OwnerScope(kind: .anonymous)
        let resumeCredentials = InMemoryCredentialStore(StoredSessionCredential(installationId: "installation-1", generation: 1, proposedCredential: "credential-1", identityClass: .anonymous, ownerScope: scope))
        let resumeTransport = ScriptedSessionTransport(steps: [.success(sessionFailure(code: "dependency_unavailable", directive: "never"))])
        let resumeSDK = OnloSDK(credentialStore: resumeCredentials, ownerStore: InMemoryOwnerScopedStore(), transport: resumeTransport, hostAppIdentifier: "com.example.host")
        await XCTAssertThrowsErrorAsync {
            try await resumeSDK.initialize(configuration)
        }
        let resumeState = try await resumeCredentials.loadState()
        XCTAssertNil(resumeState.pendingTransition)
        XCTAssertEqual(resumeState.credential?.proposedCredential, "credential-1")
    }

    func testDefinitiveNeverFailureClearsLogoutTransitionButKeepsBoundaryBlocked() async throws {
        let transport = ScriptedSessionTransport(steps: [
            .success(sessionResponse(identityClass: "anonymous", generation: 1, sessionId: "session-1", credential: "credential-1")),
            .success(sessionFailure(code: "dependency_unavailable", directive: "never")),
        ])
        let credentials = InMemoryCredentialStore()
        let sdk = OnloSDK(credentialStore: credentials, ownerStore: InMemoryOwnerScopedStore(), transport: transport, hostAppIdentifier: "com.example.host")
        let configuration = OnloSDK.Configuration(sdkKey: "public-key", appIdentifier: "com.example.host", apiBaseURL: URL(string: "https://sdk.example.test")!)
        _ = try await sdk.initialize(configuration)
        await XCTAssertThrowsErrorAsync {
            try await sdk.logout()
        }
        let protectedState = try await credentials.loadState()
        XCTAssertNil(protectedState.pendingTransition)
        XCTAssertTrue(protectedState.credential?.logoutPending ?? false)
    }

    func testAfterBackoffRetainsAndReplaysExactBootstrapTransition() async throws {
        let clock = TestClock(Date(timeIntervalSince1970: 1_000))
        let transport = ScriptedSessionTransport(steps: [
            .success(sessionFailure(code: "dependency_unavailable", directive: "after_backoff", retryAfterMs: 1_000)),
            .success(sessionResponse(identityClass: "anonymous", generation: 1, sessionId: "session-1", credential: "credential-1")),
        ])
        let credentials = InMemoryCredentialStore()
        let sdk = OnloSDK(credentialStore: credentials, ownerStore: InMemoryOwnerScopedStore(), transport: transport, hostAppIdentifier: "com.example.host", now: { clock.now() })
        let configuration = OnloSDK.Configuration(sdkKey: "public-key", appIdentifier: "com.example.host", apiBaseURL: URL(string: "https://sdk.example.test")!)
        await XCTAssertThrowsErrorAsync {
            try await sdk.initialize(configuration)
        }
        let retryState = await sdk.currentState()
        XCTAssertEqual(retryState, .offlineReady)
        let retainedTransition = try await credentials.loadState().pendingTransition
        XCTAssertNotNil(retainedTransition)
        await XCTAssertThrowsErrorAsync {
            try await sdk.loginUnidentifiedUser()
        }
        let earlyRequests = await transport.requests()
        XCTAssertEqual(earlyRequests.count, 1)
        clock.advance(by: 1_001)
        let anonymousState = try await sdk.loginUnidentifiedUser()
        XCTAssertEqual(anonymousState, .anonymousReady)
        let requests = await transport.requests()
        let sessionRequests = requests.filter { $0.url?.path == "/api/sdk/v1/session" }
        XCTAssertEqual(sessionRequests.count, 2)
        guard sessionRequests.count == 2 else { return }
        try XCTAssertEqualSessionRequestBodies(sessionRequests[0], sessionRequests[1])
    }

    func testAfterAttestationNeverReplaysWithoutNativeProofRefresh() async throws {
        let transport = ScriptedSessionTransport(steps: [.success(sessionFailure(code: "attestation_required", directive: "after_attestation"))])
        let sdk = OnloSDK(credentialStore: InMemoryCredentialStore(), configStore: InMemoryConfigStore(), pushIntentStore: InMemoryPushIntentStore(), ownerStore: InMemoryOwnerScopedStore(), transport: transport, hostAppIdentifier: "com.example.host")
        let configuration = OnloSDK.Configuration(sdkKey: "public-key", appIdentifier: "com.example.host", apiBaseURL: URL(string: "https://sdk.example.test")!)
        await XCTAssertThrowsErrorAsync {
            try await sdk.initialize(configuration)
        }
        await XCTAssertThrowsErrorAsync {
            try await sdk.loginUnidentifiedUser()
        }
        let requests = await transport.requests()
        XCTAssertEqual(requests.count, 1)
    }

    func testServerSuppliedBackoffDelayIsNotCapped() async throws {
        let start = Date(timeIntervalSince1970: 1_000)
        let clock = TestClock(start)
        let credentials = InMemoryCredentialStore()
        let sdk = OnloSDK(credentialStore: credentials, ownerStore: InMemoryOwnerScopedStore(), transport: ScriptedSessionTransport(steps: [.success(sessionFailure(code: "dependency_unavailable", directive: "after_backoff", retryAfterMs: 120_000))]), hostAppIdentifier: "com.example.host", now: { clock.now() }, backoffJitter: { _ in 0 })
        let configuration = OnloSDK.Configuration(sdkKey: "public-key", appIdentifier: "com.example.host", apiBaseURL: URL(string: "https://sdk.example.test")!)
        await XCTAssertThrowsErrorAsync {
            try await sdk.initialize(configuration)
        }
        let state = try await credentials.loadState()
        guard case let .afterBackoff(eligibleAt, fallbackAttempt) = state.retryGate else { return XCTFail("expected persisted backoff") }
        XCTAssertEqual(fallbackAttempt, 1)
        XCTAssertEqual(eligibleAt, start.addingTimeInterval(120))
    }

    func testFallbackBackoffPersistsAttemptAndInjectedJitter() async throws {
        let start = Date(timeIntervalSince1970: 1_000)
        let clock = TestClock(start)
        let credentials = InMemoryCredentialStore()
        let sdk = OnloSDK(credentialStore: credentials, ownerStore: InMemoryOwnerScopedStore(), transport: ScriptedSessionTransport(steps: [.success(sessionFailure(code: "dependency_unavailable", directive: "after_backoff"))]), hostAppIdentifier: "com.example.host", now: { clock.now() }, backoffJitter: { _ in 0.2 })
        let configuration = OnloSDK.Configuration(sdkKey: "public-key", appIdentifier: "com.example.host", apiBaseURL: URL(string: "https://sdk.example.test")!)
        await XCTAssertThrowsErrorAsync {
            try await sdk.initialize(configuration)
        }
        let state = try await credentials.loadState()
        guard case let .afterBackoff(eligibleAt, fallbackAttempt) = state.retryGate else { return XCTFail("expected persisted fallback") }
        XCTAssertEqual(fallbackAttempt, 1)
        XCTAssertEqual(eligibleAt, start.addingTimeInterval(1.2))
    }

    func testRestartWithTerminalLogoutPendingDoesNotCreateNetworkTransition() async throws {
        let scope = OwnerScope(kind: .identified)
        let credential = StoredSessionCredential(installationId: "installation-1", generation: 1, proposedCredential: "credential-1", identityClass: .identified, ownerScope: scope, logoutPending: true)
        let transport = ScriptedSessionTransport(steps: [])
        let sdk = OnloSDK(credentialStore: InMemoryCredentialStore(credential), ownerStore: InMemoryOwnerScopedStore(), transport: transport, hostAppIdentifier: "com.example.host")
        let configuration = OnloSDK.Configuration(sdkKey: "public-key", appIdentifier: "com.example.host", apiBaseURL: URL(string: "https://sdk.example.test")!)
        let initializedState = try await sdk.initialize(configuration)
        XCTAssertEqual(initializedState, .logoutPending)
        let requests = await transport.requests()
        XCTAssertEqual(requests.count, 0)
    }

    func testPendingLogoutBlocksOwnerStoreWhenRecoveryCannotComplete() async throws {
        let scope = OwnerScope(kind: .identified)
        let credential = StoredSessionCredential(installationId: "installation-1", generation: 1, proposedCredential: "credential-1", identityClass: .identified, ownerScope: scope, logoutPending: true)
        let mismatched = PendingSessionTransition.resume(transitionId: "transition", installationId: "installation-1", expectedGeneration: 1, presentedCredential: "credential-1", proposedCredential: "credential-2")
        let ownerStore = InMemoryOwnerScopedStore()
        try await ownerStore.prepare(scope: scope)
        let entry = OutboxEntry(ownerScope: scope, message: "synthetic", orderingKey: 1)
        try await ownerStore.enqueue(entry)
        let sdk = OnloSDK(credentialStore: InMemoryCredentialStore(credential, pendingTransition: mismatched), ownerStore: ownerStore, transport: ScriptedSessionTransport(steps: []), hostAppIdentifier: "com.example.host")
        let configuration = OnloSDK.Configuration(sdkKey: "public-key", appIdentifier: "com.example.host", apiBaseURL: URL(string: "https://sdk.example.test")!)
        let state = try await sdk.initialize(configuration)
        XCTAssertEqual(state, .logoutPending)
        await XCTAssertThrowsErrorAsync {
            try await ownerStore.outboxEntries(for: scope)
        }
    }

    func testRequestFactoryRejectsNonContractAttachmentAndCursorBounds() throws {
        let factory = try OnloRequestFactory(baseURL: URL(string: "https://sdk.example.test")!)

        XCTAssertThrowsError(try OnloRequestFactory(baseURL: URL(string: "http://sdk.example.test")!))

        XCTAssertThrowsError(
            try factory.attachmentIntent(
                AttachmentIntentRequest(
                    conversationId: "conversation-1",
                    mimeType: .jpeg,
                    byteSize: OnloProtocol.maximumImageBytes + 1,
                    sha256: String(repeating: "a", count: 64),
                    filename: "image.jpg"
                ),
                chatToken: "opaque-access-token"
            )
        )
        XCTAssertThrowsError(
            try factory.transcript(
                conversationId: "conversation-1",
                query: .after("cursor", limit: 101),
                chatToken: "opaque-access-token"
            )
        )
    }

    func testChatAndStreamRequestSSE() throws {
        let factory = try OnloRequestFactory(baseURL: URL(string: "https://sdk.example.test")!)
        let chat = try factory.chat(
            ChatRequest(sessionId: "session-1", clientMessageId: UUID().uuidString, message: "synthetic message"),
            chatToken: "opaque-access-token"
        )
        let stream = try factory.stream(chatToken: "opaque-access-token")
        XCTAssertEqual(chat.value(forHTTPHeaderField: "Accept"), "text/event-stream")
        XCTAssertEqual(stream.value(forHTTPHeaderField: "Accept"), "text/event-stream")
    }

    func testChatEventRejectsUnknownAndMalformedPayloads() throws {
        XCTAssertThrowsError(try JSONDecoder().decode(ChatEvent.self, from: Data("{\"type\":\"unknown\"}".utf8)))
        XCTAssertThrowsError(try JSONDecoder().decode(ChatEvent.self, from: Data("{\"type\":\"accepted\"}".utf8)))
    }

    func testForegroundStreamRejectsUnknownAndMalformedFrames() throws {
        XCTAssertThrowsError(try JSONDecoder().decode(StreamEvent.self, from: Data("{\"type\":\"unknown\"}".utf8)))
        XCTAssertThrowsError(try JSONDecoder().decode(StreamEvent.self, from: Data("{\"type\":\"inbox.message\"}".utf8)))
    }

    func testOwnerScopesAreIsolatedAndPurged() async throws {
        let store = InMemoryOwnerScopedStore()
        let ownerA = OwnerScope(kind: .identified)
        let ownerB = OwnerScope(kind: .identified)
        try await store.prepare(scope: ownerA)
        try await store.prepare(scope: ownerB)
        let entryA = OutboxEntry(ownerScope: ownerA, message: "synthetic A", orderingKey: 1)
        let entryB = OutboxEntry(ownerScope: ownerB, message: "synthetic B", orderingKey: 1)
        try await store.enqueue(entryA)
        try await store.enqueue(entryB)
        let ownerAEntries = try await store.outboxEntries(for: ownerA)
        XCTAssertEqual(ownerAEntries, [entryA])
        let ownerBEntries = try await store.outboxEntries(for: ownerB)
        XCTAssertEqual(ownerBEntries, [entryB])
        try await store.beginLogout(for: ownerA)
        await XCTAssertThrowsErrorAsync {
            try await store.outboxEntries(for: ownerA)
        }
        let retainedOwnerBEntries = try await store.outboxEntries(for: ownerB)
        XCTAssertEqual(retainedOwnerBEntries, [entryB])
        try await store.finishLogout(for: ownerA)
        let replacementOwner = OwnerScope(kind: .identified)
        try await store.prepare(scope: replacementOwner)
        let replacementEntries = try await store.outboxEntries(for: replacementOwner)
        XCTAssertEqual(replacementEntries, [])
    }

    func testSSEMockDeliversEventsIncrementallyAndSupportsCancellation() async throws {
        let transport = StreamingMockTransport(events: [.text(content: "one"), .text(content: "two")])
        let stream = transport.chatEvents(for: URLRequest(url: URL(string: "https://sdk.example.test/api/widget/chat")!))
        var received: [ChatEvent] = []
        for try await event in stream {
            received.append(event)
            break
        }
        XCTAssertEqual(received, [.text(content: "one")])
    }

    func testImmediateFirstSSEEventIsDelivered() async throws {
        let transport = ImmediateAcceptedTransport()
        let credentials = InMemoryCredentialStore()
        let store = InMemoryOwnerScopedStore()
        let sdk = OnloSDK(credentialStore: credentials, configStore: InMemoryConfigStore(), pushIntentStore: InMemoryPushIntentStore(), ownerStore: store, transport: transport, hostAppIdentifier: "com.example.host", lifecycleBindingEnabled: false)
        _ = try await sdk.initialize(OnloSDK.Configuration(sdkKey: "public-key", appIdentifier: "com.example.host", apiBaseURL: URL(string: "https://sdk.example.test")!))
        let stream = try await sdk.sendMessage(message: "synthetic message")
        guard await waitUntil(condition: { transport.chatEventRequestCount() == 1 }) else {
            XCTFail("timed out waiting for the chat SSE request")
            return
        }
        var iterator = stream.makeAsyncIterator()
        let first = try await iterator.next()
        XCTAssertNotNil(first, "chat SSE requests: \(transport.chatEventRequestCount())")
        let stored = try await credentials.loadState().credential
        let scope = try XCTUnwrap(stored?.ownerScope)
        let outboxEntries = try await store.outboxEntries(for: scope)
        XCTAssertEqual(outboxEntries.first?.state, .accepted)
    }

    func testSendMessageUsesDurableDispatcherBeforeOpeningChatRequest() async throws {
        let transport = RecordingAcceptedTransport()
        let credentials = InMemoryCredentialStore()
        let store = InMemoryOwnerScopedStore()
        let sdk = OnloSDK(credentialStore: credentials, configStore: InMemoryConfigStore(), pushIntentStore: InMemoryPushIntentStore(), ownerStore: store, transport: transport, hostAppIdentifier: "com.example.host", lifecycleBindingEnabled: false)
        _ = try await sdk.initialize(OnloSDK.Configuration(sdkKey: "public-key", appIdentifier: "com.example.host", apiBaseURL: URL(string: "https://sdk.example.test")!))

        let stream = try await sdk.sendMessage(message: "synthetic dispatcher message")
        guard await waitUntil(condition: { await transport.hasChatRequest() }) else {
            XCTFail("timed out waiting for the durable chat request")
            return
        }
        var iterator = stream.makeAsyncIterator()
        _ = try await iterator.next()
        let recordedRequest = await transport.chatRequest()
        let request = try XCTUnwrap(recordedRequest)
        let requestBody = try XCTUnwrap(request.httpBody)
        let chat = try JSONDecoder().decode(ChatRequest.self, from: requestBody)
        let scope = try await activeOwnerScope(credentials)
        let row = try await firstOutboxEntry(store, for: scope)
        XCTAssertEqual(chat.clientMessageId, row.clientMessageId.uuidString)
        XCTAssertEqual(chat.message, row.message)
        XCTAssertEqual(row.state, .accepted)
    }

    func testRestoredSQLiteRowIsDispatchedWithoutUIObserver() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("outbox.sqlite")
        let keyStore = InMemoryOutboxKeyStore()
        let scope = OwnerScope(kind: .anonymous)
        let entry = OutboxEntry(ownerScope: scope, message: "synthetic restored", orderingKey: 1)
        let firstStore = SQLiteOwnerScopedStore(databaseURL: databaseURL, keyStore: keyStore)
        try await firstStore.prepare(scope: scope)
        try await firstStore.enqueue(entry)

        let transport = RecordingAcceptedTransport()
        let credentials = InMemoryCredentialStore(StoredSessionCredential(installationId: "installation-1", generation: 1, proposedCredential: "credential-1", identityClass: .anonymous, ownerScope: scope))
        let restoredStore = SQLiteOwnerScopedStore(databaseURL: databaseURL, keyStore: keyStore)
        let sdk = OnloSDK(credentialStore: credentials, ownerStore: restoredStore, transport: transport, hostAppIdentifier: "com.example.host")
        _ = try await sdk.initialize(OnloSDK.Configuration(sdkKey: "public-key", appIdentifier: "com.example.host", apiBaseURL: URL(string: "https://sdk.example.test")!))
        await transport.waitForChatRequest()

        let recordedRequest = await transport.chatRequest()
        let request = try XCTUnwrap(recordedRequest)
        let chat = try JSONDecoder().decode(ChatRequest.self, from: try XCTUnwrap(request.httpBody))
        XCTAssertEqual(chat.clientMessageId, entry.clientMessageId.uuidString)
        XCTAssertEqual(chat.message, entry.message)
        try await restoredStore.finishLogout(for: scope)
    }

    func testDuplicateAcceptanceReconcilesTranscriptThroughDispatcher() async throws {
        let transport = DuplicateAcceptedTransport()
        let credentials = InMemoryCredentialStore()
        let store = InMemoryOwnerScopedStore()
        let sdk = OnloSDK(credentialStore: credentials, configStore: InMemoryConfigStore(), pushIntentStore: InMemoryPushIntentStore(), ownerStore: store, transport: transport, hostAppIdentifier: "com.example.host")
        _ = try await sdk.initialize(OnloSDK.Configuration(sdkKey: "public-key", appIdentifier: "com.example.host", apiBaseURL: URL(string: "https://sdk.example.test")!))

        let stream = try await sdk.sendMessage(message: "synthetic duplicate")
        var iterator = stream.makeAsyncIterator()
        _ = try await iterator.next()
        let terminalEvent = try await iterator.next()
        XCTAssertNil(terminalEvent)
        let scope = try await activeOwnerScope(credentials)
        let entries = try await store.outboxEntries(for: scope)
        XCTAssertEqual(entries.first?.state, .accepted)
        let paths = transport.requestPaths()
        XCTAssertTrue(paths.contains("/api/widget/conversations/conversation-1"))
    }

    func testActiveDispatcherPersistsRetryEligibilityAfterUnacknowledgedChatEnds() async throws {
        let clock = TestClock(Date(timeIntervalSince1970: 1_000))
        let credentials = InMemoryCredentialStore()
        let store = InMemoryOwnerScopedStore()
        let sdk = OnloSDK(credentialStore: credentials, ownerStore: store, transport: FinishingChatTransport(), hostAppIdentifier: "com.example.host", now: clock.now, backoffJitter: { _ in 0 })
        _ = try await sdk.initialize(OnloSDK.Configuration(sdkKey: "public-key", appIdentifier: "com.example.host", apiBaseURL: URL(string: "https://sdk.example.test")!))

        let stream = try await sdk.sendMessage(message: "synthetic retry")
        var iterator = stream.makeAsyncIterator()
        await XCTAssertThrowsErrorAsync { _ = try await iterator.next() }
        let scope = try await activeOwnerScope(credentials)
        let row = try await firstOutboxEntry(store, for: scope)
        XCTAssertEqual(row.state, .failedRetryable)
        XCTAssertEqual(row.attemptCount, 1)
        XCTAssertEqual(row.nextAttemptAt, clock.now().addingTimeInterval(1))
    }

    func testWrongAcceptedMessageIDLeavesRowTerminalInsteadOfSending() async throws {
        let credentials = InMemoryCredentialStore()
        let store = InMemoryOwnerScopedStore()
        let sdk = OnloSDK(credentialStore: credentials, ownerStore: store, transport: ChatFailureTransport(mode: .wrongAcceptedID), hostAppIdentifier: "com.example.host")
        _ = try await sdk.initialize(OnloSDK.Configuration(sdkKey: "public-key", appIdentifier: "com.example.host", apiBaseURL: URL(string: "https://sdk.example.test")!))

        let stream = try await sdk.sendMessage(message: "synthetic wrong id")
        var iterator = stream.makeAsyncIterator()
        await XCTAssertThrowsErrorAsync { _ = try await iterator.next() }
        let scope = try await activeOwnerScope(credentials)
        let entries = try await store.outboxEntries(for: scope)
        XCTAssertEqual(entries.first?.state, .failedTerminal)
    }

    func testWidgetErrorDoesNotAutoRetryDurableRow() async throws {
        let credentials = InMemoryCredentialStore()
        let store = InMemoryOwnerScopedStore()
        let sdk = OnloSDK(credentialStore: credentials, ownerStore: store, transport: ChatFailureTransport(mode: .widgetError), hostAppIdentifier: "com.example.host")
        _ = try await sdk.initialize(OnloSDK.Configuration(sdkKey: "public-key", appIdentifier: "com.example.host", apiBaseURL: URL(string: "https://sdk.example.test")!))

        let stream = try await sdk.sendMessage(message: "synthetic widget error")
        var iterator = stream.makeAsyncIterator()
        await XCTAssertThrowsErrorAsync { _ = try await iterator.next() }
        let scope = try await activeOwnerScope(credentials)
        let row = try await firstOutboxEntry(store, for: scope)
        XCTAssertEqual(row.state, .failedTerminal)
        XCTAssertNil(row.nextAttemptAt)
    }

    func testDuplicateTranscriptFailureDoesNotReclassifyAcceptedRow() async throws {
        let transport = DuplicateTranscriptFailureTransport()
        let credentials = InMemoryCredentialStore()
        let store = InMemoryOwnerScopedStore()
        let sdk = OnloSDK(credentialStore: credentials, configStore: InMemoryConfigStore(), pushIntentStore: InMemoryPushIntentStore(), ownerStore: store, transport: transport, hostAppIdentifier: "com.example.host")
        _ = try await sdk.initialize(OnloSDK.Configuration(sdkKey: "public-key", appIdentifier: "com.example.host", apiBaseURL: URL(string: "https://sdk.example.test")!))

        let stream = try await sdk.sendMessage(message: "synthetic duplicate transcript failure")
        var iterator = stream.makeAsyncIterator()
        _ = try await iterator.next()
        let scope = try await activeOwnerScope(credentials)
        let row = try await firstOutboxEntry(store, for: scope)
        XCTAssertEqual(row.state, .accepted)
        let chatRequestCount = await transport.chatRequestCount()
        XCTAssertEqual(chatRequestCount, 1)
    }

    func testGenericStreamFailureAfterAcceptanceDoesNotDowngradeDurableRow() async throws {
        let credentials = InMemoryCredentialStore()
        let store = InMemoryOwnerScopedStore()
        let sdk = OnloSDK(credentialStore: credentials, ownerStore: store, transport: AcceptedThenGenericFailureTransport(), hostAppIdentifier: "com.example.host")
        _ = try await sdk.initialize(OnloSDK.Configuration(sdkKey: "public-key", appIdentifier: "com.example.host", apiBaseURL: URL(string: "https://sdk.example.test")!))

        let stream = try await sdk.sendMessage(message: "synthetic accepted then generic failure")
        var iterator = stream.makeAsyncIterator()
        _ = try await iterator.next()
        await XCTAssertThrowsErrorAsync { _ = try await iterator.next() }
        let scope = try await activeOwnerScope(credentials)
        let row = try await firstOutboxEntry(store, for: scope)
        XCTAssertEqual(row.state, .accepted)
        XCTAssertNil(row.nextAttemptAt)
    }

    func testFailedIdentifyRestartsForegroundStreamForAnonymousSession() async throws {
        let controller = ForegroundStreamController()
        let transport = ForegroundLifecycleTransport(controller: controller, identifyFails: true)
        let sdk = OnloSDK(credentialStore: InMemoryCredentialStore(), configStore: InMemoryConfigStore(), pushIntentStore: InMemoryPushIntentStore(), ownerStore: InMemoryOwnerScopedStore(), transport: transport, hostAppIdentifier: "com.example.host", lifecycleBindingEnabled: false)
        _ = try await sdk.initialize(OnloSDK.Configuration(sdkKey: "public-key", appIdentifier: "com.example.host", apiBaseURL: URL(string: "https://sdk.example.test")!))
        await controller.waitForSubscriptions(1)
        await XCTAssertThrowsErrorAsync { try await sdk.loginIdentifiedUser(userJwt: "header.payload.signature") }
        await controller.waitForSubscriptions(2)
        let failedIdentifyState = await sdk.currentState()
        XCTAssertEqual(failedIdentifyState, .anonymousReady)
    }

    func testSameOwnerConfigTokenRefreshReplacesForegroundStream() async throws {
        let controller = ForegroundStreamController()
        let transport = ForegroundLifecycleTransport(controller: controller, configRefreshesToken: true)
        let sdk = OnloSDK(credentialStore: InMemoryCredentialStore(), configStore: InMemoryConfigStore(), pushIntentStore: InMemoryPushIntentStore(), ownerStore: InMemoryOwnerScopedStore(), transport: transport, hostAppIdentifier: "com.example.host", lifecycleBindingEnabled: false)
        _ = try await sdk.initialize(OnloSDK.Configuration(sdkKey: "public-key", appIdentifier: "com.example.host", apiBaseURL: URL(string: "https://sdk.example.test")!))
        await controller.waitForSubscriptions(1)
        try await sdk.refreshConfigurationForForeground()
        await controller.waitForSubscriptions(2)
        let refreshedState = await sdk.currentState()
        XCTAssertEqual(refreshedState, .anonymousReady)
        let streamAuthorizations = await transport.streamAuthorizations()
        XCTAssertEqual(streamAuthorizations.count, 2)
        XCTAssertNotEqual(streamAuthorizations[0], streamAuthorizations[1])
    }

    func testDelayedOldOwnerForegroundTranscriptCannotCommitAfterLogout() async throws {
        let controller = DelayedTranscriptController()
        let transport = DelayedTranscriptForegroundTransport(controller: controller)
        let credentials = InMemoryCredentialStore()
        let store = InMemoryOwnerScopedStore()
        let sdk = OnloSDK(credentialStore: credentials, configStore: InMemoryConfigStore(), pushIntentStore: InMemoryPushIntentStore(), ownerStore: store, transport: transport, hostAppIdentifier: "com.example.host")
        _ = try await sdk.initialize(OnloSDK.Configuration(sdkKey: "public-key", appIdentifier: "com.example.host", apiBaseURL: URL(string: "https://sdk.example.test")!))
        let oldScope = try await activeOwnerScope(credentials)
        await controller.waitForTranscriptRequest()

        _ = try await sdk.logout()
        await controller.releaseTranscript()
        await XCTAssertThrowsErrorAsync { try await store.outboxEntries(for: oldScope) }
        let intent = try await sdk.present()
        XCTAssertEqual(intent, .messenger(conversationId: nil))
    }

    func testAccountBoundaryCancellationTerminatesStreamWithoutLaterEvent() async throws {
        let controller = ControlledSSEController()
        let transport = ControlledChatTransport(controller: controller)
        let credentials = InMemoryCredentialStore()
        let store = InMemoryOwnerScopedStore()
        let sdk = OnloSDK(credentialStore: credentials, configStore: InMemoryConfigStore(), pushIntentStore: InMemoryPushIntentStore(), ownerStore: store, transport: transport, hostAppIdentifier: "com.example.host")
        _ = try await sdk.initialize(OnloSDK.Configuration(sdkKey: "public-key", appIdentifier: "com.example.host", apiBaseURL: URL(string: "https://sdk.example.test")!))
        let oldCredential = try await credentials.loadState().credential
        let oldScope = try XCTUnwrap(oldCredential).ownerScope
        let stream = try await sdk.sendMessage(message: "synthetic message")
        await controller.waitUntilSubscribed()
        _ = try await sdk.logout()
        await controller.yield(.text(content: "late synthetic text"))
        var iterator = stream.makeAsyncIterator()
        let eventAfterLogout = try await iterator.next()
        XCTAssertNil(eventAfterLogout)
        await XCTAssertThrowsErrorAsync {
            try await store.outboxEntries(for: oldScope)
        }
    }

    func testLifecycleRotatesCredentialAndUnlinksBeforeAccountChange() async throws {
        let transport = MockTransport(responses: [
            sessionResponse(identityClass: "anonymous", generation: 1, sessionId: "anonymous-session", credential: "credential-1"),
            sessionResponse(identityClass: "identified", generation: 2, sessionId: "identified-session", credential: "credential-2"),
            sessionResponse(identityClass: "anonymous", generation: 3, sessionId: "anonymous-session-2", credential: "credential-3"),
        ])
        let credentials = InMemoryCredentialStore()
        let ownerStore = InMemoryOwnerScopedStore()
        let sdk = OnloSDK(
            credentialStore: credentials,
            configStore: InMemoryConfigStore(),
            pushIntentStore: InMemoryPushIntentStore(),
            ownerStore: ownerStore,
            transport: transport,
            hostAppIdentifier: "com.example.host"
        )
        let configuration = OnloSDK.Configuration(
            sdkKey: "public-key",
            appIdentifier: "com.example.host",
            apiBaseURL: URL(string: "https://sdk.example.test")!
        )

        let initializedState = try await sdk.initialize(configuration)
        XCTAssertEqual(initializedState, .anonymousReady)
        let identifiedState = try await sdk.loginIdentifiedUser(userJwt: "header.payload.signature")
        XCTAssertEqual(identifiedState, .identifiedReady)
        let loggedOutState = try await sdk.logout()
        XCTAssertEqual(loggedOutState, .anonymousReady)

        let stored = try await credentials.loadState().credential
        XCTAssertEqual(stored?.generation, 3)
        XCTAssertEqual(stored?.identityClass, .anonymous)
        XCTAssertFalse(stored?.logoutPending ?? true)
        let persistedBytes = try XCTUnwrap(stored).thenEncode()
        XCTAssertFalse(persistedBytes.contains("opaque-access-token"))

        let requests = await transport.requests()
        let operations = try requests.filter { $0.url?.path == "/api/sdk/v1/session" }.map { request -> SessionOperation in
            let body = try XCTUnwrap(request.httpBody)
            return try JSONDecoder().decode(SessionRequest.self, from: body).operation
        }
        XCTAssertEqual(operations.count, 3)
        guard case .bootstrap = operations[0] else { return XCTFail("expected bootstrap") }
        guard case .identify = operations[1] else { return XCTFail("expected identify") }
        guard case .logout = operations[2] else { return XCTFail("expected logout") }
    }

    func testDurableDispatcherAssignsFIFOOrderForSameTimeEnqueues() async throws {
        let now = Date(timeIntervalSince1970: 1_000)
        let (sdk, credentials, store) = try await readyDurableDispatcher(now: { now })
        let scope = try await activeOwnerScope(credentials)
        let firstID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let secondID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!

        let first = try await store.enqueueAssigningOrder(OutboxEntry(clientMessageId: firstID, ownerScope: scope, message: "synthetic first", createdAt: now, orderingKey: 0))
        let second = try await store.enqueueAssigningOrder(OutboxEntry(clientMessageId: secondID, ownerScope: scope, message: "synthetic second", createdAt: now, orderingKey: 0))

        XCTAssertEqual(first.orderingKey, 1)
        XCTAssertEqual(second.orderingKey, 2)
        let dispatch = try await sdk.nextDurableTextDispatch()
        XCTAssertEqual(dispatch?.clientMessageId, firstID)
    }

    func testDurableDispatcherDoesNotOvertakeHeadAwaitingRetry() async throws {
        let now = Date(timeIntervalSince1970: 1_000)
        let (sdk, credentials, store) = try await readyDurableDispatcher(now: { now })
        let scope = try await activeOwnerScope(credentials)
        let blocked = try await store.enqueueAssigningOrder(OutboxEntry(ownerScope: scope, message: "synthetic blocked", orderingKey: 0, state: .failedRetryable, nextAttemptAt: now.addingTimeInterval(1)))
        let later = try await store.enqueueAssigningOrder(OutboxEntry(ownerScope: scope, message: "synthetic later", orderingKey: 0))

        let pendingDispatch = try await sdk.nextDurableTextDispatch()
        XCTAssertNil(pendingDispatch)
        let entries = try await store.outboxEntries(for: scope)
        XCTAssertEqual(entries, [blocked, later])
    }

    func testDurableDispatcherBackoffRetainsStableIDAndBody() async throws {
        let clock = TestClock(Date(timeIntervalSince1970: 1_000))
        let (sdk, credentials, store) = try await readyDurableDispatcher(now: { clock.now() }, jitter: { _ in 0 })
        let scope = try await activeOwnerScope(credentials)
        let messageID = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
        let queued = try await store.enqueueAssigningOrder(OutboxEntry(clientMessageId: messageID, ownerScope: scope, message: "synthetic durable body", orderingKey: 0))
        let firstAttemptCandidate = try await sdk.nextDurableTextDispatch()
        let firstAttempt = try XCTUnwrap(firstAttemptCandidate)

        try await sdk.recordDurableDispatchFailure(firstAttempt, retryable: true, safeCode: "network_unavailable")
        let retryingEntries = try await store.outboxEntries(for: scope)
        let retrying = try XCTUnwrap(retryingEntries.first)
        XCTAssertEqual(retrying.clientMessageId, messageID)
        XCTAssertEqual(retrying.message, queued.message)
        XCTAssertEqual(retrying.attemptCount, 1)
        XCTAssertEqual(retrying.nextAttemptAt, clock.now().addingTimeInterval(1))
        let retryPendingDispatch = try await sdk.nextDurableTextDispatch()
        XCTAssertNil(retryPendingDispatch)

        clock.advance(by: 1_001)
        let secondAttemptCandidate = try await sdk.nextDurableTextDispatch()
        let secondAttempt = try XCTUnwrap(secondAttemptCandidate)
        XCTAssertEqual(secondAttempt.clientMessageId, messageID)
        XCTAssertEqual(secondAttempt.message, queued.message)
        XCTAssertEqual(secondAttempt.attemptCount, 2)
    }

    func testDurableDispatcherRecoversInterruptedSendingAfterSQLiteReconstruction() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("outbox.sqlite")
        let keyStore = InMemoryOutboxKeyStore()
        let scope = OwnerScope(kind: .anonymous)
        let messageID = UUID(uuidString: "00000000-0000-0000-0000-000000000004")!
        let firstStore = SQLiteOwnerScopedStore(databaseURL: databaseURL, keyStore: keyStore)
        try await firstStore.prepare(scope: scope)
        try await firstStore.enqueue(OutboxEntry(clientMessageId: messageID, ownerScope: scope, message: "synthetic interrupted", orderingKey: 1, state: .sending, attemptCount: 1))

        let credentials = InMemoryCredentialStore(StoredSessionCredential(installationId: "installation-1", generation: 1, proposedCredential: "credential-1", identityClass: .anonymous, ownerScope: scope))
        let reconstructedStore = SQLiteOwnerScopedStore(databaseURL: databaseURL, keyStore: keyStore)
        let sdk = OnloSDK(credentialStore: credentials, ownerStore: reconstructedStore, transport: MockTransport(responses: [sessionResponse(identityClass: "anonymous", generation: 2, sessionId: "session-2", credential: "credential-2")]), hostAppIdentifier: "com.example.host", now: { Date(timeIntervalSince1970: 1_000) })
        _ = try await sdk.initialize(OnloSDK.Configuration(sdkKey: "public-key", appIdentifier: "com.example.host", apiBaseURL: URL(string: "https://sdk.example.test")!))

        let dispatchCandidate = try await sdk.nextDurableTextDispatch()
        let dispatch = try XCTUnwrap(dispatchCandidate)
        XCTAssertEqual(dispatch.clientMessageId, messageID)
        XCTAssertEqual(dispatch.message, "synthetic interrupted")
        XCTAssertEqual(dispatch.state, .sending)
        XCTAssertEqual(dispatch.attemptCount, 2)
        try await reconstructedStore.finishLogout(for: scope)
    }

    func testDurableDispatcherKeepsTerminalHeadBlockingLaterRow() async throws {
        let now = Date(timeIntervalSince1970: 1_000)
        let (sdk, credentials, store) = try await readyDurableDispatcher(now: { now })
        let scope = try await activeOwnerScope(credentials)
        let terminal = try await store.enqueueAssigningOrder(OutboxEntry(ownerScope: scope, message: "synthetic terminal", orderingKey: 0, state: .failedTerminal))
        let later = try await store.enqueueAssigningOrder(OutboxEntry(ownerScope: scope, message: "synthetic allowed", orderingKey: 0))

        let pendingDispatch = try await sdk.nextDurableTextDispatch()
        XCTAssertNil(pendingDispatch)
        let entries = try await store.outboxEntries(for: scope)
        XCTAssertEqual(entries, [
            terminal,
            later,
        ])
    }

    func testDurableDispatcherRejectsAttachmentBearingHeadUntilUploadLifecycleExists() async throws {
        let now = Date(timeIntervalSince1970: 1_000)
        let (sdk, credentials, store) = try await readyDurableDispatcher(now: { now })
        let scope = try await activeOwnerScope(credentials)
        let attachment = OutboxAttachment(attachment: ChatAttachment(id: "attachment-1", url: "https://synthetic.invalid/image.jpg", type: "image/jpeg", name: "image.jpg", size: 1))
        let queued = try await store.enqueueAssigningOrder(OutboxEntry(ownerScope: scope, message: "", attachments: [attachment], orderingKey: 0))

        await XCTAssertThrowsErrorAsync { try await sdk.nextDurableTextDispatch() }
        let entries = try await store.outboxEntries(for: scope)
        XCTAssertEqual(entries, [queued])
    }

    func testDurableDispatcherRejectsOldOwnerAfterAccountSwitch() async throws {
        let transport = MockTransport(responses: [
            sessionResponse(identityClass: "anonymous", generation: 1, sessionId: "anonymous-session", credential: "credential-1"),
            sessionResponse(identityClass: "identified", generation: 2, sessionId: "session-2", credential: "credential-2"),
        ])
        let credentials = InMemoryCredentialStore()
        let store = InMemoryOwnerScopedStore()
        let sdk = OnloSDK(credentialStore: credentials, ownerStore: store, transport: transport, hostAppIdentifier: "com.example.host")
        _ = try await sdk.initialize(OnloSDK.Configuration(sdkKey: "public-key", appIdentifier: "com.example.host", apiBaseURL: URL(string: "https://sdk.example.test")!))
        let oldScope = try await activeOwnerScope(credentials)
        let oldEntry = try await store.enqueueAssigningOrder(OutboxEntry(ownerScope: oldScope, message: "synthetic old owner", orderingKey: 0))

        _ = try await sdk.loginIdentifiedUser(userJwt: "header.payload.signature")
        await XCTAssertThrowsErrorAsync {
            try await sdk.recordDurableDispatchFailure(oldEntry, retryable: true, safeCode: "network_unavailable")
        }
    }

    func testPresentAuthorizesConversationWithTranscript() async throws {
        let transport = MockTransport(responses: [
            sessionResponse(identityClass: "anonymous", generation: 1, sessionId: "anonymous-session", credential: "credential-1"),
            transcriptResponse(conversationId: "conversation-1"),
        ])
        let sdk = OnloSDK(
            credentialStore: InMemoryCredentialStore(),
            ownerStore: InMemoryOwnerScopedStore(),
            transport: transport,
            hostAppIdentifier: "com.example.host"
        )
        _ = try await sdk.initialize(
            OnloSDK.Configuration(
                sdkKey: "public-key",
                appIdentifier: "com.example.host",
                apiBaseURL: URL(string: "https://sdk.example.test")!
            )
        )

        let intent = try await sdk.present(conversationId: "conversation-1")
        XCTAssertEqual(intent, .messenger(conversationId: "conversation-1"))
        let requests = await transport.requests()
        XCTAssertEqual(requests.last?.url?.path, "/api/widget/conversations/conversation-1")
        XCTAssertEqual(requests.last?.url?.query, "limit=1")
        XCTAssertEqual(requests.last?.value(forHTTPHeaderField: "Authorization"), "Bearer opaque-access-token")
    }

    func testAPNsRegistrationPersistsThenUsesExactV1EnvelopeRoute() async throws {
        let pushStore = InMemoryPushIntentStore()
        let transport = MockTransport(responses: [
            sessionResponse(identityClass: "anonymous", generation: 1, sessionId: "session-1", credential: "credential-1"),
            mobileConfigResponse(),
            pushResponse(),
        ])
        let sdk = OnloSDK(
            credentialStore: InMemoryCredentialStore(),
            configStore: InMemoryConfigStore(),
            pushIntentStore: pushStore,
            ownerStore: InMemoryOwnerScopedStore(),
            transport: transport,
            hostAppIdentifier: "com.example.host"
        )
        _ = try await sdk.initialize(OnloSDK.Configuration(sdkKey: "public-key", appIdentifier: "com.example.host", apiBaseURL: URL(string: "https://sdk.example.test")!))
        let state = try await sdk.setAPNsPushToken(Data(repeating: 0xAB, count: 32))
        XCTAssertEqual(state, .registered)
        let storedPushIntent = try await pushStore.load()
        let protected = try XCTUnwrap(storedPushIntent)
        XCTAssertEqual(protected.action, .register)
        XCTAssertFalse(protected.automaticallyRetryable)
        let requests = await transport.requests()
        let request = requests.last
        XCTAssertEqual(request?.url?.path, "/api/sdk/v1/push-token")
        XCTAssertEqual(request?.httpMethod, "POST")
        XCTAssertEqual(request?.value(forHTTPHeaderField: "Authorization"), "Bearer opaque-access-token")
        let body = try XCTUnwrap(request?.httpBody)
        let decoded = try JSONDecoder().decode(PushTokenRequest.self, from: body)
        guard case let .register(provider, token, _, _) = decoded else { return XCTFail("missing APNs registration") }
        XCTAssertEqual(provider, .apns)
        XCTAssertEqual(token.count, 64)
    }

    func testPushPayloadMustAuthoriseConversationAndMessageBeforeIntent() async throws {
        let transcript = """
        {"conversation":{"id":"conversation-1","sessionId":"anonymous-session","status":"open","isHumanTakeover":false},"messages":[{"id":"message-1","externalId":null,"role":"assistant","senderType":null,"senderName":null,"senderTeam":null,"text":"synthetic","attachments":[],"timestamp":1}],"sync":{"previousCursor":null,"nextCursor":null,"limit":100}}
        """
        let transport = MockTransport(responses: [
            sessionResponse(identityClass: "anonymous", generation: 1, sessionId: "anonymous-session", credential: "credential-1"),
            mobileConfigResponse(),
            OnloHTTPResponse(statusCode: 200, body: Data(transcript.utf8)),
        ])
        let sdk = OnloSDK(credentialStore: InMemoryCredentialStore(), configStore: InMemoryConfigStore(), pushIntentStore: InMemoryPushIntentStore(), ownerStore: InMemoryOwnerScopedStore(), transport: transport, hostAppIdentifier: "com.example.host")
        _ = try await sdk.initialize(OnloSDK.Configuration(sdkKey: "public-key", appIdentifier: "com.example.host", apiBaseURL: URL(string: "https://sdk.example.test")!))
        let result = try await sdk.handlePushNotification(PushNotificationPayload(conversationId: "conversation-1", messageId: "message-1", notificationType: .messageAvailable))
        XCTAssertEqual(result, .handled(.messenger(conversationId: "conversation-1")))
    }

    func testLogoutUnregistersProtectedAPNsIntentBeforeSessionLogout() async throws {
        let pushStore = InMemoryPushIntentStore()
        let transport = MockTransport(responses: [
            sessionResponse(identityClass: "anonymous", generation: 1, sessionId: "session-1", credential: "credential-1"),
            mobileConfigResponse(),
            pushResponse(),
            pushInactiveResponse(),
            sessionResponse(identityClass: "anonymous", generation: 2, sessionId: "session-2", credential: "credential-2"),
        ])
        let sdk = OnloSDK(credentialStore: InMemoryCredentialStore(), configStore: InMemoryConfigStore(), pushIntentStore: pushStore, ownerStore: InMemoryOwnerScopedStore(), transport: transport, hostAppIdentifier: "com.example.host")
        _ = try await sdk.initialize(OnloSDK.Configuration(sdkKey: "public-key", appIdentifier: "com.example.host", apiBaseURL: URL(string: "https://sdk.example.test")!))
        _ = try await sdk.setAPNsPushToken(Data(repeating: 0xAB, count: 32))
        let logoutState = try await sdk.logout()
        XCTAssertEqual(logoutState, .anonymousReady)
        let remainingPushIntent = try await pushStore.load()
        XCTAssertNil(remainingPushIntent)
        let requests = await transport.requests()
        let pushRequests = requests.filter { $0.url?.path == "/api/sdk/v1/push-token" }
        let unregister = try XCTUnwrap(pushRequests.last?.httpBody)
        XCTAssertEqual(try JSONDecoder().decode(PushTokenRequest.self, from: unregister), .unregister)
    }

    func testProtectedOwnerAIntentCannotBeOverwrittenByOwnerB() async throws {
        let pushStore = InMemoryPushIntentStore()
        try await pushStore.save(ProtectedPushIntent(ownerScope: OwnerScope(kind: .identified), action: .unregister, eligibleAt: Date.distantFuture, retryDirective: .afterBackoff))
        let transport = MockTransport(responses: [
            sessionResponse(identityClass: "anonymous", generation: 1, sessionId: "session-1", credential: "credential-1"),
            mobileConfigResponse(),
        ])
        let sdk = OnloSDK(credentialStore: InMemoryCredentialStore(), pushIntentStore: pushStore, ownerStore: InMemoryOwnerScopedStore(), transport: transport, hostAppIdentifier: "com.example.host")
        _ = try await sdk.initialize(OnloSDK.Configuration(sdkKey: "public-key", appIdentifier: "com.example.host", apiBaseURL: URL(string: "https://sdk.example.test")!))
        await XCTAssertThrowsErrorAsync { _ = try await sdk.setAPNsPushToken(Data(repeating: 0xCD, count: 32)) }
        let storedPushIntent = try await pushStore.load()
        let retained = try XCTUnwrap(storedPushIntent)
        XCTAssertEqual(retained.action, .unregister)
        let requests = await transport.requests()
        XCTAssertEqual(requests.filter { $0.url?.path == "/api/sdk/v1/push-token" }.count, 0)
    }

    func testPushBackoffKeepsLogoutBoundaryAndForegroundDoesNotRetryEarly() async throws {
        let credentials = InMemoryCredentialStore()
        let owners = InMemoryOwnerScopedStore()
        let push = InMemoryPushIntentStore()
        let transport = MockTransport(responses: [
            sessionResponse(identityClass: "anonymous", generation: 1, sessionId: "session-1", credential: "credential-1"), mobileConfigResponse(), pushResponse(),
            sessionFailure(code: "dependency_unavailable", directive: "after_backoff", retryAfterMs: 120_000)
        ])
        let sdk = OnloSDK(credentialStore: credentials, configStore: InMemoryConfigStore(), pushIntentStore: push, ownerStore: owners, transport: transport, hostAppIdentifier: "com.example.host")
        _ = try await sdk.initialize(OnloSDK.Configuration(sdkKey: "public-key", appIdentifier: "com.example.host", apiBaseURL: URL(string: "https://sdk.example.test")!))
        let owner = try await activeOwnerScope(credentials)
        _ = try await sdk.setAPNsPushToken(Data(repeating: 0xAA, count: 32))
        let logoutState = try await sdk.logout()
        XCTAssertEqual(logoutState, .logoutPending)
        let requestsBeforeForeground = await transport.requests()
        let before = requestsBeforeForeground.count
        try await sdk.refreshConfigurationForForeground()
        let requestsAfterForeground = await transport.requests()
        let requestCount = requestsAfterForeground.count
        XCTAssertEqual(requestCount, before)
        await XCTAssertThrowsErrorAsync { try await owners.outboxEntries(for: owner) }
        let storedPushIntent = try await push.load()
        let pending = try XCTUnwrap(storedPushIntent)
        XCTAssertEqual(pending.retryDirective, .afterBackoff)
    }

    func testPersistedLogoutResumeReplaysExactOperationBeforeUnregister() async throws {
        let owner = OwnerScope(kind: .anonymous)
        let credential = StoredSessionCredential(installationId: "installation-1", generation: 1, proposedCredential: "credential-1", identityClass: .anonymous, ownerScope: owner, logoutPending: true)
        let resume = PendingSessionTransition.resume(transitionId: "resume-transition", installationId: "installation-1", expectedGeneration: 1, presentedCredential: "credential-1", proposedCredential: "credential-2")
        let credentials = InMemoryCredentialStore(credential, pendingTransition: resume)
        let push = InMemoryPushIntentStore()
        try await push.save(ProtectedPushIntent(ownerScope: owner, action: .unregister))
        let transport = MockTransport(responses: [
            sessionResponse(identityClass: "anonymous", generation: 2, sessionId: "session-r", credential: "credential-2"), pushInactiveResponse(),
            sessionResponse(identityClass: "anonymous", generation: 3, sessionId: "session-l", credential: "credential-3"), mobileConfigResponse()
        ])
        let sdk = OnloSDK(credentialStore: credentials, pushIntentStore: push, ownerStore: InMemoryOwnerScopedStore(), transport: transport, hostAppIdentifier: "com.example.host")
        _ = try await sdk.initialize(OnloSDK.Configuration(sdkKey: "public-key", appIdentifier: "com.example.host", apiBaseURL: URL(string: "https://sdk.example.test")!))
        let requests = await transport.requests()
        let first = try XCTUnwrap(requests.first)
        let request = try XCTUnwrap(first.httpBody)
        let decoded = try JSONDecoder().decode(SessionRequest.self, from: request)
        guard case let .resume(transitionId, _, _, proposedCredential) = decoded.operation else { return XCTFail("expected durable resume") }
        XCTAssertEqual(transitionId, "resume-transition")
        XCTAssertEqual(proposedCredential, "credential-2")
    }

    func testPushTokenRefreshUsesOneResumeThenLeavesRepeatedDirectivePending() async throws {
        let transport = MockTransport(responses: [
            sessionResponse(identityClass: "anonymous", generation: 1, sessionId: "session-1", credential: "credential-1"), mobileConfigResponse(), pushResponse(),
            sessionFailure(code: "session_expired", directive: "after_token_refresh"),
            sessionResponse(identityClass: "anonymous", generation: 2, sessionId: "session-2", credential: "credential-2"),
            sessionFailure(code: "session_expired", directive: "after_token_refresh")
        ])
        let push = InMemoryPushIntentStore()
        let sdk = OnloSDK(credentialStore: InMemoryCredentialStore(), configStore: InMemoryConfigStore(), pushIntentStore: push, ownerStore: InMemoryOwnerScopedStore(), transport: transport, hostAppIdentifier: "com.example.host")
        _ = try await sdk.initialize(OnloSDK.Configuration(sdkKey: "public-key", appIdentifier: "com.example.host", apiBaseURL: URL(string: "https://sdk.example.test")!))
        _ = try await sdk.setAPNsPushToken(Data(repeating: 0xAB, count: 32))
        let logoutState = try await sdk.logout()
        XCTAssertEqual(logoutState, .logoutPending)
        let paths = await transport.requests().compactMap { $0.url?.path }
        XCTAssertEqual(paths.filter { $0 == "/api/sdk/v1/session" }.count, 2)
        XCTAssertEqual(paths.filter { $0 == "/api/sdk/v1/push-token" }.count, 3)
        let storedPushIntent = try await push.load()
        let pending = try XCTUnwrap(storedPushIntent)
        XCTAssertEqual(pending.retryDirective, .afterTokenRefresh)
        XCTAssertFalse(pending.automaticallyRetryable)
    }

    func testGatedPushIntentCausesNoRecoveryTraffic() async throws {
        let owner = OwnerScope(kind: .anonymous)
        let credential = StoredSessionCredential(installationId: "installation-1", generation: 1, proposedCredential: "credential-1", identityClass: .anonymous, ownerScope: owner, logoutPending: true)
        let push = InMemoryPushIntentStore()
        try await push.save(ProtectedPushIntent(ownerScope: owner, action: .unregister, retryDirective: .afterAttestation, automaticallyRetryable: false))
        let transport = MockTransport(responses: [])
        let sdk = OnloSDK(credentialStore: InMemoryCredentialStore(credential), pushIntentStore: push, ownerStore: InMemoryOwnerScopedStore(), transport: transport, hostAppIdentifier: "com.example.host")
        _ = try await sdk.initialize(OnloSDK.Configuration(sdkKey: "public-key", appIdentifier: "com.example.host", apiBaseURL: URL(string: "https://sdk.example.test")!))
        let requests = await transport.requests()
        let requestCount = requests.count
        XCTAssertEqual(requestCount, 0)
        let state = await sdk.currentState()
        XCTAssertEqual(state, .logoutPending)
    }

    func testDelayedPushPayloadAcrossLogoutIsDeferredWithoutOldRoute() async throws {
        let controller = DelayedTranscriptController()
        let transport = DelayedPushPayloadTransport(controller: controller)
        let sdk = OnloSDK(credentialStore: InMemoryCredentialStore(), configStore: InMemoryConfigStore(), pushIntentStore: InMemoryPushIntentStore(), ownerStore: InMemoryOwnerScopedStore(), transport: transport, hostAppIdentifier: "com.example.host")
        _ = try await sdk.initialize(OnloSDK.Configuration(sdkKey: "public-key", appIdentifier: "com.example.host", apiBaseURL: URL(string: "https://sdk.example.test")!))
        let task = Task.detached { try await sdk.handlePushNotification(PushNotificationPayload(conversationId: "conversation-old", messageId: "message-old", notificationType: .messageAvailable)) }
        await controller.waitForTranscriptRequest()
        _ = try await sdk.logout()
        await controller.releaseTranscript()
        let result = try await task.value
        XCTAssertEqual(result, .deferred)
    }

    func testSQLiteOwnerStorePersistsStableOutboxID() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let databaseURL = directory.appendingPathComponent("outbox.sqlite")
        defer { try? FileManager.default.removeItem(at: directory) }
        let scope = OwnerScope(kind: .anonymous)
        let messageID = UUID()
        let entry = OutboxEntry(
            clientMessageId: messageID,
            ownerScope: scope,
            message: "synthetic message",
            orderingKey: 1
        )
        let keyStore = InMemoryOutboxKeyStore()
        let firstStore = SQLiteOwnerScopedStore(databaseURL: databaseURL, keyStore: keyStore)
        try await firstStore.prepare(scope: scope)
        try await firstStore.enqueue(entry)

        let reloadedStore = SQLiteOwnerScopedStore(databaseURL: databaseURL, keyStore: keyStore)
        let reloaded = try await reloadedStore.outboxEntries(for: scope)
        XCTAssertEqual(reloaded, [entry])
        XCTAssertEqual(reloaded.first?.clientMessageId, messageID)

        try await reloadedStore.finishLogout(for: scope)
    }

    func testSQLiteOwnerStoreDurablyBlocksThenPurgesOwner() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let databaseURL = directory.appendingPathComponent("outbox.sqlite")
        defer { try? FileManager.default.removeItem(at: directory) }
        let scope = OwnerScope(kind: .identified)
        let entry = OutboxEntry(ownerScope: scope, message: "synthetic message", orderingKey: 1)
        let keyStore = InMemoryOutboxKeyStore()
        let store = SQLiteOwnerScopedStore(databaseURL: databaseURL, keyStore: keyStore)
        try await store.prepare(scope: scope)
        try await store.enqueue(entry)
        try await store.beginLogout(for: scope)

        let restartedStore = SQLiteOwnerScopedStore(databaseURL: databaseURL, keyStore: keyStore)
        await XCTAssertThrowsErrorAsync {
            try await restartedStore.outboxEntries(for: scope)
        }
        await XCTAssertThrowsErrorAsync {
            try await restartedStore.enqueue(entry)
        }

        try await restartedStore.finishLogout(for: scope)
        let replacementStore = SQLiteOwnerScopedStore(databaseURL: databaseURL, keyStore: keyStore)
        try await replacementStore.prepare(scope: scope)
        let replacementEntries = try await replacementStore.outboxEntries(for: scope)
        XCTAssertEqual(replacementEntries, [])
        try await replacementStore.finishLogout(for: scope)
    }

    func testSQLiteOwnerStorePurgesWhenEncryptionKeyChanges() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let databaseURL = directory.appendingPathComponent("outbox.sqlite")
        defer { try? FileManager.default.removeItem(at: directory) }
        let scope = OwnerScope(kind: .identified)
        let keyStore = RotatingOutboxKeyStore()
        let firstStore = SQLiteOwnerScopedStore(databaseURL: databaseURL, keyStore: keyStore)
        try await firstStore.prepare(scope: scope)
        try await firstStore.enqueue(OutboxEntry(ownerScope: scope, message: "synthetic message", orderingKey: 1))

        await keyStore.replace()
        let restartedStore = SQLiteOwnerScopedStore(databaseURL: databaseURL, keyStore: keyStore)
        try await restartedStore.prepare(scope: scope)
        let restartedEntries = try await restartedStore.outboxEntries(for: scope)
        XCTAssertEqual(restartedEntries, [])
        try await restartedStore.finishLogout(for: scope)
    }

    private func readyDurableDispatcher(
        now: @escaping @Sendable () -> Date,
        jitter: @escaping @Sendable (Int) -> Double = { _ in 0 }
    ) async throws -> (OnloSDK, InMemoryCredentialStore, InMemoryOwnerScopedStore) {
        let credentials = InMemoryCredentialStore()
        let store = InMemoryOwnerScopedStore()
        let sdk = OnloSDK(
            credentialStore: credentials,
            ownerStore: store,
            transport: MockTransport(responses: [sessionResponse(identityClass: "anonymous", generation: 1, sessionId: "session-1", credential: "credential-1")]),
            hostAppIdentifier: "com.example.host",
            now: now,
            backoffJitter: jitter
        )
        _ = try await sdk.initialize(OnloSDK.Configuration(sdkKey: "public-key", appIdentifier: "com.example.host", apiBaseURL: URL(string: "https://sdk.example.test")!))
        return (sdk, credentials, store)
    }

    private func sessionResponse(identityClass: String, generation: Int, sessionId: String, credential: String) -> OnloHTTPResponse {
        let json = """
        {
          "requestId": "request-1",
          "serverTime": "2026-07-21T10:00:00.000Z",
          "protocolVersion": 1,
          "minimumProtocolVersion": 1,
          "ok": true,
          "result": {
            "sessionId": "\(sessionId)",
            "chatToken": "opaque-access-token",
            "installationId": "installation-1",
            "generation": \(generation),
            "proposedCredential": "\(credential)",
            "identityClass": "\(identityClass)",
            "publicationState": "testing",
            "attestationState": "not_required",
            "configRevision": "revision-1",
            "configSchemaVersion": 1,
            "configEtag": "etag-1"
          }
        }
        """
        return OnloHTTPResponse(statusCode: 200, body: Data(json.utf8))
    }

    private func transcriptResponse(conversationId: String) -> OnloHTTPResponse {
        let json = """
        {
          "conversation": {
            "id": "\(conversationId)",
            "sessionId": "anonymous-session",
            "status": "open",
            "isHumanTakeover": false
          },
          "messages": [],
          "sync": { "previousCursor": null, "nextCursor": null, "limit": 1 }
        }
        """
        return OnloHTTPResponse(statusCode: 200, body: Data(json.utf8))
    }

    private func pushResponse() -> OnloHTTPResponse {
        let json = """
        {"requestId":"request-push","serverTime":"2026-07-21T10:00:00.000Z","protocolVersion":1,"minimumProtocolVersion":1,"ok":true,"result":{"state":"active","provider":"apns","environment":"sandbox","fingerprint":"redacted","registeredAt":"2026-07-21T10:00:00.000Z"}}
        """
        return OnloHTTPResponse(statusCode: 200, body: Data(json.utf8))
    }

    private func pushInactiveResponse() -> OnloHTTPResponse {
        let json = """
        {"requestId":"request-push","serverTime":"2026-07-21T10:00:00.000Z","protocolVersion":1,"minimumProtocolVersion":1,"ok":true,"result":{"state":"inactive"}}
        """
        return OnloHTTPResponse(statusCode: 200, body: Data(json.utf8))
    }

    private func sessionFailure(code: String, directive: String, retryAfterMs: Int? = nil) -> OnloHTTPResponse {
        let retryAfter = retryAfterMs.map { ",\"retryAfterMs\":\($0)" } ?? ""
        let json = """
        {"requestId":"request-failure","serverTime":"2026-07-21T10:00:00.000Z","protocolVersion":1,"minimumProtocolVersion":1,"ok":false,"error":{"code":"\(code)","message":"safe","retry":{"directive":"\(directive)"\(retryAfter)}}}
        """
        return OnloHTTPResponse(statusCode: 400, body: Data(json.utf8))
    }

    func testConfiguration200ThenExact304PreservesProtectedSnapshotAndETag() async throws {
        let configStore = InMemoryConfigStore()
        let transport = MockTransport(responses: [
            sessionResponse(identityClass: "anonymous", generation: 1, sessionId: "session-1", credential: "credential-1"),
            mobileConfigResponse(),
            OnloHTTPResponse(statusCode: 304, headers: ["ETag": "W/\"mobile-config-example\""], body: Data())
        ])
        let sdk = OnloSDK(credentialStore: InMemoryCredentialStore(), configStore: configStore, ownerStore: InMemoryOwnerScopedStore(), transport: transport, hostAppIdentifier: "com.example.host")
        let configuration = OnloSDK.Configuration(sdkKey: "public-key", appIdentifier: "com.example.host", apiBaseURL: URL(string: "https://sdk.example.test")!)
        let initialized = try await sdk.initialize(configuration)
        XCTAssertEqual(initialized, .anonymousReady)
        let first = try await sdk.currentConfiguration()
        XCTAssertEqual(first?.schemaVersion, 1)
        try await sdk.refreshConfigurationForForeground()
        let persisted = await configStore.state()
        XCTAssertEqual(persisted.etag, "W/\"mobile-config-example\"")
        let requests = await transport.requests()
        let configRequests = requests.filter { $0.url?.path == "/api/sdk/v1/config" }
        XCTAssertEqual(configRequests.last?.value(forHTTPHeaderField: "If-None-Match"), "W/\"mobile-config-example\"")
    }

    func testMalformedConfigurationDoesNotReplaceLastKnownGood() async throws {
        let configStore = InMemoryConfigStore()
        let transport = MockTransport(responses: [
            sessionResponse(identityClass: "anonymous", generation: 1, sessionId: "session-1", credential: "credential-1"),
            mobileConfigResponse(),
            OnloHTTPResponse(statusCode: 200, headers: ["ETag": "bad"], body: Data("{\"ok\":true}".utf8))
        ])
        let sdk = OnloSDK(credentialStore: InMemoryCredentialStore(), configStore: configStore, ownerStore: InMemoryOwnerScopedStore(), transport: transport, hostAppIdentifier: "com.example.host")
        let configuration = OnloSDK.Configuration(sdkKey: "public-key", appIdentifier: "com.example.host", apiBaseURL: URL(string: "https://sdk.example.test")!)
        _ = try await sdk.initialize(configuration)
        await XCTAssertThrowsErrorAsync {
            try await sdk.refreshConfigurationForForeground()
        }
        let persisted = await configStore.state()
        XCTAssertEqual(persisted.config?.revision, "2026-07-21T10:00:00.000Z")
        XCTAssertEqual(persisted.etag, "W/\"mobile-config-example\"")
    }

    func testMobileConfigRequiresNullableSecurityMinimumSDKVersionKey() throws {
        let body = mobileConfigJSON().replacingOccurrences(of: "\"minimumSdkVersion\":null,", with: "")
        XCTAssertThrowsError(try JSONDecoder().decode(APIEnvelope<MobileConfig>.self, from: Data(body.utf8)))
    }

    func testMobileConfigRequiresNullableHeaderAvatarDataKey() throws {
        let body = mobileConfigJSON().replacingOccurrences(of: "\"data\":null", with: "")
        XCTAssertThrowsError(try JSONDecoder().decode(APIEnvelope<MobileConfig>.self, from: Data(body.utf8)))
    }

    func testOfflineConfigurationRefreshRetainsLastKnownGood() async throws {
        let store = InMemoryConfigStore()
        let transport = MockTransport(responses: [
            sessionResponse(identityClass: "anonymous", generation: 1, sessionId: "session-1", credential: "credential-1"), mobileConfigResponse()
        ])
        let sdk = OnloSDK(credentialStore: InMemoryCredentialStore(), configStore: store, ownerStore: InMemoryOwnerScopedStore(), transport: transport, hostAppIdentifier: "com.example.host")
        let configuration = OnloSDK.Configuration(sdkKey: "public-key", appIdentifier: "com.example.host", apiBaseURL: URL(string: "https://sdk.example.test")!)
        _ = try await sdk.initialize(configuration)
        await XCTAssertThrowsErrorAsync {
            try await sdk.refreshConfigurationForForeground()
        }
        let retained = await store.state()
        XCTAssertEqual(retained.config?.revision, "2026-07-21T10:00:00.000Z")
    }

    func testConfigurationChangedUsesConditionalETagRefresh() async throws {
        let store = InMemoryConfigStore()
        let transport = MockTransport(responses: [
            sessionResponse(identityClass: "anonymous", generation: 1, sessionId: "session-1", credential: "credential-1"), mobileConfigResponse(),
            OnloHTTPResponse(statusCode: 304, headers: ["ETag": "W/\"mobile-config-example\""], body: Data())
        ])
        let sdk = OnloSDK(credentialStore: InMemoryCredentialStore(), configStore: store, ownerStore: InMemoryOwnerScopedStore(), transport: transport, hostAppIdentifier: "com.example.host")
        let configuration = OnloSDK.Configuration(sdkKey: "public-key", appIdentifier: "com.example.host", apiBaseURL: URL(string: "https://sdk.example.test")!)
        _ = try await sdk.initialize(configuration)
        try await sdk.configurationChanged()
        let requests = await transport.requests()
        let configRequests = requests.filter { $0.url?.path == "/api/sdk/v1/config" }
        XCTAssertEqual(configRequests.last?.value(forHTTPHeaderField: "If-None-Match"), "W/\"mobile-config-example\"")
    }

    func testConfigurationBackoffDoesNotRequestEarlyAndHonorsSuppliedDelay() async throws {
        let clock = TestClock(Date(timeIntervalSince1970: 1_000))
        let store = InMemoryConfigStore()
        let transport = MockTransport(responses: [
            sessionResponse(identityClass: "anonymous", generation: 1, sessionId: "session-1", credential: "credential-1"),
            sessionFailure(code: "config_unavailable", directive: "after_backoff", retryAfterMs: 9_000)
        ])
        let sdk = OnloSDK(credentialStore: InMemoryCredentialStore(), configStore: store, ownerStore: InMemoryOwnerScopedStore(), transport: transport, hostAppIdentifier: "com.example.host", now: { clock.now() })
        let configuration = OnloSDK.Configuration(sdkKey: "public-key", appIdentifier: "com.example.host", apiBaseURL: URL(string: "https://sdk.example.test")!)
        _ = try await sdk.initialize(configuration)
        await XCTAssertThrowsErrorAsync { try await sdk.refreshConfigurationForForeground() }
        let early = await transport.requests()
        XCTAssertEqual(early.filter { $0.url?.path == "/api/sdk/v1/config" }.count, 1)
        let persisted = await store.state()
        guard case let .afterBackoff(eligibleAt, attempt) = persisted.retry else { return XCTFail("missing backoff") }
        XCTAssertEqual(attempt, 1)
        XCTAssertEqual(eligibleAt, Date(timeIntervalSince1970: 1_009))
    }

    func testConfigurationFallbackBackoffUsesJitterAndCapsAtThreeAttempts() async throws {
        let clock = TestClock(Date(timeIntervalSince1970: 1_000))
        let store = InMemoryConfigStore()
        let failures = (0..<3).map { _ in sessionFailure(code: "config_unavailable", directive: "after_backoff") }
        let transport = MockTransport(responses: [sessionResponse(identityClass: "anonymous", generation: 1, sessionId: "session-1", credential: "credential-1")] + failures)
        let sdk = OnloSDK(credentialStore: InMemoryCredentialStore(), configStore: store, ownerStore: InMemoryOwnerScopedStore(), transport: transport, hostAppIdentifier: "com.example.host", now: { clock.now() }, backoffJitter: { _ in 0.2 })
        let configuration = OnloSDK.Configuration(sdkKey: "public-key", appIdentifier: "com.example.host", apiBaseURL: URL(string: "https://sdk.example.test")!)
        _ = try await sdk.initialize(configuration)
        clock.advance(by: 1_200); await XCTAssertThrowsErrorAsync { try await sdk.refreshConfigurationForForeground() }
        clock.advance(by: 2_400); await XCTAssertThrowsErrorAsync { try await sdk.refreshConfigurationForForeground() }
        let state = await store.state()
        guard case let .afterBackoff(_, attempt) = state.retry else { return XCTFail("missing cap state") }
        XCTAssertEqual(attempt, 3)
        let requests = await transport.requests()
        XCTAssertEqual(requests.filter { $0.url?.path == "/api/sdk/v1/config" }.count, 3)
    }

    func testConfigurationAttestationNeverAndFullSyncDoNotAutoRetry() async throws {
        for directive in ["after_attestation", "never", "after_full_sync"] {
            let transport = MockTransport(responses: [sessionResponse(identityClass: "anonymous", generation: 1, sessionId: "session-1", credential: "credential-1"), sessionFailure(code: "config_unavailable", directive: directive)])
            let sdk = OnloSDK(credentialStore: InMemoryCredentialStore(), configStore: InMemoryConfigStore(), ownerStore: InMemoryOwnerScopedStore(), transport: transport, hostAppIdentifier: "com.example.host")
            let configuration = OnloSDK.Configuration(sdkKey: "public-key", appIdentifier: "com.example.host", apiBaseURL: URL(string: "https://sdk.example.test")!)
            _ = try await sdk.initialize(configuration)
            let requests = await transport.requests()
            XCTAssertEqual(requests.filter { $0.url?.path == "/api/sdk/v1/config" }.count, 1, directive)
        }
    }

    func testConfigurationTokenRefreshPerformsOneResumeAndOneRetry() async throws {
        let transport = MockTransport(responses: [
            sessionResponse(identityClass: "anonymous", generation: 1, sessionId: "session-1", credential: "credential-1"),
            sessionFailure(code: "session_expired", directive: "after_token_refresh"),
            sessionResponse(identityClass: "anonymous", generation: 2, sessionId: "session-2", credential: "credential-2"),
            mobileConfigResponse()
        ])
        let sdk = OnloSDK(credentialStore: InMemoryCredentialStore(), configStore: InMemoryConfigStore(), pushIntentStore: InMemoryPushIntentStore(), ownerStore: InMemoryOwnerScopedStore(), transport: transport, hostAppIdentifier: "com.example.host")
        let configuration = OnloSDK.Configuration(sdkKey: "public-key", appIdentifier: "com.example.host", apiBaseURL: URL(string: "https://sdk.example.test")!)
        _ = try await sdk.initialize(configuration)
        let requests = await transport.requests()
        let sdkRequests = requests.filter { $0.url?.path == "/api/sdk/v1/session" || $0.url?.path == "/api/sdk/v1/config" }
        XCTAssertEqual(sdkRequests.map { $0.url?.path }, ["/api/sdk/v1/session", "/api/sdk/v1/config", "/api/sdk/v1/session", "/api/sdk/v1/config"])
    }

    func testConfigurationRepeatedTokenRefreshDoesNotResumeTwice() async throws {
        let transport = MockTransport(responses: [
            sessionResponse(identityClass: "anonymous", generation: 1, sessionId: "session-1", credential: "credential-1"),
            sessionFailure(code: "session_expired", directive: "after_token_refresh"),
            sessionResponse(identityClass: "anonymous", generation: 2, sessionId: "session-2", credential: "credential-2"),
            sessionFailure(code: "session_expired", directive: "after_token_refresh")
        ])
        let sdk = OnloSDK(credentialStore: InMemoryCredentialStore(), configStore: InMemoryConfigStore(), pushIntentStore: InMemoryPushIntentStore(), ownerStore: InMemoryOwnerScopedStore(), transport: transport, hostAppIdentifier: "com.example.host")
        let configuration = OnloSDK.Configuration(sdkKey: "public-key", appIdentifier: "com.example.host", apiBaseURL: URL(string: "https://sdk.example.test")!)
        _ = try await sdk.initialize(configuration)
        let requests = await transport.requests()
        XCTAssertEqual(requests.filter { $0.url?.path == "/api/sdk/v1/session" || $0.url?.path == "/api/sdk/v1/config" }.count, 4)
    }

    func testSQLiteTranscriptIsPurgedBeforeOwnerScopeLogout() async throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("onlo-transcript-\(UUID().uuidString)", isDirectory: true)
        let database = directory.appendingPathComponent("outbox.sqlite")
        let store = SQLiteOwnerScopedStore(databaseURL: database, keyStore: InMemoryOutboxKeyStore())
        let owner = OwnerScope(kind: .identified)
        try await store.prepare(scope: owner)
        let transcript = try OnloResponseDecoder.widget(ConversationTranscriptResult.self, from: transcriptResponse(conversationId: "conversation-1"))
        try await store.replaceTranscript(transcript, for: owner)
        try await store.beginLogout(for: owner)
        await XCTAssertThrowsErrorAsync { try await store.outboxEntries(for: owner) }
        try await store.finishLogout(for: owner)
        let fresh = OwnerScope(kind: .anonymous)
        try await store.prepare(scope: fresh)
        let freshEntries = try await store.outboxEntries(for: fresh)
        XCTAssertEqual(freshEntries, [])
        try? FileManager.default.removeItem(at: directory)
    }

    func testLogoutCancelsScheduledConfigurationRetry() async throws {
        let transport = MockTransport(responses: [
            sessionResponse(identityClass: "anonymous", generation: 1, sessionId: "session-1", credential: "credential-1"),
            sessionFailure(code: "config_unavailable", directive: "after_backoff", retryAfterMs: 10),
            sessionResponse(identityClass: "anonymous", generation: 2, sessionId: "session-2", credential: "credential-2")
        ])
        let sdk = OnloSDK(credentialStore: InMemoryCredentialStore(), configStore: InMemoryConfigStore(), pushIntentStore: InMemoryPushIntentStore(), ownerStore: InMemoryOwnerScopedStore(), transport: transport, hostAppIdentifier: "com.example.host")
        let configuration = OnloSDK.Configuration(sdkKey: "public-key", appIdentifier: "com.example.host", apiBaseURL: URL(string: "https://sdk.example.test")!)
        _ = try await sdk.initialize(configuration)
        _ = try await sdk.logout()
        try await Task.sleep(nanoseconds: 100_000_000)
        let requests = await transport.requests()
        XCTAssertEqual(requests.filter { $0.url?.path == "/api/sdk/v1/config" }.count, 1)
    }

    func testDelayedOldSessionConfigurationCannotPersistAfterLogoutBoundary() async throws {
        let transport = DelayedConfigTransport()
        let store = InMemoryConfigStore()
        let sdk = OnloSDK(credentialStore: InMemoryCredentialStore(), configStore: store, pushIntentStore: InMemoryPushIntentStore(), ownerStore: InMemoryOwnerScopedStore(), transport: transport, hostAppIdentifier: "com.example.host")
        let configuration = OnloSDK.Configuration(sdkKey: "public-key", appIdentifier: "com.example.host", apiBaseURL: URL(string: "https://sdk.example.test")!)
        let initialization = Task.detached { try await sdk.initialize(configuration) }
        await transport.waitForConfigRequest()
        _ = try await sdk.logout()
        await transport.releaseOldConfig()
        _ = try await initialization.value
        let retained = await store.state()
        XCTAssertNil(retained.config)
        XCTAssertNil(retained.etag)
        let requests = await transport.requestPaths()
        XCTAssertEqual(
            requests.filter { $0 == "/api/sdk/v1/session" || $0 == "/api/sdk/v1/config" },
            ["/api/sdk/v1/session", "/api/sdk/v1/config", "/api/sdk/v1/session", "/api/sdk/v1/config"]
        )
    }

    private func mobileConfigResponse() -> OnloHTTPResponse {
        let json = mobileConfigJSON()
        return OnloHTTPResponse(statusCode: 200, headers: ["ETag": "W/\"mobile-config-example\""], body: Data(json.utf8))
    }

    private func mobileConfigJSON() -> String { """
    {"requestId":"config-1","serverTime":"2026-07-21T10:00:00.000Z","protocolVersion":1,"minimumProtocolVersion":1,"ok":true,"result":{"schemaVersion":1,"revision":"2026-07-21T10:00:00.000Z","compatibility":{"requestedSchemaVersion":1,"appliedSchemaVersion":1,"capabilities":["config_schema_v1"],"unsupportedSettings":[]},"securityPolicy":{"minimumProtocolVersion":1,"minimumSdkVersion":null,"identityMode":"sdk_interface","anonymousScope":"installation_generation","nativePlacement":"host_app"},"appearance":{"accent":"#6750A4","botName":"Onlo","botSubtitle":"Help","greeting":"Hi","headerAvatar":{"mode":"initials","text":"OA","data":null},"light":{"background":"#fff","outgoing":"#111","outgoingText":"#fff","incoming":"#eee","incomingText":"#000"},"dark":{"enabled":true,"background":"#000","outgoing":"#111","outgoingText":"#fff","incoming":"#222","incomingText":"#eee"}},"features":{"insertLink":false,"insertCode":false,"emoji":true,"gifs":false,"voice":false,"fileUpload":true,"transcriptDownload":false,"soundNotifications":true,"showTimestamps":true,"faqButton":{"enabled":true,"label":"Help"}},"content":{"faqs":[],"tabs":{"enabled":true,"tabs":[],"defaultTab":"home"},"search":{"enabled":true,"placeholder":"Search","showSearchInHome":true},"onboarding":{"enabled":false,"title":"Welcome","showProgress":false,"items":[]},"homeSections":[]},"identityMode":"sdk_interface","unsupportedWidgetSettings":[]}}
    """ }
}

private func activeOwnerScope(_ credentials: InMemoryCredentialStore) async throws -> OwnerScope {
    let protectedState = try await credentials.loadState()
    return try XCTUnwrap(protectedState.credential?.ownerScope)
}

private func firstOutboxEntry(
    _ store: InMemoryOwnerScopedStore,
    for scope: OwnerScope
) async throws -> OutboxEntry {
    let entries = try await store.outboxEntries(for: scope)
    return try XCTUnwrap(entries.first)
}

private extension StoredSessionCredential {
    func thenEncode() throws -> String {
        let data = try JSONEncoder().encode(self)
        return try XCTUnwrap(String(data: data, encoding: .utf8))
    }
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: () async throws -> T,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("expected an error", file: file, line: line)
    } catch {}
}

private func XCTAssertEqualSessionRequestBodies(
    _ first: URLRequest,
    _ second: URLRequest,
    file: StaticString = #filePath,
    line: UInt = #line
) throws {
    let firstBody = try XCTUnwrap(first.httpBody, file: file, line: line)
    let secondBody = try XCTUnwrap(second.httpBody, file: file, line: line)
    XCTAssertEqual(
        try JSONDecoder().decode(SessionRequest.self, from: firstBody),
        try JSONDecoder().decode(SessionRequest.self, from: secondBody),
        file: file,
        line: line
    )
}

private actor InMemoryOutboxKeyStore: OutboxEncryptionKeyStoring {
    private let key = SymmetricKey(size: .bits256)

    func loadOrCreate() async throws -> SymmetricKey { key }
}

private actor InMemoryConfigStore: MobileConfigStoring {
    private var stored = ProtectedMobileConfigState(config: nil, etag: nil, retry: nil)
    func loadConfigState() async throws -> ProtectedMobileConfigState { stored }
    func saveConfigState(_ state: ProtectedMobileConfigState) async throws { stored = state }
    func state() -> ProtectedMobileConfigState { stored }
}

private actor RotatingOutboxKeyStore: OutboxEncryptionKeyStoring {
    private var key = SymmetricKey(size: .bits256)

    func loadOrCreate() async throws -> SymmetricKey { key }
    func replace() { key = SymmetricKey(size: .bits256) }
}

private final class StreamingMockTransport: OnloChatSSETransport, @unchecked Sendable {
    private let events: [ChatEvent]

    init(events: [ChatEvent]) { self.events = events }

    func execute(_ request: URLRequest) async throws -> OnloHTTPResponse {
        throw OnloError.transport(code: "unexpected_request")
    }

    func chatEvents(for request: URLRequest) -> AsyncThrowingStream<ChatEvent, Error> {
        let configuredEvents = events
        return AsyncThrowingStream { continuation in
            let task = Task.detached {
                for event in configuredEvents {
                    guard !Task.isCancelled else { return }
                    continuation.yield(event)
                    await Task.yield()
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

private final class ImmediateAcceptedTransport: OnloChatSSETransport, @unchecked Sendable {
    private let lock = NSLock()
    private var chatEventRequests = 0

    func execute(_ request: URLRequest) async throws -> OnloHTTPResponse {
        let json = """
        {"requestId":"request-1","serverTime":"2026-01-01T00:00:00Z","protocolVersion":1,"minimumProtocolVersion":1,"ok":true,"result":{"sessionId":"session-1","chatToken":"opaque-access-token","installationId":"installation-1","generation":1,"proposedCredential":"credential-1","identityClass":"anonymous","publicationState":"testing","attestationState":"not_required","configRevision":"revision-1","configSchemaVersion":1,"configEtag":"etag-1"}}
        """
        return sessionResponseMatchingRequest(OnloHTTPResponse(statusCode: 200, body: Data(json.utf8)), request: request)
    }

    func chatEvents(for request: URLRequest) -> AsyncThrowingStream<ChatEvent, Error> {
        lock.withLock { chatEventRequests += 1 }
        let clientMessageID: String
        if let body = request.httpBody, let chat = try? JSONDecoder().decode(ChatRequest.self, from: body) {
            clientMessageID = chat.clientMessageId
        } else {
            clientMessageID = "invalid"
        }
        return AsyncThrowingStream { continuation in
            continuation.yield(.accepted(clientMessageId: clientMessageID, messageId: "message-1", conversationId: "conversation-1", acceptedAt: "2026-01-01T00:00:00Z", duplicate: false, processingStatus: "accepted"))
            continuation.finish()
        }
    }

    func chatEventRequestCount() -> Int { lock.withLock { chatEventRequests } }
}

private actor ChatRequestRecorder {
    private var request: URLRequest?
    private var waiter: CheckedContinuation<Void, Never>?

    func record(_ request: URLRequest) {
        self.request = request
        waiter?.resume()
        waiter = nil
    }

    func value() -> URLRequest? { request }

    func wait() async {
        if request != nil { return }
        await withCheckedContinuation { waiter = $0 }
    }
}

private final class RecordingAcceptedTransport: OnloChatSSETransport, @unchecked Sendable {
    private let recorder = ChatRequestRecorder()

    func execute(_ request: URLRequest) async throws -> OnloHTTPResponse {
        durableSessionResponse(for: request)
    }

    func chatEvents(for request: URLRequest) -> AsyncThrowingStream<ChatEvent, Error> {
        let recorder = recorder
        let clientMessageID: String
        if let body = request.httpBody, let chat = try? JSONDecoder().decode(ChatRequest.self, from: body) {
            clientMessageID = chat.clientMessageId
        } else {
            clientMessageID = "invalid"
        }
        return AsyncThrowingStream { continuation in
            Task.detached { await recorder.record(request) }
            continuation.yield(.accepted(clientMessageId: clientMessageID, messageId: "message-1", conversationId: "conversation-1", acceptedAt: "2026-01-01T00:00:00Z", duplicate: false, processingStatus: "accepted"))
            continuation.finish()
        }
    }

    func chatRequest() async -> URLRequest? { await recorder.value() }
    func hasChatRequest() async -> Bool { await recorder.value() != nil }
    func waitForChatRequest() async { await recorder.wait() }
}

private final class DuplicateAcceptedTransport: OnloChatSSETransport, @unchecked Sendable {
    private let lock = NSLock()
    private var paths: [String] = []

    func execute(_ request: URLRequest) async throws -> OnloHTTPResponse {
        let path = request.url?.path ?? ""
        lock.withLock { paths.append(path) }
        if path == "/api/widget/conversations/conversation-1" {
            return OnloHTTPResponse(statusCode: 200, body: Data("{\"conversation\":{\"id\":\"conversation-1\",\"sessionId\":\"session-1\",\"status\":\"open\",\"isHumanTakeover\":false},\"messages\":[],\"sync\":{\"previousCursor\":null,\"nextCursor\":null,\"limit\":100}}".utf8))
        }
        return durableSessionResponse(for: request)
    }

    func chatEvents(for request: URLRequest) -> AsyncThrowingStream<ChatEvent, Error> {
        let clientMessageID: String
        if let body = request.httpBody, let chat = try? JSONDecoder().decode(ChatRequest.self, from: body) {
            clientMessageID = chat.clientMessageId
        } else {
            clientMessageID = "invalid"
        }
        return AsyncThrowingStream { continuation in
            continuation.yield(.accepted(clientMessageId: clientMessageID, messageId: "message-1", conversationId: "conversation-1", acceptedAt: "2026-01-01T00:00:00Z", duplicate: true, processingStatus: "accepted"))
            continuation.finish()
        }
    }

    func requestPaths() -> [String] { lock.withLock { paths } }
}

private final class FinishingChatTransport: OnloChatSSETransport, @unchecked Sendable {
    func execute(_ request: URLRequest) async throws -> OnloHTTPResponse { durableSessionResponse(for: request) }

    func chatEvents(for request: URLRequest) -> AsyncThrowingStream<ChatEvent, Error> {
        return AsyncThrowingStream { $0.finish() }
    }
}

private final class ChatFailureTransport: OnloChatSSETransport, @unchecked Sendable {
    enum Mode { case wrongAcceptedID, widgetError }
    private let mode: Mode

    init(mode: Mode) { self.mode = mode }

    func execute(_ request: URLRequest) async throws -> OnloHTTPResponse { durableSessionResponse(for: request) }

    func chatEvents(for request: URLRequest) -> AsyncThrowingStream<ChatEvent, Error> {
        let mode = mode
        return AsyncThrowingStream { continuation in
            switch mode {
            case .wrongAcceptedID:
                continuation.yield(.accepted(clientMessageId: "wrong-id", messageId: "message-1", conversationId: "conversation-1", acceptedAt: "2026-01-01T00:00:00Z", duplicate: false, processingStatus: "accepted"))
                continuation.finish()
            case .widgetError:
                continuation.finish(throwing: OnloError.transport(code: "widget_error"))
            }
        }
    }
}

private actor ChatRequestCounter {
    private var count = 0
    func increment() { count += 1 }
    func value() -> Int { count }
}

private final class DuplicateTranscriptFailureTransport: OnloChatSSETransport, @unchecked Sendable {
    private let counter = ChatRequestCounter()

    func execute(_ request: URLRequest) async throws -> OnloHTTPResponse {
        if request.url?.path == "/api/widget/conversations/conversation-1" {
            throw OnloError.transport(code: "network_unavailable")
        }
        return durableSessionResponse(for: request)
    }

    func chatEvents(for request: URLRequest) -> AsyncThrowingStream<ChatEvent, Error> {
        let counter = counter
        let clientMessageID: String
        if let body = request.httpBody, let chat = try? JSONDecoder().decode(ChatRequest.self, from: body) {
            clientMessageID = chat.clientMessageId
        } else {
            clientMessageID = "invalid"
        }
        return AsyncThrowingStream { continuation in
            Task.detached { await counter.increment() }
            continuation.yield(.accepted(clientMessageId: clientMessageID, messageId: "message-1", conversationId: "conversation-1", acceptedAt: "2026-01-01T00:00:00Z", duplicate: true, processingStatus: "accepted"))
            continuation.finish()
        }
    }

    func chatRequestCount() async -> Int { await counter.value() }
}

private final class AcceptedThenGenericFailureTransport: OnloChatSSETransport, @unchecked Sendable {
    func execute(_ request: URLRequest) async throws -> OnloHTTPResponse { durableSessionResponse(for: request) }

    func chatEvents(for request: URLRequest) -> AsyncThrowingStream<ChatEvent, Error> {
        let clientMessageID: String
        if let body = request.httpBody, let chat = try? JSONDecoder().decode(ChatRequest.self, from: body) {
            clientMessageID = chat.clientMessageId
        } else {
            clientMessageID = "invalid"
        }
        return AsyncThrowingStream { continuation in
            continuation.yield(.accepted(clientMessageId: clientMessageID, messageId: "message-1", conversationId: "conversation-1", acceptedAt: "2026-01-01T00:00:00Z", duplicate: false, processingStatus: "accepted"))
            continuation.finish(throwing: URLError(.cannotConnectToHost))
        }
    }
}

private actor ForegroundStreamController {
    private var subscriptions = 0
    private var waiters: [Int: CheckedContinuation<Void, Never>] = [:]

    func subscribed() {
        subscriptions += 1
        for (target, waiter) in waiters where subscriptions >= target {
            waiter.resume()
            waiters[target] = nil
        }
    }

    func waitForSubscriptions(_ target: Int) async {
        if subscriptions >= target { return }
        await withCheckedContinuation { waiters[target] = $0 }
    }
}

private final class ForegroundLifecycleTransport: OnloForegroundSSETransport, @unchecked Sendable {
    private let controller: ForegroundStreamController
    private let identifyFails: Bool
    private let configRefreshesToken: Bool
    private let lock = NSLock()
    private var configRequests = 0
    private var sessionRequests = 0
    private var streamTokens: [String] = []

    init(controller: ForegroundStreamController, identifyFails: Bool = false, configRefreshesToken: Bool = false) {
        self.controller = controller
        self.identifyFails = identifyFails
        self.configRefreshesToken = configRefreshesToken
    }

    func execute(_ request: URLRequest) async throws -> OnloHTTPResponse {
        if request.url?.path == "/api/sdk/v1/config" {
            let count = lock.withLock { configRequests += 1; return configRequests }
            if configRefreshesToken && count == 2 {
                return OnloHTTPResponse(statusCode: 401, body: Data("{\"requestId\":\"r\",\"serverTime\":\"2026-01-01T00:00:00Z\",\"protocolVersion\":1,\"minimumProtocolVersion\":1,\"ok\":false,\"error\":{\"code\":\"session_expired\",\"message\":\"safe\",\"retry\":{\"directive\":\"after_token_refresh\"}}}".utf8))
            }
            return delayedMobileConfigResponse()
        }
        if let body = request.httpBody,
           let session = try? JSONDecoder().decode(SessionRequest.self, from: body),
           case .identify = session.operation, identifyFails {
            return OnloHTTPResponse(statusCode: 400, body: Data("{\"requestId\":\"r\",\"serverTime\":\"2026-01-01T00:00:00Z\",\"protocolVersion\":1,\"minimumProtocolVersion\":1,\"ok\":false,\"error\":{\"code\":\"identity_disabled\",\"message\":\"safe\",\"retry\":{\"directive\":\"never\"}}}".utf8))
        }
        let sessionNumber = lock.withLock { sessionRequests += 1; return sessionRequests }
        return foregroundSessionResponse(for: request, token: "synthetic-stream-token-\(sessionNumber)")
    }

    func streamEvents(for request: URLRequest) -> AsyncThrowingStream<StreamEvent, Error> {
        let controller = controller
        let authorization = request.value(forHTTPHeaderField: "Authorization") ?? ""
        lock.withLock { streamTokens.append(authorization) }
        return AsyncThrowingStream(unfolding: {
            await controller.subscribed()
            try await Task.sleep(nanoseconds: 3_600_000_000_000)
            return nil
        })
    }

    func streamAuthorizations() async -> [String] { lock.withLock { streamTokens } }
}

private func foregroundSessionResponse(for request: URLRequest, token: String) -> OnloHTTPResponse {
    guard let body = request.httpBody, let session = try? JSONDecoder().decode(SessionRequest.self, from: body) else { return durableSessionResponse(for: request) }
    let credential: String
    switch session.operation {
    case let .bootstrap(_, proposedCredential, _): credential = proposedCredential
    case let .resume(_, _, _, proposedCredential), let .identify(_, _, _, proposedCredential, _), let .logout(_, _, _, proposedCredential): credential = proposedCredential
    }
    let json = "{\"requestId\":\"r\",\"serverTime\":\"2026-01-01T00:00:00Z\",\"protocolVersion\":1,\"minimumProtocolVersion\":1,\"ok\":true,\"result\":{\"sessionId\":\"session-1\",\"chatToken\":\"\(token)\",\"installationId\":\"\(session.client.installationId)\",\"generation\":1,\"proposedCredential\":\"\(credential)\",\"identityClass\":\"anonymous\",\"publicationState\":\"testing\",\"attestationState\":\"not_required\",\"configRevision\":\"r\",\"configSchemaVersion\":1,\"configEtag\":\"etag\"}}"
    return OnloHTTPResponse(statusCode: 200, body: Data(json.utf8))
}

private actor DelayedTranscriptController {
    private var requested: CheckedContinuation<Void, Never>?
    private var release: CheckedContinuation<Void, Never>?
    private var started = false
    private var cancelled = false

    func begin() async {
        started = true
        requested?.resume()
        requested = nil
        await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                if cancelled {
                    continuation.resume()
                } else {
                    release = continuation
                }
            }
        }, onCancel: {
            Task.detached { await self.cancelPendingTranscript() }
        })
    }

    func waitForTranscriptRequest() async {
        if started { return }
        await withCheckedContinuation { requested = $0 }
    }

    func releaseTranscript() { release?.resume(); release = nil }

    private func cancelPendingTranscript() {
        cancelled = true
        release?.resume()
        release = nil
    }
}

private final class DelayedTranscriptForegroundTransport: OnloForegroundSSETransport, @unchecked Sendable {
    private let controller: DelayedTranscriptController
    private let lock = NSLock()
    private var sessions = 0

    init(controller: DelayedTranscriptController) { self.controller = controller }

    func execute(_ request: URLRequest) async throws -> OnloHTTPResponse {
        if request.url?.path == "/api/widget/conversations/conversation-old" {
            await controller.begin()
            if Task.isCancelled { throw OnloError.transport(code: "network_unavailable") }
            return OnloHTTPResponse(statusCode: 200, body: Data("{\"conversation\":{\"id\":\"conversation-old\",\"sessionId\":\"session-1\",\"status\":\"open\",\"isHumanTakeover\":false},\"messages\":[],\"sync\":{\"previousCursor\":null,\"nextCursor\":null,\"limit\":100}}".utf8))
        }
        if request.url?.path == "/api/sdk/v1/config" { return delayedMobileConfigResponse() }
        let session = lock.withLock { sessions += 1; return sessions }
        return foregroundSessionResponse(for: request, token: "synthetic-token-\(session)")
    }

    func streamEvents(for request: URLRequest) -> AsyncThrowingStream<StreamEvent, Error> {
        return AsyncThrowingStream { continuation in
            continuation.yield(.inboxConversation(conversationId: "conversation-old"))
        }
    }
}

private final class DelayedPushPayloadTransport: OnloHTTPTransport, @unchecked Sendable {
    private let controller: DelayedTranscriptController

    init(controller: DelayedTranscriptController) { self.controller = controller }

    func execute(_ request: URLRequest) async throws -> OnloHTTPResponse {
        if request.url?.path == "/api/widget/conversations/conversation-old" {
            await controller.begin()
            let json = """
            {"conversation":{"id":"conversation-old","sessionId":"session-1","status":"open","isHumanTakeover":false},"messages":[{"id":"message-old","externalId":null,"role":"assistant","senderType":null,"senderName":null,"senderTeam":null,"text":"synthetic","attachments":[],"timestamp":1}],"sync":{"previousCursor":null,"nextCursor":null,"limit":100}}
            """
            return OnloHTTPResponse(statusCode: 200, body: Data(json.utf8))
        }
        if request.url?.path == "/api/sdk/v1/config" { return delayedMobileConfigResponse() }
        return durableSessionResponse(for: request)
    }
}

private func durableSessionResponse(for request: URLRequest) -> OnloHTTPResponse {
    let installationId: String
    let proposedCredential: String
    if let body = request.httpBody,
       let session = try? JSONDecoder().decode(SessionRequest.self, from: body) {
        installationId = session.client.installationId
        switch session.operation {
        case let .bootstrap(_, credential, _): proposedCredential = credential
        case let .resume(_, _, _, credential), let .identify(_, _, _, credential, _), let .logout(_, _, _, credential): proposedCredential = credential
        }
    } else {
        installationId = "installation-1"
        proposedCredential = "credential-1"
    }
    let json = "{\"requestId\":\"request-1\",\"serverTime\":\"2026-01-01T00:00:00Z\",\"protocolVersion\":1,\"minimumProtocolVersion\":1,\"ok\":true,\"result\":{\"sessionId\":\"session-1\",\"chatToken\":\"opaque-access-token\",\"installationId\":\"\(installationId)\",\"generation\":1,\"proposedCredential\":\"\(proposedCredential)\",\"identityClass\":\"anonymous\",\"publicationState\":\"testing\",\"attestationState\":\"not_required\",\"configRevision\":\"revision-1\",\"configSchemaVersion\":1,\"configEtag\":\"etag-1\"}}"
    return OnloHTTPResponse(statusCode: 200, body: Data(json.utf8))
}

private func sessionResponseMatchingRequest(_ response: OnloHTTPResponse, request: URLRequest) -> OnloHTTPResponse {
    guard request.url?.path == "/api/sdk/v1/session",
          let body = request.httpBody,
          let session = try? JSONDecoder().decode(SessionRequest.self, from: body),
          var envelope = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any],
          var result = envelope["result"] as? [String: Any] else {
        return response
    }

    let proposedCredential: String
    switch session.operation {
    case let .bootstrap(_, credential, _): proposedCredential = credential
    case let .resume(_, _, _, credential), let .identify(_, _, _, credential, _), let .logout(_, _, _, credential): proposedCredential = credential
    }
    result["installationId"] = session.client.installationId
    result["proposedCredential"] = proposedCredential
    envelope["result"] = result
    guard let rewrittenBody = try? JSONSerialization.data(withJSONObject: envelope) else { return response }
    return OnloHTTPResponse(statusCode: response.statusCode, headers: response.headers, body: rewrittenBody)
}

private actor ControlledSSEController {
    private var continuation: AsyncThrowingStream<ChatEvent, Error>.Continuation?
    private var subscriber: CheckedContinuation<Void, Never>?

    func attach(_ continuation: AsyncThrowingStream<ChatEvent, Error>.Continuation) {
        self.continuation = continuation
        subscriber?.resume()
        subscriber = nil
    }

    func waitUntilSubscribed() async {
        if continuation != nil { return }
        await withCheckedContinuation { subscriber = $0 }
    }

    func yield(_ event: ChatEvent) { continuation?.yield(event) }
}

private final class ControlledChatTransport: OnloChatSSETransport, @unchecked Sendable {
    private let controller: ControlledSSEController
    private var sessionRequests = 0

    init(controller: ControlledSSEController) { self.controller = controller }

    func execute(_ request: URLRequest) async throws -> OnloHTTPResponse {
        sessionRequests += 1
        let generation = sessionRequests == 1 ? 1 : 2
        let identity = "anonymous"
        let json = """
        {"requestId":"request-\(sessionRequests)","serverTime":"2026-01-01T00:00:00Z","protocolVersion":1,"minimumProtocolVersion":1,"ok":true,"result":{"sessionId":"session-\(generation)","chatToken":"opaque-access-token","installationId":"installation-1","generation":\(generation),"proposedCredential":"credential-\(generation)","identityClass":"\(identity)","publicationState":"testing","attestationState":"not_required","configRevision":"revision-1","configSchemaVersion":1,"configEtag":"etag-1"}}
        """
        return sessionResponseMatchingRequest(OnloHTTPResponse(statusCode: 200, body: Data(json.utf8)), request: request)
    }

    func chatEvents(for request: URLRequest) -> AsyncThrowingStream<ChatEvent, Error> {
        let controller = controller
        return AsyncThrowingStream { continuation in
            Task.detached { await controller.attach(continuation) }
        }
    }
}

private actor MockTransport: OnloHTTPTransport {
    private var responses: [OnloHTTPResponse]
    private var capturedRequests: [URLRequest] = []

    init(responses: [OnloHTTPResponse]) {
        self.responses = responses
    }

    func execute(_ request: URLRequest) async throws -> OnloHTTPResponse {
        capturedRequests.append(request)
        if request.url?.path == "/api/widget/conversations" {
            return emptyInboxResponse()
        }
        if request.url?.path == "/api/sdk/v1/config",
           let next = responses.first,
           !isConfigurationFixture(next) {
            return delayedMobileConfigResponse()
        }
        guard !responses.isEmpty else { throw OnloError.transport(code: "unexpected_request") }
        return sessionResponseMatchingRequest(responses.removeFirst(), request: request)
    }

    func requests() -> [URLRequest] { capturedRequests }
}

private actor DelayedConfigTransport: OnloHTTPTransport {
    private var paths: [String] = []
    private var sessionCount = 0
    private var configCount = 0
    private var started: CheckedContinuation<Void, Never>?
    private var delayed: CheckedContinuation<OnloHTTPResponse, Never>?

    func execute(_ request: URLRequest) async throws -> OnloHTTPResponse {
        let path = request.url?.path ?? ""
        paths.append(path)
        if path == "/api/sdk/v1/config" {
            configCount += 1
            if configCount > 1 { return OnloHTTPResponse(statusCode: 500, body: Data("{}".utf8)) }
            started?.resume(); started = nil
            return await withCheckedContinuation { delayed = $0 }
        }
        sessionCount += 1
        return sessionResponseMatchingRequest(delayedSessionResponse(generation: sessionCount), request: request)
    }

    func waitForConfigRequest() async {
        if paths.contains("/api/sdk/v1/config") { return }
        await withCheckedContinuation { started = $0 }
    }

    func releaseOldConfig() {
        delayed?.resume(returning: delayedMobileConfigResponse())
        delayed = nil
    }

    func requestPaths() -> [String] { paths }
}

private func delayedSessionResponse(generation: Int) -> OnloHTTPResponse {
    let json = """
    {"requestId":"session-\(generation)","serverTime":"2026-07-21T10:00:00.000Z","protocolVersion":1,"minimumProtocolVersion":1,"ok":true,"result":{"sessionId":"session-\(generation)","chatToken":"synthetic-token","installationId":"installation-1","generation":\(generation),"proposedCredential":"credential-\(generation)","identityClass":"anonymous","publicationState":"testing","attestationState":"not_required","configRevision":"r","configSchemaVersion":1,"configEtag":"etag"}}
    """
    return OnloHTTPResponse(statusCode: 200, body: Data(json.utf8))
}

private func delayedMobileConfigResponse() -> OnloHTTPResponse {
    let json = """
    {"requestId":"config","serverTime":"2026-07-21T10:00:00.000Z","protocolVersion":1,"minimumProtocolVersion":1,"ok":true,"result":{"schemaVersion":1,"revision":"r","compatibility":{"requestedSchemaVersion":1,"appliedSchemaVersion":1,"capabilities":["config_schema_v1"],"unsupportedSettings":[]},"securityPolicy":{"minimumProtocolVersion":1,"minimumSdkVersion":null,"identityMode":"sdk_interface","anonymousScope":"installation_generation","nativePlacement":"host_app"},"appearance":{"accent":"#000","botName":"B","botSubtitle":"S","greeting":"G","headerAvatar":{"mode":"initials","text":"O","data":null},"light":{"background":"#0","outgoing":"#1","outgoingText":"#2","incoming":"#3","incomingText":"#4"},"dark":{"enabled":false,"background":"#0","outgoing":"#1","outgoingText":"#2","incoming":"#3","incomingText":"#4"}},"features":{"insertLink":false,"insertCode":false,"emoji":false,"gifs":false,"voice":false,"fileUpload":false,"transcriptDownload":false,"soundNotifications":false,"showTimestamps":false,"faqButton":{"enabled":false,"label":""}},"content":{"faqs":[],"tabs":{"enabled":false,"tabs":[],"defaultTab":""},"search":{"enabled":false,"placeholder":"","showSearchInHome":false},"onboarding":{"enabled":false,"title":"","showProgress":false,"items":[]},"homeSections":[]},"identityMode":"sdk_interface","unsupportedWidgetSettings":[]}}
    """
    return OnloHTTPResponse(statusCode: 200, headers: ["ETag": "etag"], body: Data(json.utf8))
}

private actor LostBootstrapResponseTransport: OnloHTTPTransport {
    private var firstRequest = true
    private let response: OnloHTTPResponse
    private var capturedRequests: [URLRequest] = []

    init(response: OnloHTTPResponse) { self.response = response }

    func execute(_ request: URLRequest) async throws -> OnloHTTPResponse {
        capturedRequests.append(request)
        if request.url?.path == "/api/widget/conversations" { return emptyInboxResponse() }
        if request.url?.path == "/api/sdk/v1/config" { return delayedMobileConfigResponse() }
        if firstRequest {
            firstRequest = false
            throw OnloError.transport(code: "network_unavailable")
        }
        return sessionResponseMatchingRequest(response, request: request)
    }

    func requests() -> [URLRequest] { capturedRequests }
}

private actor ScriptedSessionTransport: OnloHTTPTransport {
    private var steps: [Result<OnloHTTPResponse, OnloError>]
    private var capturedRequests: [URLRequest] = []

    init(steps: [Result<OnloHTTPResponse, OnloError>]) { self.steps = steps }

    func execute(_ request: URLRequest) async throws -> OnloHTTPResponse {
        capturedRequests.append(request)
        if request.url?.path == "/api/widget/conversations" { return emptyInboxResponse() }
        if request.url?.path == "/api/sdk/v1/config" { return delayedMobileConfigResponse() }
        guard !steps.isEmpty else { throw OnloError.transport(code: "unexpected_request") }
        let response = try steps.removeFirst().get()
        return sessionResponseMatchingRequest(response, request: request)
    }

    func requests() -> [URLRequest] { capturedRequests }
}

private func emptyInboxResponse() -> OnloHTTPResponse {
    OnloHTTPResponse(statusCode: 200, body: Data("{\"conversations\":[]}".utf8))
}

private func waitUntil(
    timeoutNanoseconds: UInt64 = 2_000_000_000,
    pollIntervalNanoseconds: UInt64 = 10_000_000,
    condition: @escaping @Sendable () async -> Bool
) async -> Bool {
    var elapsed: UInt64 = 0
    while !(await condition()) {
        guard elapsed < timeoutNanoseconds else { return false }
        let interval = min(pollIntervalNanoseconds, timeoutNanoseconds - elapsed)
        try? await Task.sleep(nanoseconds: interval)
        elapsed += interval
    }
    return true
}

private func isConfigurationFixture(_ response: OnloHTTPResponse) -> Bool {
    if response.statusCode == 304 { return true }
    if (try? OnloResponseDecoder.envelope(MobileConfig.self, from: response)) != nil { return true }
    if let failure = try? JSONDecoder().decode(APIFailure.self, from: response.body) {
        return failure.error.code == .configUnavailable || failure.error.code == .sessionExpired
    }
    if (try? OnloResponseDecoder.envelope(SessionResult.self, from: response)) != nil { return false }
    if (try? OnloResponseDecoder.envelope(PushTokenResult.self, from: response)) != nil { return false }
    if let object = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any],
       object["conversation"] != nil || object["conversations"] != nil {
        return false
    }
    return true
}

private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date: Date

    init(_ date: Date) { self.date = date }
    func now() -> Date { lock.withLock { date } }
    func advance(by milliseconds: Int) { lock.withLock { date = date.addingTimeInterval(Double(milliseconds) / 1_000) } }
}
