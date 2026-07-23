import Flutter
import Foundation
@_spi(FrameworkBridge) import OnloSDK
import UIKit

/// Flutter's iOS boundary owns neither credentials nor customer content. The
/// the bridge imports the single native OnloSDK module, so all
/// session, protected storage, push intent, lifecycle, and UI work stays native.
@MainActor
public final class OnloFlutterPlugin: NSObject, FlutterPlugin, FlutterStreamHandler {
    private let sdk = OnloSDK()
    private lazy var presenter = OnloMessengerPresenter(sdk: sdk)
    private weak var hostViewController: UIViewController?
    private var eventSink: FlutterEventSink?
    private var stateTask: Task<Void, Never>?
    private var lastEmittedState: SDKState?
    private var lastUnreadCount: Int?
    private var hasEmittedUnreadCount = false

    deinit { stateTask?.cancel() }

    public static func register(with registrar: FlutterPluginRegistrar) {
        let instance = OnloFlutterPlugin()
        instance.hostViewController = registrar.viewController
        let methods = FlutterMethodChannel(name: "ai.onlo/onlo_flutter", binaryMessenger: registrar.messenger())
        registrar.addMethodCallDelegate(instance, channel: methods)
        let events = FlutterEventChannel(name: "ai.onlo/onlo_flutter/state", binaryMessenger: registrar.messenger())
        events.setStreamHandler(instance)
    }

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "setLogLevel":
            guard let raw = call.arguments as? String else {
                result(failure("invalid_argument")); return
            }
            let level: OnloLogLevel
            switch raw {
            case "off": level = .off
            case "error": level = .error
            case "info": level = .info
            case "verbose": level = .verbose
            default: result(failure("invalid_argument")); return
            }
            OnloConsoleLogger.shared.setLevel(level)
            result(nil)
        case "initialize":
            guard let sdkKey = arguments(call)["sdkKey"] as? String, !sdkKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                result(failure("invalid_argument")); return
            }
            operation(result) {
                _ = try await self.sdk.initializeFrameworkBridge(sdkKey: sdkKey, sdkFamily: .flutter)
            }
        case "loginUnidentifiedUser":
            operation(result) {
                _ = try await self.sdk.loginUnidentifiedUser()
            }
        case "loginIdentifiedUser":
            guard let jwt = arguments(call)["userJwt"] as? String, !jwt.isEmpty else {
                result(failure("invalid_argument")); return
            }
            operation(result) {
                _ = try await self.sdk.loginIdentifiedUser(userJwt: jwt)
            }
        case "logout":
            operation(result) {
                _ = try await self.sdk.logout()
                self.presenter.dismiss()
            }
        case "present":
            present(call, result: result)
        case "dismiss":
            presenter.dismiss()
            result(nil)
        case "openConversation":
            guard let conversationId = nonEmpty(arguments(call)["conversationId"]) else {
                result(failure("invalid_argument")); return
            }
            openConversation(conversationId, result: result)
        case "setPushToken":
            setPushToken(call, result: result)
        case "handlePushNotification":
            handlePushNotification(call, result: result)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    public func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        eventSink = events
        stateTask?.cancel()
        // A new Dart subscription must receive the current safe snapshot even
        // when it is unchanged from a previous subscription.
        lastEmittedState = nil
        hasEmittedUnreadCount = false
        stateTask = Task { [weak self] in
            guard let self else { return }
            let states = await self.sdk.observeFrameworkState()
            for await snapshot in states {
                guard !Task.isCancelled else { return }
                self.emit(snapshot)
            }
        }
        return nil
    }

    public func onCancel(withArguments arguments: Any?) -> FlutterError? {
        stateTask?.cancel()
        stateTask = nil
        eventSink = nil
        return nil
    }

    private func present(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let values = arguments(call)
        if values.keys.contains("conversationId"), values["conversationId"] != nil, nonEmpty(values["conversationId"]) == nil {
            result(failure("invalid_argument")); return
        }
        let conversationId = values["conversationId"] as? String
        operation(result) {
            guard let host = self.presentationHost() else { throw BridgeError(code: "native_operation_failed") }
            try await self.presenter.present(from: host, conversationId: conversationId)
        }
    }

    private func openConversation(_ conversationId: String, result: @escaping FlutterResult) {
        operation(result) {
            guard let host = self.presentationHost() else { throw BridgeError(code: "native_operation_failed") }
            try await self.presenter.present(from: host, conversationId: conversationId)
        }
    }

    private func setPushToken(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let values = arguments(call)
        guard values["provider"] as? String == "apns",
              let token = nonEmpty(values["token"]),
              let tokenData = Data(hexString: token) else {
            result(failure("invalid_argument")); return
        }
        let preference: PushTokenRequest.NotificationPreference?
        switch values["notificationPreference"] as? String {
        case nil: preference = nil
        case "enabled": preference = .enabled
        case "muted": preference = .muted
        default: result(failure("invalid_argument")); return
        }
        let locale = values["locale"] as? String
        if values.keys.contains("locale"), values["locale"] != nil, nonEmpty(locale) == nil {
            result(failure("invalid_argument")); return
        }
        operation(result) {
            _ = try await self.sdk.setAPNsPushToken(tokenData, notificationPreference: preference, locale: locale)
        }
    }

    private func handlePushNotification(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let values = arguments(call)
        guard let conversationId = nonEmpty(values["conversationId"]),
              let messageId = nonEmpty(values["messageId"]),
              values["notificationType"] as? String == "message_available" else {
            result(failure("invalid_argument")); return
        }
        operationResult(result) {
            let payload = PushNotificationPayload(conversationId: conversationId, messageId: messageId, notificationType: .messageAvailable)
            switch try await self.sdk.handlePushNotificationFromBridge(payload) {
            case .handled(let intent):
                guard let host = self.presentationHost() else { return "deferred" }
                switch intent {
                case let .messenger(conversationId):
                    // The push refetch was authorised above. Re-authorise at
                    // presentation time because a logout/account switch can
                    // happen while the Flutter host is resuming.
                    try await self.presenter.present(from: host, conversationId: conversationId)
                    return "handled"
                }
            case .deferred: return "deferred"
            case .notOnlo: return "notOnlo"
            }
        }
    }

    private func operation(_ result: @escaping FlutterResult, _ body: @escaping @MainActor () async throws -> Void) {
        Task { @MainActor in
            do {
                try await body()
                result(nil)
            } catch {
                result(errorPayload(error))
            }
        }
    }

    private func operationResult(_ result: @escaping FlutterResult, _ body: @escaping @MainActor () async throws -> String) {
        Task { @MainActor in
            do { result(try await body()) }
            catch { result(errorPayload(error)) }
        }
    }

    private func emit(_ snapshot: SDKFrameworkState) {
        guard lastEmittedState != snapshot.state ||
                !hasEmittedUnreadCount ||
                lastUnreadCount != snapshot.unreadCount else { return }
        lastEmittedState = snapshot.state
        lastUnreadCount = snapshot.unreadCount
        hasEmittedUnreadCount = true
        let event: [String: Any] = [
            "session": snapshot.state.rawValue,
            "identity": identity(for: snapshot.state),
            "connection": connection(for: snapshot.state),
            "unreadCount": snapshot.unreadCount.map { $0 as Any } ?? NSNull(),
        ]
        eventSink?(event)
    }

    private func presentationHost() -> UIViewController? {
        let host = hostViewController ?? topViewController()
        return host?.viewIfLoaded?.window == nil ? nil : host
    }
}

