import XCTest
@testable import OnloSDK

final class NativeLifecycleBindingTests: XCTestCase {
    func testInitialReachablePathIsNotTreatedAsRecovery() {
        var gate = NetworkRecoveryGate()

        XCTAssertFalse(gate.pathChanged(isAvailable: true))
        XCTAssertFalse(gate.pathChanged(isAvailable: true))
    }

    func testOnlyOfflineToOnlinePathTransitionRecovers() {
        var gate = NetworkRecoveryGate()

        XCTAssertFalse(gate.pathChanged(isAvailable: false))
        XCTAssertTrue(gate.pathChanged(isAvailable: true))
        XCTAssertFalse(gate.pathChanged(isAvailable: true))
        XCTAssertFalse(gate.pathChanged(isAvailable: false))
        XCTAssertTrue(gate.pathChanged(isAvailable: true))
    }

    func testForegroundRecoveryReplaysStoredResumeWithoutChangingTransitionID() async throws {
        let scope = OwnerScope(kind: .anonymous)
        let credential = StoredSessionCredential(
            installationId: "installation-1", generation: 1, proposedCredential: "credential-1",
            identityClass: .anonymous, ownerScope: scope
        )
        let transport = LifecycleRecordingTransport()
        await transport.enqueueUnavailable()
        let sdk = OnloSDK(
            credentialStore: InMemoryCredentialStore(credential),
            ownerStore: InMemoryOwnerScopedStore(),
            transport: transport,
            hostAppIdentifier: "com.example.host"
        )
        let configuration = OnloSDK.Configuration(sdkKey: "public-key", appIdentifier: "com.example.host", apiBaseURL: URL(string: "https://sdk.example.test")!)
        let initialState = try await sdk.initialize(configuration)
        XCTAssertEqual(initialState, .offlineReady)

        await transport.enqueue(lifecycleSessionResponse())
        _ = try? await sdk.refreshConfigurationForForeground()

        let recoveredState = await sdk.currentState()
        XCTAssertEqual(recoveredState, .anonymousReady)
        let sessionBodies = await transport.sessionBodies()
        XCTAssertEqual(sessionBodies.count, 2)
        let firstRequest = try XCTUnwrap(sessionBodies[0])
        let secondRequest = try XCTUnwrap(sessionBodies[1])
        XCTAssertEqual(
            try JSONDecoder().decode(SessionRequest.self, from: firstRequest),
            try JSONDecoder().decode(SessionRequest.self, from: secondRequest)
        )
        // One post-session conditional config attempt is expected; foreground
        // recovery must not immediately issue a duplicate config request.
        let requestCount = await transport.requestCount()
        XCTAssertEqual(requestCount, 3)
    }

    func testForegroundRecoveryNeverReplaysPendingIdentifyWithoutFreshJWT() async throws {
        let scope = OwnerScope(kind: .anonymous)
        let credential = StoredSessionCredential(
            installationId: "installation-1", generation: 1, proposedCredential: "credential-1",
            identityClass: .anonymous, ownerScope: scope
        )
        let pending = PendingSessionTransition.identify(
            transitionId: "transition-1", installationId: "installation-1", expectedGeneration: 1,
            presentedCredential: "credential-1", proposedCredential: "credential-2"
        )
        let transport = LifecycleRecordingTransport()
        let sdk = OnloSDK(
            credentialStore: InMemoryCredentialStore(credential, pendingTransition: pending),
            ownerStore: InMemoryOwnerScopedStore(),
            transport: transport,
            hostAppIdentifier: "com.example.host"
        )
        let configuration = OnloSDK.Configuration(sdkKey: "public-key", appIdentifier: "com.example.host", apiBaseURL: URL(string: "https://sdk.example.test")!)
        let initialState = try await sdk.initialize(configuration)
        XCTAssertEqual(initialState, .reauthRequired)

        do {
            try await sdk.refreshConfigurationForForeground()
            XCTFail("reauth-required recovery must not start configuration traffic")
        } catch let error as OnloError {
            XCTAssertEqual(error, .requiresNetwork)
        }

        let state = await sdk.currentState()
        let requestCount = await transport.requestCount()
        XCTAssertEqual(state, .reauthRequired)
        XCTAssertEqual(requestCount, 0)
    }
}

private actor LifecycleRecordingTransport: OnloHTTPTransport {
    private enum Step { case response(OnloHTTPResponse), unavailable }
    private var steps: [Step] = []
    private var requests: [URLRequest] = []

    func enqueue(_ response: OnloHTTPResponse) { steps.append(.response(response)) }
    func enqueueUnavailable() { steps.append(.unavailable) }

    func execute(_ request: URLRequest) async throws -> OnloHTTPResponse {
        requests.append(request)
        let step = steps.isEmpty ? Step.unavailable : steps.removeFirst()
        switch step {
        case let .response(response): return lifecycleSessionResponseMatchingRequest(response, request: request)
        case .unavailable: throw OnloError.transport(code: "network_unavailable")
        }
    }

    func sessionBodies() -> [Data?] { requests.filter { $0.url?.path == "/api/sdk/v1/session" }.map(\.httpBody) }
    func requestCount() -> Int { requests.count }
}

private func lifecycleSessionResponse() -> OnloHTTPResponse {
    let body = Data("""
    {"requestId":"r","serverTime":"2026-01-01T00:00:00Z","protocolVersion":1,"minimumProtocolVersion":1,"ok":true,"result":{"sessionId":"session-2","chatToken":"synthetic-chat-token","installationId":"installation-1","generation":2,"proposedCredential":"credential-2","identityClass":"anonymous","publicationState":"testing","attestationState":"not_required","configRevision":"r2","configSchemaVersion":1,"configEtag":"e2"}}
    """.utf8)
    return OnloHTTPResponse(statusCode: 200, body: body)
}

private func lifecycleSessionResponseMatchingRequest(_ response: OnloHTTPResponse, request: URLRequest) -> OnloHTTPResponse {
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
