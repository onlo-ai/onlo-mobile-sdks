import Foundation
import XCTest
@testable import OnloSDK

final class SessionConcurrencyTests: XCTestCase {
    // Exact review P1: the refresh reply arrives only AFTER logout has failed.
    func testLateRefreshSuccessCannotUndoFailedLogout() async throws {
        try await checkLateRefresh(logoutFails: true, staleFailure: false, switchAccount: false)
    }

    func testLateRefreshFailureCannotUndoFailedLogout() async throws {
        try await checkLateRefresh(logoutFails: true, staleFailure: true, switchAccount: false)
    }

    func testLateRefreshSuccessCannotUndoSuccessfulLogout() async throws {
        try await checkLateRefresh(logoutFails: false, staleFailure: false, switchAccount: false)
    }

    func testLateRefreshFailureCannotUndoSuccessfulLogout() async throws {
        try await checkLateRefresh(logoutFails: false, staleFailure: true, switchAccount: false)
    }

    func testLateRefreshSuccessCannotReplaceNewAccount() async throws {
        try await checkLateRefresh(logoutFails: false, staleFailure: false, switchAccount: true)
    }

    func testLateRefreshFailureCannotInvalidateNewAccount() async throws {
        try await checkLateRefresh(logoutFails: false, staleFailure: true, switchAccount: true)
    }

    private func checkLateRefresh(logoutFails: Bool, staleFailure: Bool, switchAccount: Bool) async throws {
        let paused = expectation(description: "refresh reached transport")
        let transport = SessionRaceTransport(paused: paused, logoutFails: logoutFails, staleFailure: staleFailure)
        let (sdk, credentials, owner) = try await makeSDK(transport)
        let opening = Task { try await sdk.openConversation("conversation-history") }
        await fulfillment(of: [paused], timeout: 3)
        if logoutFails {
            do { _ = try await sdk.logout(); XCTFail("Synthetic logout must fail") } catch {}
        } else {
            let state = try await sdk.logout()
            XCTAssertEqual(state, .anonymousReady)
        }
        if switchAccount {
            let state = try await sdk.loginIdentifiedUser(userJwt: "e30.eyJzdWIiOiJzeW50aGV0aWMtQiJ9.c2ln")
            XCTAssertEqual(state, .identifiedReady)
        }
        let boundary = try await credentials.loadState()
        let expectedState = await sdk.currentState()
        if logoutFails { XCTAssertEqual(boundary.credential?.logoutPending, true) }
        else { XCTAssertNotEqual(boundary.credential?.ownerScope, owner) }
        await transport.releaseRefresh()
        do { _ = try await opening.value; XCTFail("Old-owner open must be rejected") } catch {}
        let after = try await credentials.loadState()
        let state = await sdk.currentState()
        XCTAssertTrue(after == boundary, "Late success/failure must not rewrite any protected state")
        XCTAssertEqual(state, expectedState)
        let replay = await transport.replayWasExact()
        XCTAssertTrue(replay, "Logout must recover the SAME pending rotation before logging out")
        if logoutFails {
            // A failed logout survives recreation and finishes without restoring A.
            await transport.allowLogout()
            let recreated = OnloSDK(credentialStore: credentials, configStore: InMemoryConfigStore(), pushIntentStore: InMemoryPushIntentStore(), ownerStore: InMemoryOwnerScopedStore(), transport: transport, hostAppIdentifier: "com.example.test", lifecycleBindingEnabled: false)
            let recovered = try await recreated.initialize(configuration)
            XCTAssertEqual(recovered, .anonymousReady)
            let recoveredCredential = try await credentials.loadState().credential
            XCTAssertNotEqual(recoveredCredential?.ownerScope, owner)
        }
    }

    // Exact review P2 ordering: both opens reject the old bearer while the first
    // resume is held. A DIFFERENT second transition would receive session_expired.
    // The fix must prevent that request entirely, and preserve the winning generation.
    func testOverlapping401sCoalesceAndCannotRollBackSuccessfulGeneration() async throws {
        try await checkOverlapping401s(rejectRetry: false)
    }

