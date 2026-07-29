import Foundation
import XCTest
@_spi(FrameworkBridge) @testable import OnloSDK

final class MessengerSecurityTests: XCTestCase {
    func testEncryptedInboxIndexSurvivesSDKRecreationAndOfflineRefresh() async throws {
        let credentials = InMemoryCredentialStore()
        let store = InMemoryOwnerScopedStore()
        let firstSDK = OnloSDK(
            credentialStore: credentials,
            ownerStore: store,
            transport: PersistentInboxTransport(inboxIsAvailable: true),
            hostAppIdentifier: "com.example.host",
            lifecycleBindingEnabled: false
        )
        let configuration = OnloSDK.Configuration(
            sdkKey: "public-key",
            appIdentifier: "com.example.host",
            apiBaseURL: URL(string: "https://sdk.example.test")!
        )
        _ = try await firstSDK.initialize(configuration)
        let fresh = try await firstSDK.messengerInboxResult()
        guard case .ready(let freshConversations) = fresh else {
            return XCTFail("The first authorised inbox must be fresh")
        }
        XCTAssertEqual(freshConversations.map(\.id), ["conversation-cached"])

        let recreatedSDK = OnloSDK(
            credentialStore: credentials,
            ownerStore: store,
            transport: PersistentInboxTransport(inboxIsAvailable: false),
            hostAppIdentifier: "com.example.host",
            lifecycleBindingEnabled: false
        )
        _ = try await recreatedSDK.initialize(configuration)
        let offline = try await recreatedSDK.messengerInboxResult()
        guard case .stale(let cachedConversations) = offline else {
            return XCTFail("An offline refresh must return the encrypted owner-scoped inbox")
        }
        XCTAssertEqual(cachedConversations, freshConversations)
    }

    func testExpiredInboxBearerRefreshesOnceAndRetriesWithRotatedSession() async throws {
        let transport = ExpiredInboxBearerTransport()
        let sdk = OnloSDK(
            credentialStore: InMemoryCredentialStore(),
            ownerStore: InMemoryOwnerScopedStore(),
            transport: transport,
            hostAppIdentifier: "com.example.host",
            lifecycleBindingEnabled: false
        )
        _ = try await sdk.initialize(OnloSDK.Configuration(
            sdkKey: "public-key",
            appIdentifier: "com.example.host",
            apiBaseURL: URL(string: "https://sdk.example.test")!
        ))

        let result = try await sdk.messengerInboxResult()
        guard case .ready(let conversations) = result else {
            return XCTFail("The rotated bearer retry must return a fresh inbox")
        }
        XCTAssertEqual(conversations.map(\.id), ["conversation-after-refresh"])
        let counts = await transport.requestCounts()
        let authorizations = await transport.inboxAuthorizationHeaders()
        XCTAssertEqual(counts.session, 2)
        XCTAssertEqual(counts.inbox, 2)
        XCTAssertEqual(authorizations, [
            "Bearer token-1",
            "Bearer token-2",
        ])
    }

    func testAuthorisedHistoricalInboxAcceptsPriorSessionMetadata() async throws {
        let sdk = OnloSDK(
            credentialStore: InMemoryCredentialStore(),
            ownerStore: InMemoryOwnerScopedStore(),
            transport: HistoricalConversationTransport(),
            hostAppIdentifier: "com.example.host"
        )
        _ = try await sdk.initialize(OnloSDK.Configuration(
            sdkKey: "public-key",
            appIdentifier: "com.example.host",
            apiBaseURL: URL(string: "https://sdk.example.test")!
        ))

        let inbox = try await sdk.messengerInbox()
        XCTAssertEqual(inbox.map(\.id), ["conversation-history"])
        XCTAssertEqual(inbox.first?.sessionId, "session-history")
    }

    func testAuthorisedHistoricalTranscriptPersistsForCurrentOwner() async throws {
        let store = InMemoryOwnerScopedStore()
        let credentialStore = InMemoryCredentialStore()
        let sdk = OnloSDK(
            credentialStore: credentialStore,
            ownerStore: store,
            transport: HistoricalConversationTransport(),
            hostAppIdentifier: "com.example.host"
        )
        _ = try await sdk.initialize(OnloSDK.Configuration(
            sdkKey: "public-key",
            appIdentifier: "com.example.host",
            apiBaseURL: URL(string: "https://sdk.example.test")!
        ))

        let transcript = try await sdk.messengerTranscript(conversationId: "conversation-history")
        XCTAssertEqual(transcript?.conversation.id, "conversation-history")

        let protectedState = try await credentialStore.loadState()
        let scope = try XCTUnwrap(protectedState.credential?.ownerScope)
        let persistedTranscript = try await store.transcript(conversationId: "conversation-history", for: scope)
        XCTAssertEqual(persistedTranscript?.conversation.id, "conversation-history")
    }

