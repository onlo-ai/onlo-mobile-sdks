import Foundation
import XCTest
@_spi(FrameworkBridge) @testable import OnloSDK

final class MessengerSecurityTests: XCTestCase {
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

    func testAuthorisedHistoricalPushPersistsAndReturnsRoute() async throws {
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

    func testFrameworkUnreadObservationUsesOnlyAuthorisedConversationTotals() async throws {
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
        XCTAssertEqual(snapshot.unreadCount, 3)

        // A repeat list fetch has the same total and must not manufacture a
        // separate framework state. The total itself contains no content.
        let inbox = try await sdk.messengerInbox()
        XCTAssertEqual(inbox.map(\.unreadCount).reduce(0, +), 3)

        _ = try await sdk.loginIdentifiedUser(userJwt: "header.payload.signature")
        let boundarySnapshot = await iterator.next()
        let boundary = try XCTUnwrap(boundarySnapshot)
        XCTAssertNil(boundary.unreadCount)
    }

    func testNormalOwnerFreshBearerIntentUsesOneResumeThenOnePush() async throws {
        let owner = OwnerScope(kind: .anonymous)
        let credentials = InMemoryCredentialStore(StoredSessionCredential(installationId: "installation-1", generation: 1, proposedCredential: "credential-1", identityClass: .anonymous, ownerScope: owner))
        let push = InMemoryPushIntentStore()
        let transport = FreshBearerPushTransport()
        try await push.save(ProtectedPushIntent(ownerScope: owner, action: .register, token: String(repeating: "a", count: 64), requiresFreshBearer: true))
        let sdk = OnloSDK(credentialStore: credentials, pushIntentStore: push, ownerStore: InMemoryOwnerScopedStore(), transport: transport, hostAppIdentifier: "com.example.host")
        _ = try await sdk.initialize(OnloSDK.Configuration(sdkKey: "public-key", appIdentifier: "com.example.host", apiBaseURL: URL(string: "https://sdk.example.test")!))
        let paths = await transport.paths()
        XCTAssertEqual(paths.filter { $0 == "/api/sdk/v1/session" }.count, 2) // restore + exactly one fresh-bearer Resume
        XCTAssertEqual(paths.filter { $0 == "/api/sdk/v1/push-token" }.count, 1)
        let storedPushIntent = try await push.load()
        let pushIntent = try XCTUnwrap(storedPushIntent)
        XCTAssertFalse(pushIntent.requiresFreshBearer)
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
        default:
            return OnloHTTPResponse(statusCode: 503, body: Data("{}".utf8))
        }
    }
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
            ]}
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
            {"requestId":"synthetic","serverTime":"2026-07-21T10:00:00.000Z","protocolVersion":1,"minimumProtocolVersion":1,"ok":true,"result":{"sessionId":"session-\(sessionCount)","chatToken":"opaque-test-token","installationId":"installation-1","generation":\(sessionCount),"proposedCredential":"credential-\(sessionCount)","identityClass":"anonymous","publicationState":"testing","attestationState":"not_required","configRevision":"revision-1","configSchemaVersion":1,"configEtag":"etag-1"}}
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

private actor HistoricalConversationTransport: OnloHTTPTransport {
    func execute(_ request: URLRequest) async throws -> OnloHTTPResponse {
        switch request.url?.path {
        case "/api/sdk/v1/session":
            return messengerSessionResponse(request, json: """
            {"requestId":"synthetic","serverTime":"2026-07-21T10:00:00.000Z","protocolVersion":1,"minimumProtocolVersion":1,"ok":true,"result":{"sessionId":"session-current","chatToken":"opaque-test-token","installationId":"installation-1","generation":1,"proposedCredential":"credential-1","identityClass":"anonymous","publicationState":"testing","attestationState":"not_required","configRevision":"revision-1","configSchemaVersion":1,"configEtag":"etag-1"}}
            """)
        case "/api/widget/conversations":
            return OnloHTTPResponse(statusCode: 200, body: Data("""
            {"conversations":[{"id":"conversation-history","sessionId":"session-history","title":"synthetic","unread":true,"unreadCount":1,"status":"open","updatedAt":"2026-07-21T10:00:00.000Z","messageCount":1,"lastMessageRole":"assistant"}]}
            """.utf8))
        case "/api/widget/conversations/conversation-history":
            return OnloHTTPResponse(statusCode: 200, body: Data("""
            {"conversation":{"id":"conversation-history","sessionId":"session-history","status":"open","isHumanTakeover":false},"messages":[{"id":"message-history","externalId":null,"role":"assistant","senderType":null,"senderName":null,"senderTeam":null,"text":"synthetic","attachments":[],"timestamp":1}],"sync":{"previousCursor":null,"nextCursor":null,"limit":100}}
            """.utf8))
        default:
            return OnloHTTPResponse(statusCode: 503, body: Data("{}".utf8))
        }
    }

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
