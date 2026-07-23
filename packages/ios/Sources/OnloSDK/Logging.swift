import Foundation
import OSLog

public enum OnloLogLevel: Int, Sendable, CaseIterable {
    case off = 0
    case error = 1
    case info = 2
    case verbose = 3
}

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

/// Process-wide logger used by the customer facade and native framework
/// bridges. Every value is selected by the SDK and sanitised before OSLog.
/// The level changes at runtime, including after SDK initialization.
public final class OnloConsoleLogger: SDKLogging, @unchecked Sendable {
    public static let shared = OnloConsoleLogger()

    private let lock = NSLock()
    private var configuredLevel: OnloLogLevel = .off
    private let logger = Logger(subsystem: "ai.onlo.sdk", category: "runtime")

    private init() {}

    public func setLevel(_ level: OnloLogLevel) {
        lock.lock()
        configuredLevel = level
        lock.unlock()
    }

    public func record(_ event: SDKLogEvent) async {
        let required = requiredLevel(for: event)
        guard shouldRecord(event) else { return }
        let fields = formattedMessage(for: event)

        switch required {
        case .error:
            logger.error("\(fields, privacy: .public)")
        case .info:
            logger.info("\(fields, privacy: .public)")
        case .verbose:
            logger.debug("\(fields, privacy: .public)")
        case .off:
            break
        }
    }

    func shouldRecord(_ event: SDKLogEvent) -> Bool {
        currentLevel().rawValue >= requiredLevel(for: event).rawValue
    }

    func formattedMessage(for event: SDKLogEvent) -> String {
        [
            "operation=\(sanitise(event.operation))",
            "code=\(sanitise(event.code))",
            "sdkVersion=\(sanitise(event.sdkVersion))",
            "runtime=\(event.runtimePlatform.rawValue)",
            event.requestId.map { "requestId=\(sanitise($0))" },
            "durationMs=\(max(0, event.durationMs))",
        ].compactMap { $0 }.joined(separator: " ")
    }

    private func currentLevel() -> OnloLogLevel {
        lock.lock()
        defer { lock.unlock() }
        return configuredLevel
    }

    private func requiredLevel(for event: SDKLogEvent) -> OnloLogLevel {
        switch event.code {
        case "ok", "accepted", "complete":
            return .info
        case "first_token", "not_modified", "offline_cache":
            return .verbose
        default:
            return .error
        }
    }

    private func sanitise(_ value: String) -> String {
        String(value.prefix(128).map { character in
            character.isLetter || character.isNumber || "._:-".contains(character)
                ? character
                : "_"
        })
    }
}

public actor InMemorySDKLogger: SDKLogging {
    private var storedEvents: [SDKLogEvent] = []

    public init() {}

    public func record(_ event: SDKLogEvent) async {
        storedEvents.append(event)
    }

    public func events() async -> [SDKLogEvent] { storedEvents }
}
