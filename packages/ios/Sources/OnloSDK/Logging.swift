import Foundation

public struct SDKLogEvent: Sendable, Equatable {
    public let operation: String
    public let code: String
    public let requestId: String?
    public let sdkVersion: String
    public let runtimePlatform: RuntimePlatform
    public let durationMs: Int

    public init(
        operation: String,
        code: String,
        requestId: String? = nil,
        sdkVersion: String,
        runtimePlatform: RuntimePlatform = .ios,
        durationMs: Int
    ) {
        self.operation = operation
        self.code = code
        self.requestId = requestId
        self.sdkVersion = sdkVersion
        self.runtimePlatform = runtimePlatform
        self.durationMs = durationMs
    }
}

/// Receives only structured, PII-free diagnostic metadata. Implementations must
/// not add credentials, JWTs, message text, push tokens, or attachment URLs.
public protocol SDKLogging: Sendable {
    func record(_ event: SDKLogEvent) async
}

public struct NoopSDKLogger: SDKLogging {
    public init() {}
    public func record(_ event: SDKLogEvent) async {}
}

public actor InMemorySDKLogger: SDKLogging {
    private var storedEvents: [SDKLogEvent] = []

    public init() {}

    public func record(_ event: SDKLogEvent) async {
        storedEvents.append(event)
    }

    public func events() async -> [SDKLogEvent] { storedEvents }
}