private struct BridgeError: Error { let code: String }

private func arguments(_ call: FlutterMethodCall) -> [String: Any] { call.arguments as? [String: Any] ?? [:] }
private func nonEmpty(_ value: Any?) -> String? {
    guard let string = value as? String, !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
    return string
}

private func failure(_ code: String) -> FlutterError { FlutterError(code: code, message: "Onlo operation failed (\(code)).", details: ["code": code]) }

private func errorPayload(_ error: Error) -> FlutterError {
    if let bridge = error as? BridgeError { return failure(bridge.code) }
    guard let onlo = error as? OnloError else { return failure("native_operation_failed") }
    switch onlo {
    case .remote(let remote):
        var details: [String: Any] = ["code": remote.code.rawValue, "retry": ["directive": remote.retry.directive.rawValue]]
        if let retryAfterMs = remote.retry.retryAfterMs { details["retry"] = ["directive": remote.retry.directive.rawValue, "retryAfterMs": retryAfterMs] }
        return FlutterError(code: remote.code.rawValue, message: "Onlo operation failed (\(remote.code.rawValue)).", details: details)
    case .invalidUserJWT, .invalidConfiguration:
        return failure("invalid_argument")
    default:
        return failure("native_operation_failed")
    }
}

private func identity(for state: SDKState) -> String {
    switch state {
    case .anonymousReady, .identifying: return "anonymous"
    case .identifiedReady: return "identified"
    default: return "unknown"
    }
}

private func connection(for state: SDKState) -> String {
    switch state {
    case .uninitialized: return "uninitialized"
    case .offlineReady: return "offline"
    case .restoring, .logoutPending, .reauthRequired: return "unavailable"
    default: return "ready"
    }
}

private func topViewController(_ root: UIViewController? = UIApplication.shared.connectedScenes
    .compactMap { ($0 as? UIWindowScene)?.keyWindow }
    .first?.rootViewController) -> UIViewController? {
    if let navigation = root as? UINavigationController { return topViewController(navigation.visibleViewController) }
    if let tab = root as? UITabBarController { return topViewController(tab.selectedViewController) }
    if let presented = root?.presentedViewController { return topViewController(presented) }
    return root
}

private extension Data {
    init?(hexString: String) {
        let text = hexString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count.isMultiple(of: 2), text.count <= 1024 else { return nil }
        var data = Data()
        data.reserveCapacity(text.count / 2)
        var index = text.startIndex
        while index < text.endIndex {
            let end = text.index(index, offsetBy: 2)
            guard let byte = UInt8(text[index..<end], radix: 16) else { return nil }
            data.append(byte)
            index = end
        }
        self = data
    }
}