    func testOverlapping401sStillRetryEachOpenOnlyOnce() async throws {
        try await checkOverlapping401s(rejectRetry: true)
    }

    private func checkOverlapping401s(rejectRetry: Bool) async throws {
        let paused = expectation(description: "first refresh paused")
        let joined = expectation(description: "second caller joined same refresh")
        let logger = SessionRaceLogger(joined: joined)
        let transport = SessionRaceTransport(paused: paused, rejectRetry: rejectRetry)
        let (sdk, credentials, owner) = try await makeSDK(transport, logger: logger)
        let first = Task { try await sdk.openConversation("conversation-history") }
        await fulfillment(of: [paused], timeout: 3)
        let second = Task { try await sdk.openConversation("conversation-history") }
        await fulfillment(of: [joined], timeout: 3)
        await transport.releaseRefresh()
        for (index, task) in [first, second].enumerated() {
            do {
                let intent = try await task.value
                XCTAssertFalse(rejectRetry)
                XCTAssertEqual(intent, .messenger(conversationId: "conversation-history"))
            } catch {
                XCTAssertTrue(rejectRetry)
                XCTAssertEqual(error as? OnloError, .transport(code: "widget_http_401"))
            }
            // In the unfixed implementation, deliver the second resume failure
            // only after the first has successfully committed generation 3.
            if index == 0 { await transport.releaseStaleFailure() }
        }
        let protected = try await credentials.loadState()
        let state = await sdk.currentState()
        let counts = await transport.counts()
        XCTAssertEqual(state, .identifiedReady)
        XCTAssertEqual(protected.credential?.generation, 3)
        XCTAssertEqual(protected.credential?.ownerScope, owner)
        XCTAssertNil(protected.pendingTransition)
        XCTAssertNil(protected.retryGate)
        XCTAssertEqual(counts.rotations, 1)
        XCTAssertEqual(counts.staleRejections, 0)
        XCTAssertEqual(counts.transcripts, 4)
        let events = await logger.events()
        XCTAssertTrue(events.contains { $0.code == "resume_joined" })
        XCTAssertFalse(String(describing: events).contains("synthetic-bearer"))
        XCTAssertFalse(String(describing: events).contains("conversation-history"))
    }

    private var configuration: OnloSDK.Configuration {
        .init(sdkKey: "public-example", appIdentifier: "com.example.test", apiBaseURL: URL(string: "https://sdk.example.test")!)
    }

    private func makeSDK(_ transport: SessionRaceTransport, logger: any SDKLogging = NoopSDKLogger()) async throws -> (OnloSDK, InMemoryCredentialStore, OwnerScope) {
        let owner = OwnerScope(kind: .identified)
        let credentials = InMemoryCredentialStore(.init(installationId: "installation-1", generation: 1, proposedCredential: "synthetic-credential", identityClass: .identified, ownerScope: owner))
        let sdk = OnloSDK(credentialStore: credentials, configStore: InMemoryConfigStore(), pushIntentStore: InMemoryPushIntentStore(), ownerStore: InMemoryOwnerScopedStore(), transport: transport, logger: logger, hostAppIdentifier: "com.example.test", lifecycleBindingEnabled: false)
        _ = try await sdk.initialize(configuration)
        return (sdk, credentials, owner)
    }
}

private actor SessionRaceLogger: SDKLogging {
    let joined: XCTestExpectation
    var recorded: [SDKLogEvent] = []
    init(joined: XCTestExpectation) { self.joined = joined }
    func record(_ event: SDKLogEvent) {
        recorded.append(event)
        if event.code == "resume_joined" { joined.fulfill() }
    }
    func events() -> [SDKLogEvent] { recorded }
}