    func testAuthorisedTranscriptUsesOwnerScopedCacheAfterFirstNetworkFetch() async throws {
        let transport = HistoricalConversationTransport()
        let sdk = OnloSDK(
            credentialStore: InMemoryCredentialStore(),
            ownerStore: InMemoryOwnerScopedStore(),
            transport: transport,
            hostAppIdentifier: "com.example.host",
            lifecycleBindingEnabled: false
        )
        _ = try await sdk.initialize(OnloSDK.Configuration(
            sdkKey: "public-key",
            appIdentifier: "com.example.host",
            apiBaseURL: URL(string: "https://sdk.example.test")!
        ))

        let first = try await sdk.messengerTranscript(conversationId: "conversation-history")
        let second = try await sdk.messengerTranscript(conversationId: "conversation-history")
        let requestCount = await transport.transcriptRequestCount()

        XCTAssertEqual(first, second)
        XCTAssertEqual(requestCount, 1)
    }

    func testAnonymousPushAuthorisesAndPersistsItsConversationTranscript() async throws {
        let store = InMemoryOwnerScopedStore()
        let credentialStore = InMemoryCredentialStore()
        let sdk = OnloSDK(
            credentialStore: credentialStore,
            ownerStore: store,
            transport: HistoricalConversationTransport(),
            hostAppIdentifier: "com.example.host"
        )
        _ = try await sdk.initialize(OnloSDK.Configuration(
            sdkKey: "public-key",
            appIdentifier: "com.example.host",
            apiBaseURL: URL(string: "https://sdk.example.test")!
        ))

        let result = try await sdk.handlePushNotification(PushNotificationPayload(
            conversationId: "conversation-history",
            messageId: "message-history",
            notificationType: .messageAvailable
        ))
        XCTAssertEqual(result, .handled(.messenger(conversationId: "conversation-history")))
        let protectedState = try await credentialStore.loadState()
        let scope = try XCTUnwrap(protectedState.credential?.ownerScope)
        let persistedTranscript = try await store.transcript(conversationId: "conversation-history", for: scope)
        XCTAssertEqual(persistedTranscript?.conversation.id, "conversation-history")
    }