private actor SessionRaceTransport: OnloHTTPTransport {
    let paused: XCTestExpectation
    var logoutFails: Bool
    let staleFailure: Bool
    let rejectRetry: Bool
    var held: CheckedContinuation<Void, Never>?
    var staleReply: CheckedContinuation<Void, Never>?
    var generation = 1
    var identity = "identified"
    var replay: [String: OnloHTTPResponse] = [:]
    var firstRotation: String?
    var exactReplay = false
    var rotations = 0
    var staleRejections = 0
    var transcripts = 0

    init(paused: XCTestExpectation, logoutFails: Bool = false, staleFailure: Bool = false, rejectRetry: Bool = false) {
        self.paused = paused; self.logoutFails = logoutFails
        self.staleFailure = staleFailure; self.rejectRetry = rejectRetry
    }
    func releaseRefresh() { held?.resume(); held = nil }
    func releaseStaleFailure() { staleReply?.resume(); staleReply = nil }
    func allowLogout() { logoutFails = false }
    func replayWasExact() -> Bool { exactReplay }
    func counts() -> (rotations: Int, staleRejections: Int, transcripts: Int) { (rotations, staleRejections, transcripts) }

    func execute(_ request: URLRequest) async throws -> OnloHTTPResponse {
        if request.url?.path == "/api/sdk/v1/session" {
            let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
            let operation = body["operation"] as! [String: Any]
            let transition = operation["transitionId"] as! String
            let type = operation["type"] as! String
            if let response = replay[transition] {
                if transition == firstRotation { exactReplay = true }
                return response
            }
            if type == "logout", logoutFails { throw URLError(.notConnectedToInternet) }
            guard operation["expectedGeneration"] as? Int == generation else {
                staleRejections += 1
                if type == "resume" { await withCheckedContinuation { staleReply = $0 } }
                return rejection()
            }
            generation += 1
            if type == "logout" { identity = "anonymous" }
            if type == "identify" { identity = "identified" }
            let response = try success(operation: operation)
            replay[transition] = response
            if type == "resume", generation == 3 {
                rotations += 1
                firstRotation = transition
                await withCheckedContinuation { continuation in
                    held = continuation
                    paused.fulfill()
                }
                if staleFailure { return rejection() }
            }
            return response
        }
        if request.url?.path == "/api/widget/conversations/conversation-history" {
            transcripts += 1
            if request.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-bearer-2" || rejectRetry {
                return OnloHTTPResponse(statusCode: 401, body: Data("{}".utf8))
            }
            return OnloHTTPResponse(statusCode: 200, body: Data("""
            {"conversation":{"id":"conversation-history","sessionId":"historical-session","status":"open","isHumanTakeover":false},"messages":[],"sync":{"previousCursor":null,"nextCursor":null,"limit":100}}
            """.utf8))
        }
        return OnloHTTPResponse(statusCode: 503, body: Data("{}".utf8))
    }
    private func rejection() -> OnloHTTPResponse {
        OnloHTTPResponse(statusCode: 401, body: Data("""
        {"requestId":"synthetic-stale-resume","serverTime":"2026-10-10T00:00:00Z","protocolVersion":1,"minimumProtocolVersion":1,"ok":false,"error":{"code":"session_expired","message":"synthetic","retry":{"directive":"after_token_refresh"}}}
        """.utf8))
    }
    private func success(operation: [String: Any]) throws -> OnloHTTPResponse {
        let result: [String: Any] = ["sessionId": "session-\(generation)", "chatToken": "synthetic-bearer-\(generation)", "installationId": "installation-1", "generation": generation, "proposedCredential": operation["proposedCredential"]!, "identityClass": identity, "publicationState": "testing", "attestationState": "not_required", "configRevision": "revision-1", "configSchemaVersion": 1, "configEtag": "etag-1"]
        let envelope: [String: Any] = ["requestId": "synthetic", "serverTime": "2026-10-10T00:00:00Z", "protocolVersion": 1, "minimumProtocolVersion": 1, "ok": true, "result": result]
        return OnloHTTPResponse(statusCode: 200, body: try JSONSerialization.data(withJSONObject: envelope))
    }
}