    func testOfflineComposerDurablyQueuesTextForRestoredOwner() async throws {
        let owner = OwnerScope(kind: .anonymous)
        let credential = StoredSessionCredential(
            installationId: "installation-1",
            generation: 1,
            proposedCredential: "credential-1",
            identityClass: .anonymous,
            ownerScope: owner
        )
        let store = InMemoryOwnerScopedStore()
        let sdk = OnloSDK(
            credentialStore: InMemoryCredentialStore(credential),
            ownerStore: store,
            transport: OfflineTransport(),
            hostAppIdentifier: "com.example.host"
        )
        _ = try await sdk.initialize(OnloSDK.Configuration(
            sdkKey: "public-key",
            appIdentifier: "com.example.host",
            apiBaseURL: URL(string: "https://sdk.example.test")!
        ))
        let initialState = await sdk.currentState()
        XCTAssertEqual(initialState, .offlineReady)

        _ = try await sdk.sendMessage(message: "synthetic offline message")
        let entries = try await store.outboxEntries(for: owner)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].state, .queued)
        XCTAssertEqual(entries[0].ownerScope, owner)
    }

    func testIdentifyInvalidatesRegisteredMessengerBeforeReplacingAnonymousScope() async throws {
        let transport = IdentityBoundaryTransport()
        let sdk = OnloSDK(
            credentialStore: InMemoryCredentialStore(),
            ownerStore: InMemoryOwnerScopedStore(),
            transport: transport,
            hostAppIdentifier: "com.example.host"
        )
        _ = try await sdk.initialize(OnloSDK.Configuration(
            sdkKey: "public-key",
            appIdentifier: "com.example.host",
            apiBaseURL: URL(string: "https://sdk.example.test")!
        ))
        let probe = await MainActor.run { InvalidationProbe() }
        let registration = await sdk.registerMessengerPresentationInvalidator { @MainActor in
            probe.invalidated = true
        }

        _ = try await sdk.loginIdentifiedUser(userJwt: "header.payload.signature")
        let wasInvalidated = await MainActor.run { probe.invalidated }
        XCTAssertTrue(wasInvalidated)
        await sdk.unregisterMessengerPresentationInvalidator(registration)
    }

    func testAPNsTokenRegistersForAnonymousAndReregistersAfterIdentify() async throws {
        let transport = IdentityBoundaryTransport()
        let sdk = OnloSDK(
            credentialStore: InMemoryCredentialStore(),
            pushIntentStore: InMemoryPushIntentStore(),
            ownerStore: InMemoryOwnerScopedStore(),
            transport: transport,
            hostAppIdentifier: "com.example.host"
        )
        _ = try await sdk.initialize(OnloSDK.Configuration(
            sdkKey: "public-key",
            appIdentifier: "com.example.host",
            apiBaseURL: URL(string: "https://sdk.example.test")!
        ))
        let queued = try await sdk.setAPNsPushToken(Data(repeating: 0xAB, count: 32))
        XCTAssertEqual(queued, .registered)
        let anonymousPushRequests = await transport.pushRequestCount()
        XCTAssertEqual(anonymousPushRequests, 1)

        _ = try await sdk.loginIdentifiedUser(userJwt: "header.payload.signature")
        let identifiedRegistrationCompleted = await waitUntil {
            await transport.pushRequestCount() == 2
        }
        XCTAssertTrue(identifiedRegistrationCompleted)
        let identifiedPushRequests = await transport.pushRequestCount()
        XCTAssertEqual(identifiedPushRequests, 2)
    }

    func testUnreadIsHiddenForAnonymousAndPublishedFromIdentifiedTotal() async throws {
        let sdk = OnloSDK(
            credentialStore: InMemoryCredentialStore(),
            ownerStore: InMemoryOwnerScopedStore(),
            transport: UnreadObservationTransport(),
            hostAppIdentifier: "com.example.host"
        )
        _ = try await sdk.initialize(OnloSDK.Configuration(
            sdkKey: "public-key",
            appIdentifier: "com.example.host",
            apiBaseURL: URL(string: "https://sdk.example.test")!
        ))

        let states = await sdk.observeFrameworkState()
        var iterator = states.makeAsyncIterator()
        let firstSnapshot = await iterator.next()
        let snapshot = try XCTUnwrap(firstSnapshot)
        XCTAssertEqual(snapshot.state, .anonymousReady)

        let inbox = try await sdk.messengerInbox()
        XCTAssertEqual(inbox.count, 2)
        XCTAssertEqual(inbox.map(\.unreadCount), [0, 0])
        XCTAssertNil(snapshot.unreadCount)

        _ = try await sdk.loginIdentifiedUser(userJwt: "header.payload.signature")
        _ = try await sdk.messengerInbox()
        let identifiedStates = await sdk.observeFrameworkState()
        var identifiedIterator = identifiedStates.makeAsyncIterator()
        let identifiedSnapshot = await identifiedIterator.next()
        XCTAssertEqual(identifiedSnapshot?.state, .identifiedReady)
        XCTAssertEqual(identifiedSnapshot?.unreadCount, 3)
    }

    func testTranscriptFetchDoesNotAcknowledgeUntilPresenterReportsRenderedMessage() async throws {
        let transport = ReadAcknowledgementTransport()
        let sdk = OnloSDK(
            credentialStore: InMemoryCredentialStore(),
            ownerStore: InMemoryOwnerScopedStore(),
            transport: transport,
            hostAppIdentifier: "com.example.host"
        )
        _ = try await sdk.initialize(OnloSDK.Configuration(
            sdkKey: "public-key",
            appIdentifier: "com.example.host",
            apiBaseURL: URL(string: "https://sdk.example.test")!
        ))
        let initialStates = await sdk.observeFrameworkState()
        var initialIterator = initialStates.makeAsyncIterator()
        let initialSnapshot = await initialIterator.next()
        XCTAssertEqual(initialSnapshot?.state, .anonymousReady)

        _ = try await sdk.messengerTranscript(conversationId: "conversation-1")
        let readsBeforeRender = await transport.readRequestCount()
        XCTAssertEqual(readsBeforeRender, 0)

        try await sdk.acknowledgeRenderedConversation(
            conversationId: "conversation-1",
            throughMessageId: "message-1"
        )
        let readsAfterRender = await transport.readRequestCount()
        let readBody = await transport.lastReadBody()
        XCTAssertEqual(readsAfterRender, 1)
        XCTAssertEqual(readBody, #"{"throughMessageId":"message-1"}"#)
        let frameworkStates = await sdk.observeFrameworkState()
        var frameworkIterator = frameworkStates.makeAsyncIterator()
        let convergedState = await frameworkIterator.next()
        XCTAssertNil(convergedState?.unreadCount)
    }

    func testOlderInboxResponseCannotOverwriteNewerObservation() async throws {
        let transport = OutOfOrderInboxTransport()
        let sdk = OnloSDK(
            credentialStore: InMemoryCredentialStore(),
            ownerStore: InMemoryOwnerScopedStore(),
            transport: transport,
            hostAppIdentifier: "com.example.host",
            lifecycleBindingEnabled: false
        )
        _ = try await sdk.initialize(OnloSDK.Configuration(
            sdkKey: "public-key",
            appIdentifier: "com.example.host",
            apiBaseURL: URL(string: "https://sdk.example.test")!
        ))
        _ = try await sdk.loginIdentifiedUser(userJwt: "header.payload.signature")

        let older = Task { try await sdk.messengerInbox() }
        await transport.waitForFirstList()
        let newer = Task { try await sdk.messengerInbox() }
        await transport.waitForSecondList()
        await transport.releaseSecondList()
        let newerInbox = try await newer.value
        await transport.releaseFirstList()
        let olderInbox = try await older.value
        let states = await sdk.observeFrameworkState()
        var iterator = states.makeAsyncIterator()
        let snapshot = await iterator.next()

        XCTAssertEqual(newerInbox.first?.title, "newer")
        XCTAssertEqual(olderInbox, newerInbox)
        XCTAssertEqual(snapshot?.unreadCount, 0)
    }

    func testSuccessfulReadAcknowledgementFencesOlderInboxResponse() async throws {
        let transport = OutOfOrderInboxTransport()
        let sdk = OnloSDK(
            credentialStore: InMemoryCredentialStore(),
            ownerStore: InMemoryOwnerScopedStore(),
            transport: transport,
            hostAppIdentifier: "com.example.host",
            lifecycleBindingEnabled: false
        )
        _ = try await sdk.initialize(OnloSDK.Configuration(
            sdkKey: "public-key",
            appIdentifier: "com.example.host",
            apiBaseURL: URL(string: "https://sdk.example.test")!
        ))
        _ = try await sdk.loginIdentifiedUser(userJwt: "header.payload.signature")

        let staleInbox = Task { try await sdk.messengerInbox() }
        await transport.waitForFirstList()
        let acknowledgement = Task {
            try await sdk.acknowledgeRenderedConversation(
                conversationId: "conversation-1",
                throughMessageId: "message-1"
            )
        }
        await transport.waitForSecondList()
        await transport.releaseSecondList()
        try await acknowledgement.value
        await transport.releaseFirstList()
        let staleResult = try await staleInbox.value
        let states = await sdk.observeFrameworkState()
        var iterator = states.makeAsyncIterator()
        let snapshot = await iterator.next()
        let readRequestCount = await transport.readRequestCount()

        XCTAssertEqual(staleResult.first?.title, "newer")
        XCTAssertEqual(snapshot?.unreadCount, 0)
        XCTAssertEqual(readRequestCount, 1)
    }

    func testSameConversationTranscriptObservationsSerializeBeforeTransport() async throws {
        let transport = SerializedTranscriptTransport()
        let store = InMemoryOwnerScopedStore()
        let sdk = OnloSDK(
            credentialStore: InMemoryCredentialStore(),
            ownerStore: store,
            transport: transport,
            hostAppIdentifier: "com.example.host",
            lifecycleBindingEnabled: false
        )
        _ = try await sdk.initialize(OnloSDK.Configuration(
            sdkKey: "public-key",
            appIdentifier: "com.example.host",
            apiBaseURL: URL(string: "https://sdk.example.test")!
        ))

        let first = Task { try await sdk.messengerTranscript(conversationId: "conversation-1") }
        await transport.waitForFirstTranscript()
        let second = Task { try await sdk.messengerTranscript(conversationId: "conversation-1") }
        await Task.yield()
        let requestsBeforeRelease = await transport.transcriptRequestCount()
        XCTAssertEqual(requestsBeforeRelease, 1)
        await transport.releaseFirstTranscript()
        _ = try await first.value
        await transport.waitForSecondTranscript()
        await transport.releaseSecondTranscript()
        let finalTranscript = try await second.value
        let finalRequestCount = await transport.transcriptRequestCount()

        XCTAssertEqual(finalTranscript?.messages.map(\.id), ["newer-message"])
        XCTAssertEqual(finalRequestCount, 2)
    }

    func testNormalSessionRecoveryConsumesPushFreshBearerGateWithoutExtraResume() async throws {
        let owner = OwnerScope(kind: .identified)
        let credentials = InMemoryCredentialStore(StoredSessionCredential(installationId: "installation-1", generation: 1, proposedCredential: "credential-1", identityClass: .identified, ownerScope: owner))
        let push = InMemoryPushIntentStore()
        let transport = FreshBearerPushTransport()
        try await push.save(ProtectedPushIntent(ownerScope: owner, action: .register, token: String(repeating: "a", count: 64), requiresFreshBearer: true))
        let sdk = OnloSDK(credentialStore: credentials, pushIntentStore: push, ownerStore: InMemoryOwnerScopedStore(), transport: transport, hostAppIdentifier: "com.example.host")
        _ = try await sdk.initialize(OnloSDK.Configuration(sdkKey: "public-key", appIdentifier: "com.example.host", apiBaseURL: URL(string: "https://sdk.example.test")!))
        let pushRecovered = await waitUntil {
            let paths = await transport.paths()
            guard paths.filter({ $0 == "/api/sdk/v1/push-token" }).count == 1 else { return false }
            do {
                return try await push.load()?.requiresFreshBearer == false
            } catch {
                return false
            }
        }
        XCTAssertTrue(pushRecovered)
        let paths = await transport.paths()
        XCTAssertEqual(paths.filter { $0 == "/api/sdk/v1/session" }.count, 1)
        XCTAssertEqual(paths.filter { $0 == "/api/sdk/v1/push-token" }.count, 1)
        let storedPushIntent = try await push.load()
        let pushIntent = try XCTUnwrap(storedPushIntent)
        XCTAssertFalse(pushIntent.requiresFreshBearer)
    }
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

private actor PersistentInboxTransport: OnloHTTPTransport {
    private let inboxIsAvailable: Bool
    private var sessionCount = 0

    init(inboxIsAvailable: Bool) {
        self.inboxIsAvailable = inboxIsAvailable
    }

    func execute(_ request: URLRequest) async throws -> OnloHTTPResponse {
        switch request.url?.path {
        case "/api/sdk/v1/session":
            sessionCount += 1
            let generation: Int
            if let body = request.httpBody,
               let session = try? JSONDecoder().decode(SessionRequest.self, from: body),
               case let .resume(_, expectedGeneration, _, _) = session.operation {
                generation = expectedGeneration + 1
            } else {
                generation = 1
            }
            return messengerSessionResponse(request, json: """
            {"requestId":"synthetic","serverTime":"2026-07-21T10:00:00.000Z","protocolVersion":1,"minimumProtocolVersion":1,"ok":true,"result":{"sessionId":"session-\(generation)","chatToken":"token-\(generation)","installationId":"installation-1","generation":\(generation),"proposedCredential":"credential-\(generation)","identityClass":"anonymous","publicationState":"testing","attestationState":"not_required","configRevision":"revision-1","configSchemaVersion":1,"configEtag":"etag-1"}}
            """)
        case "/api/widget/conversations":
            guard inboxIsAvailable else {
                return OnloHTTPResponse(statusCode: 503, body: Data("{}".utf8))
            }
            return OnloHTTPResponse(statusCode: 200, body: Data("""
            {"conversations":[{"id":"conversation-cached","sessionId":"historical-session","title":"synthetic","unread":false,"unreadCount":0,"status":"open","updatedAt":"2026-07-21T10:00:00.000Z","messageCount":1,"lastMessageRole":"assistant"}],"totalUnreadCount":0}
            """.utf8))
        default:
            return OnloHTTPResponse(statusCode: 503, body: Data("{}".utf8))
        }
    }
}

private actor ExpiredInboxBearerTransport: OnloHTTPTransport {
    private var sessionCount = 0
    private var inboxCount = 0
    private var inboxAuthorizations: [String] = []

    func execute(_ request: URLRequest) async throws -> OnloHTTPResponse {
        switch request.url?.path {
        case "/api/sdk/v1/session":
            sessionCount += 1
            return messengerSessionResponse(request, json: """
            {"requestId":"synthetic","serverTime":"2026-07-21T10:00:00.000Z","protocolVersion":1,"minimumProtocolVersion":1,"ok":true,"result":{"sessionId":"session-\(sessionCount)","chatToken":"token-\(sessionCount)","installationId":"installation-1","generation":\(sessionCount),"proposedCredential":"credential-\(sessionCount)","identityClass":"anonymous","publicationState":"testing","attestationState":"not_required","configRevision":"revision-1","configSchemaVersion":1,"configEtag":"etag-1"}}
            """)
        case "/api/widget/conversations":
            inboxCount += 1
            inboxAuthorizations.append(request.value(forHTTPHeaderField: "Authorization") ?? "")
            if inboxCount == 1 {
                return OnloHTTPResponse(statusCode: 401, body: Data("{\"error\":\"unauthorized\"}".utf8))
            }
            return OnloHTTPResponse(statusCode: 200, body: Data("""
            {"conversations":[{"id":"conversation-after-refresh","sessionId":"historical-session","title":"synthetic","unread":false,"unreadCount":0,"status":"open","updatedAt":"2026-07-21T10:00:00.000Z","messageCount":1,"lastMessageRole":"assistant"}],"totalUnreadCount":0}
            """.utf8))
        default:
            return OnloHTTPResponse(statusCode: 503, body: Data("{}".utf8))
        }
    }

    func requestCounts() -> (session: Int, inbox: Int) {
        (sessionCount, inboxCount)
    }

    func inboxAuthorizationHeaders() -> [String] {
        inboxAuthorizations
    }
}

private actor OfflineTransport: OnloHTTPTransport {
    func execute(_ request: URLRequest) async throws -> OnloHTTPResponse {
        throw OnloError.transport(code: "network_unavailable")
    }
}

@MainActor
private final class InvalidationProbe {
    var invalidated = false
}

private actor IdentityBoundaryTransport: OnloHTTPTransport {
    private var sessionCount = 0
    private var pushCount = 0

    func execute(_ request: URLRequest) async throws -> OnloHTTPResponse {
        switch request.url?.path {
        case "/api/sdk/v1/session":
            sessionCount += 1
            let identity = sessionCount == 1 ? "anonymous" : "identified"
            let session = sessionCount == 1 ? "session-anonymous" : "session-identified"
            let credential = sessionCount == 1 ? "credential-1" : "credential-2"
            return messengerSessionResponse(request, json: """
            {"requestId":"synthetic","serverTime":"2026-07-21T10:00:00.000Z","protocolVersion":1,"minimumProtocolVersion":1,"ok":true,"result":{"sessionId":"\(session)","chatToken":"opaque-test-token","installationId":"installation-1","generation":\(sessionCount),"proposedCredential":"\(credential)","identityClass":"\(identity)","publicationState":"testing","attestationState":"not_required","configRevision":"revision-1","configSchemaVersion":1,"configEtag":"etag-1"}}
            """)
        case "/api/sdk/v1/push-token":
            pushCount += 1
            return OnloHTTPResponse(statusCode: 200, body: Data("""
            {"requestId":"synthetic","serverTime":"2026-07-21T10:00:00.000Z","protocolVersion":1,"minimumProtocolVersion":1,"ok":true,"result":{"state":"active","provider":"apns","environment":"sandbox","fingerprint":"redacted","registeredAt":"2026-07-21T10:00:00.000Z"}}
            """.utf8))
        default:
            return OnloHTTPResponse(statusCode: 503, body: Data("{}".utf8))
        }
    }

    func pushRequestCount() -> Int { pushCount }
}

private actor UnreadObservationTransport: OnloHTTPTransport {
    private var sessionCount = 0

    func execute(_ request: URLRequest) async throws -> OnloHTTPResponse {
        switch request.url?.path {
        case "/api/sdk/v1/session":
            sessionCount += 1
            let identity = sessionCount == 1 ? "anonymous" : "identified"
            let session = sessionCount == 1 ? "session-current" : "session-identified"
            return messengerSessionResponse(request, json: """
            {"requestId":"synthetic","serverTime":"2026-07-21T10:00:00.000Z","protocolVersion":1,"minimumProtocolVersion":1,"ok":true,"result":{"sessionId":"\(session)","chatToken":"opaque-test-token","installationId":"installation-1","generation":\(sessionCount),"proposedCredential":"credential-\(sessionCount)","identityClass":"\(identity)","publicationState":"testing","attestationState":"not_required","configRevision":"revision-1","configSchemaVersion":1,"configEtag":"etag-1"}}
            """)
        case "/api/widget/conversations":
            let session = sessionCount == 1 ? "session-current" : "session-identified"
            return OnloHTTPResponse(statusCode: 200, body: Data("""
            {"conversations":[
              {"id":"conversation-1","sessionId":"\(session)","title":"synthetic","unread":true,"unreadCount":2,"status":"open","updatedAt":"2026-07-21T10:00:00.000Z","messageCount":1,"lastMessageRole":"assistant"},
              {"id":"conversation-2","sessionId":"\(session)","title":"synthetic","unread":true,"unreadCount":1,"status":"open","updatedAt":"2026-07-21T10:00:00.000Z","messageCount":1,"lastMessageRole":"assistant"}
            ],"totalUnreadCount":3}
            """.utf8))
        default:
            return OnloHTTPResponse(statusCode: 503, body: Data("{}".utf8))
        }
    }
}

private actor FreshBearerPushTransport: OnloHTTPTransport {
    private var sessionCount = 0
    private var recordedPaths: [String] = []

    func execute(_ request: URLRequest) async throws -> OnloHTTPResponse {
        let path = request.url?.path ?? ""
        recordedPaths.append(path)
        if path == "/api/sdk/v1/session" {
            sessionCount += 1
            return messengerSessionResponse(request, json: """
            {"requestId":"synthetic","serverTime":"2026-07-21T10:00:00.000Z","protocolVersion":1,"minimumProtocolVersion":1,"ok":true,"result":{"sessionId":"session-\(sessionCount)","chatToken":"opaque-test-token","installationId":"installation-1","generation":\(sessionCount),"proposedCredential":"credential-\(sessionCount)","identityClass":"identified","publicationState":"testing","attestationState":"not_required","configRevision":"revision-1","configSchemaVersion":1,"configEtag":"etag-1"}}
            """)
        }
        if path == "/api/sdk/v1/push-token" {
            return OnloHTTPResponse(statusCode: 200, body: Data("""
            {"requestId":"synthetic","serverTime":"2026-07-21T10:00:00.000Z","protocolVersion":1,"minimumProtocolVersion":1,"ok":true,"result":{"state":"active","provider":"apns","environment":"sandbox","fingerprint":"redacted","registeredAt":"2026-07-21T10:00:00.000Z"}}
            """.utf8))
        }
        return OnloHTTPResponse(statusCode: 503, body: Data("{}".utf8))
    }

    func paths() -> [String] { recordedPaths }
}

private actor ReadAcknowledgementTransport: OnloHTTPTransport {
    private var sessionCount = 0
    private var readBodies: [String] = []

    func execute(_ request: URLRequest) async throws -> OnloHTTPResponse {
        switch (request.httpMethod, request.url?.path) {
        case ("POST", "/api/sdk/v1/session"):
            sessionCount += 1
            let identified = sessionCount > 1
            return messengerSessionResponse(request, json: """
            {"requestId":"synthetic","serverTime":"2026-07-21T10:00:00.000Z","protocolVersion":1,"minimumProtocolVersion":1,"ok":true,"result":{"sessionId":"session-\(sessionCount)","chatToken":"opaque-test-token","installationId":"installation-1","generation":\(sessionCount),"proposedCredential":"credential-\(sessionCount)","identityClass":"\(identified ? "identified" : "anonymous")","publicationState":"testing","attestationState":"not_required","configRevision":"revision-1","configSchemaVersion":1,"configEtag":"etag-1"}}
            """)
        case ("GET", "/api/widget/conversations/conversation-1"):
            return OnloHTTPResponse(statusCode: 200, body: Data("""
            {"conversation":{"id":"conversation-1","sessionId":"historical-session","status":"open","isHumanTakeover":false},"messages":[{"id":"message-1","externalId":null,"role":"assistant","senderType":null,"senderName":null,"senderTeam":null,"text":"synthetic","attachments":[],"timestamp":1}],"sync":{"previousCursor":null,"nextCursor":null,"limit":100}}
            """.utf8))
        case ("PUT", "/api/widget/conversations/conversation-1/read"):
            readBodies.append(String(data: request.httpBody ?? Data(), encoding: .utf8) ?? "")
            return OnloHTTPResponse(statusCode: 200, body: Data("""
            {"conversationId":"conversation-1","readThroughMessageId":"message-1","unread":true,"unreadCount":1}
            """.utf8))
        case ("GET", "/api/widget/conversations"):
            return OnloHTTPResponse(statusCode: 200, body: Data("""
            {"conversations":[],"totalUnreadCount":0}
            """.utf8))
        default:
            return OnloHTTPResponse(statusCode: 503, body: Data("{}".utf8))
        }
    }

    func readRequestCount() -> Int { readBodies.count }
    func lastReadBody() -> String? { readBodies.last }
}

private actor OutOfOrderInboxTransport: OnloHTTPTransport {
    private var sessionCount = 0
    private var listCount = 0
    private var readCount = 0
    private var firstListReached = false
    private var secondListReached = false
    private var firstListWaiters: [CheckedContinuation<Void, Never>] = []
    private var secondListWaiters: [CheckedContinuation<Void, Never>] = []
    private var firstRelease: CheckedContinuation<Void, Never>?
    private var secondRelease: CheckedContinuation<Void, Never>?

    func execute(_ request: URLRequest) async throws -> OnloHTTPResponse {
        switch (request.httpMethod, request.url?.path) {
        case ("POST", "/api/sdk/v1/session"):
            sessionCount += 1
            let identified = sessionCount > 1
            return messengerSessionResponse(request, json: """
            {"requestId":"synthetic","serverTime":"2026-07-21T10:00:00.000Z","protocolVersion":1,"minimumProtocolVersion":1,"ok":true,"result":{"sessionId":"session-\(sessionCount)","chatToken":"opaque-test-token","installationId":"installation-1","generation":\(sessionCount),"proposedCredential":"credential-\(sessionCount)","identityClass":"\(identified ? "identified" : "anonymous")","publicationState":"testing","attestationState":"not_required","configRevision":"revision-1","configSchemaVersion":1,"configEtag":"etag-1"}}
            """)
        case ("PUT", "/api/widget/conversations/conversation-1/read"):
            readCount += 1
            return OnloHTTPResponse(statusCode: 200, body: Data("""
            {"conversationId":"conversation-1","readThroughMessageId":"message-1","unread":false,"unreadCount":0}
            """.utf8))
        case ("GET", "/api/widget/conversations"):
            listCount += 1
            if listCount == 1 {
                firstListReached = true
                firstListWaiters.forEach { $0.resume() }
                firstListWaiters.removeAll()
                await withCheckedContinuation { firstRelease = $0 }
                return list(title: "older", unread: 2)
            }
            secondListReached = true
            secondListWaiters.forEach { $0.resume() }
            secondListWaiters.removeAll()
            await withCheckedContinuation { secondRelease = $0 }
            return list(title: "newer", unread: 0)
        default:
            return OnloHTTPResponse(statusCode: 503, body: Data("{}".utf8))
        }
    }

    func waitForFirstList() async {
        guard !firstListReached else { return }
        await withCheckedContinuation { firstListWaiters.append($0) }
    }

    func waitForSecondList() async {
        guard !secondListReached else { return }
        await withCheckedContinuation { secondListWaiters.append($0) }
    }

    func releaseFirstList() {
        firstRelease?.resume()
        firstRelease = nil
    }

    func releaseSecondList() {
        secondRelease?.resume()
        secondRelease = nil
    }

    func readRequestCount() -> Int { readCount }

    private func list(title: String, unread: Int) -> OnloHTTPResponse {
        OnloHTTPResponse(statusCode: 200, body: Data("""
        {"conversations":[{"id":"conversation-1","sessionId":"historical-session","title":"\(title)","unread":\(unread > 0),"unreadCount":\(unread),"status":"open","updatedAt":"2026-07-21T10:00:00.000Z","messageCount":1,"lastMessageRole":"assistant"}],"totalUnreadCount":\(unread)}
        """.utf8))
    }
}

private actor SerializedTranscriptTransport: OnloHTTPTransport {
    private var transcriptCount = 0
    private var firstReached = false
    private var secondReached = false
    private var firstWaiters: [CheckedContinuation<Void, Never>] = []
    private var secondWaiters: [CheckedContinuation<Void, Never>] = []
    private var firstRelease: CheckedContinuation<Void, Never>?
    private var secondRelease: CheckedContinuation<Void, Never>?

    func execute(_ request: URLRequest) async throws -> OnloHTTPResponse {
        switch request.url?.path {
        case "/api/sdk/v1/session":
            return messengerSessionResponse(request, json: """
            {"requestId":"synthetic","serverTime":"2026-07-21T10:00:00.000Z","protocolVersion":1,"minimumProtocolVersion":1,"ok":true,"result":{"sessionId":"session-current","chatToken":"opaque-test-token","installationId":"installation-1","generation":1,"proposedCredential":"credential-1","identityClass":"anonymous","publicationState":"testing","attestationState":"not_required","configRevision":"revision-1","configSchemaVersion":1,"configEtag":"etag-1"}}
            """)
        case "/api/widget/conversations/conversation-1":
            transcriptCount += 1
            if transcriptCount == 1 {
                firstReached = true
                firstWaiters.forEach { $0.resume() }
                firstWaiters.removeAll()
                await withCheckedContinuation { firstRelease = $0 }
                return transcript(messageId: "older-message", timestamp: 1)
            }
            secondReached = true
            secondWaiters.forEach { $0.resume() }
            secondWaiters.removeAll()
            await withCheckedContinuation { secondRelease = $0 }
            return transcript(messageId: "newer-message", timestamp: 2)
        default:
            return OnloHTTPResponse(statusCode: 503, body: Data("{}".utf8))
        }
    }

    func waitForFirstTranscript() async {
        guard !firstReached else { return }
        await withCheckedContinuation { firstWaiters.append($0) }
    }

    func waitForSecondTranscript() async {
        guard !secondReached else { return }
        await withCheckedContinuation { secondWaiters.append($0) }
    }

    func releaseFirstTranscript() {
        firstRelease?.resume()
        firstRelease = nil
    }

    func releaseSecondTranscript() {
        secondRelease?.resume()
        secondRelease = nil
    }

    func transcriptRequestCount() -> Int { transcriptCount }

    private func transcript(messageId: String, timestamp: Int) -> OnloHTTPResponse {
        OnloHTTPResponse(statusCode: 200, body: Data("""
        {"conversation":{"id":"conversation-1","sessionId":"historical-session","status":"open","isHumanTakeover":false},"messages":[{"id":"\(messageId)","externalId":null,"role":"assistant","senderType":null,"senderName":null,"senderTeam":null,"text":"synthetic","attachments":[],"timestamp":\(timestamp)}],"sync":{"previousCursor":null,"nextCursor":null,"limit":100}}
        """.utf8))
    }
}

private actor HistoricalConversationTransport: OnloHTTPTransport {
    private var transcriptRequests = 0

    func execute(_ request: URLRequest) async throws -> OnloHTTPResponse {
        switch request.url?.path {
        case "/api/sdk/v1/session":
            return messengerSessionResponse(request, json: """
            {"requestId":"synthetic","serverTime":"2026-07-21T10:00:00.000Z","protocolVersion":1,"minimumProtocolVersion":1,"ok":true,"result":{"sessionId":"session-current","chatToken":"opaque-test-token","installationId":"installation-1","generation":1,"proposedCredential":"credential-1","identityClass":"anonymous","publicationState":"testing","attestationState":"not_required","configRevision":"revision-1","configSchemaVersion":1,"configEtag":"etag-1"}}
            """)
        case "/api/widget/conversations":
            return OnloHTTPResponse(statusCode: 200, body: Data("""
            {"conversations":[{"id":"conversation-history","sessionId":"session-history","title":"synthetic","unread":true,"unreadCount":1,"status":"open","updatedAt":"2026-07-21T10:00:00.000Z","messageCount":1,"lastMessageRole":"assistant"}],"totalUnreadCount":1}
            """.utf8))
        case "/api/widget/conversations/conversation-history":
            transcriptRequests += 1
            return OnloHTTPResponse(statusCode: 200, body: Data("""
            {"conversation":{"id":"conversation-history","sessionId":"session-history","status":"open","isHumanTakeover":false},"messages":[{"id":"message-history","externalId":null,"role":"assistant","senderType":null,"senderName":null,"senderTeam":null,"text":"synthetic","attachments":[],"timestamp":1}],"sync":{"previousCursor":null,"nextCursor":null,"limit":100}}
            """.utf8))
        default:
            return OnloHTTPResponse(statusCode: 503, body: Data("{}".utf8))
        }
    }

    func transcriptRequestCount() -> Int { transcriptRequests }

    private func response(_ json: String) -> OnloHTTPResponse {
        OnloHTTPResponse(statusCode: 200, body: Data(json.utf8))
    }
}

private func messengerSessionResponse(_ request: URLRequest, json: String) -> OnloHTTPResponse {
    let fallback = OnloHTTPResponse(statusCode: 200, body: Data(json.utf8))
    guard let body = request.httpBody,
          let session = try? JSONDecoder().decode(SessionRequest.self, from: body),
          var envelope = try? JSONSerialization.jsonObject(with: fallback.body) as? [String: Any],
          var result = envelope["result"] as? [String: Any] else {
        return fallback
    }

    let proposedCredential: String
    switch session.operation {
    case let .bootstrap(_, credential, _): proposedCredential = credential
    case let .resume(_, _, _, credential), let .identify(_, _, _, credential, _), let .logout(_, _, _, credential): proposedCredential = credential
    }
    result["installationId"] = session.client.installationId
    result["proposedCredential"] = proposedCredential
    envelope["result"] = result
    guard let rewrittenBody = try? JSONSerialization.data(withJSONObject: envelope) else { return fallback }
    return OnloHTTPResponse(statusCode: 200, body: rewrittenBody)
}
