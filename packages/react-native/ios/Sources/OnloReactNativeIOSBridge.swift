import Foundation

#if canImport(UIKit)
import UIKit

/// The Swift half of the React Native boundary. It intentionally owns no
/// credentials, messages, transcript, outbox, or push state: those remain in
/// `OnloSDK` protected native stores. Objective-C++ only passes short-lived
/// method arguments and promise callbacks through this type.
@MainActor
@objcMembers
public final class OnloReactNativeIOSBridge: NSObject {
    public typealias Completion = (NSDictionary?) -> Void
    public typealias ResultCompletion = (NSString?, NSDictionary?) -> Void

    private let sdk = OnloSDK()
    private lazy var presenter = OnloMessengerPresenter(sdk: sdk)
    private let eventSink: (NSDictionary) -> Void
    private var stateTask: Task<Void, Never>?
    private var initializedSDKKey: String?
    private var lastState: SDKState?
    private var lastIdentity: String?
    private var lastConnection: String?
    private var lastUnreadCount: Int?

    public init(eventSink: @escaping (NSDictionary) -> Void) {
        self.eventSink = eventSink
        super.init()
    }

    deinit { stateTask?.cancel() }

    public func initialize(withSDKKey sdkKey: String, completion: @escaping Completion) {
        guard isNonBlank(sdkKey), initializedSDKKey == nil || initializedSDKKey == sdkKey else {
            completion(failure("invalid_argument")); return
        }
        operation(completion) {
            _ = try await self.sdk.initializeFrameworkBridge(sdkKey: sdkKey, sdkFamily: .reactNative)
            self.initializedSDKKey = sdkKey
            self.observeCoreStateIfNeeded()
        }
    }

    public func loginUnidentified(completion: @escaping Completion) {
        operation(completion) { _ = try await self.sdk.loginUnidentifiedUser() }
    }

    public func loginIdentified(withUserJWT userJWT: String, completion: @escaping Completion) {
        guard isNonBlank(userJWT) else { completion(failure("invalid_argument")); return }
        operation(completion) { _ = try await self.sdk.loginIdentifiedUser(userJwt: userJWT) }
    }

    public func logout(completion: @escaping Completion) {
        operation(completion) {
            _ = try await self.sdk.logout()
            self.presenter.dismiss(animated: false)
        }
    }

    public func present(from host: UIViewController, conversationID: String?, completion: @escaping Completion) {
        guard conversationID == nil || isNonBlank(conversationID!) else { completion(failure("invalid_argument")); return }
        operation(completion) {
            try await self.presenter.present(from: host, conversationId: conversationID)
        }
    }

    public func dismiss(completion: @escaping Completion) {
        presenter.dismiss()
        completion(nil)
    }

    public func openConversation(_ conversationID: String, from host: UIViewController, completion: @escaping Completion) {
        guard isNonBlank(conversationID) else { completion(failure("invalid_argument")); return }
        operation(completion) {
            try await self.presenter.present(from: host, conversationId: conversationID)
        }
    }

    public func setAPNsPushToken(_ hexToken: String, notificationPreference: String?, locale: String?, completion: @escaping Completion) {
        guard let token = Data(onloHexString: hexToken),
              let preference = pushPreference(notificationPreference),
              locale == nil || isNonBlank(locale!) else {
            completion(failure("invalid_argument")); return
        }
        operation(completion) {
            _ = try await self.sdk.setAPNsPushToken(token, notificationPreference: preference, locale: locale)
        }
    }

    public func handlePushConversationID(_ conversationID: String, messageID: String, notificationType: String, host: UIViewController?, completion: @escaping ResultCompletion) {
        guard isNonBlank(conversationID), isNonBlank(messageID), notificationType == "message_available" else {
            completion(nil, failure("invalid_argument")); return
        }
        Task { @MainActor in
            do {
                let payload = PushNotificationPayload(conversationId: conversationID, messageId: messageID, notificationType: .messageAvailable)
                switch try await self.sdk.handlePushNotificationFromBridge(payload) {
                case .notOnlo: completion("notOnlo", nil)
                case .deferred: completion("deferred", nil)
                case let .handled(.messenger(target)):
                    // The core authorised and refetched before returning this
                    // intent. The presenter repeats its account-boundary gate
                    // before UIKit attaches anything.
                    guard let host, let target else { completion("deferred", nil); return }
                    try await self.presenter.present(from: host, conversationId: target)
                    completion("handled", nil)
                }
            } catch {
                completion(nil, errorPayload(error))
            }
        }
    }

    private func observeCoreStateIfNeeded() {
        guard stateTask == nil else { return }
        stateTask = Task { [weak self] in
            guard let self else { return }
            let states = await self.sdk.observeFrameworkState()
            for await snapshot in states {
                guard !Task.isCancelled else { return }
                self.emit(snapshot)
            }
        }
    }

    private func emit(_ snapshot: SDKFrameworkState) {
        if lastState != snapshot.state {
            lastState = snapshot.state
            eventSink(["type": "stateChanged", "state": snapshot.state.rawValue])
        }
        let identity = identity(for: snapshot.state)
        if lastIdentity != identity {
            lastIdentity = identity
            eventSink(["type": "identityChanged", "identity": identity])
        }
        let connection = connection(for: snapshot.state)
        if lastConnection != connection {
            lastConnection = connection
            eventSink(["type": "connectionChanged", "connection": connection])
        }
        guard let unreadCount = snapshot.unreadCount else {
            lastUnreadCount = nil
            return
        }
        guard lastUnreadCount != unreadCount else { return }
        lastUnreadCount = unreadCount
        eventSink(["type": "unreadChanged", "unreadCount": unreadCount])
    }

    private func operation(_ completion: @escaping Completion, _ body: @escaping @MainActor () async throws -> Void) {
        Task { @MainActor in
            do { try await body(); completion(nil) }
            catch { completion(errorPayload(error)) }
        }
    }
}

private func isNonBlank(_ value: String) -> Bool { !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

/// `nil` means no preference was supplied; a non-nil unknown value fails
/// before it reaches the native core.
private func pushPreference(_ value: String?) -> PushTokenRequest.NotificationPreference?? {
    switch value {
    case nil: return .some(nil)
    case "enabled": return .some(.enabled)
    case "muted": return .some(.muted)
    default: return nil
    }
}

private func identity(for state: SDKState) -> String {
    switch state {
    case .anonymousReady, .identifying: return "anonymous"
    case .identifiedReady: return "identified"
    default: return "unknown"
    }
}

/// Connection is derived exclusively from safe native lifecycle state. It is
/// not a second session implementation and never reports bearer authority.
private func connection(for state: SDKState) -> String {
    switch state {
    case .uninitialized: return "uninitialized"
    case .offlineReady: return "offline"
    case .anonymousReady, .identifiedReady, .identifying: return "ready"
    case .restoring, .logoutPending, .reauthRequired: return "unavailable"
    }
}

private func failure(_ code: String, retry: [String: Any]? = nil, requestID: String? = nil) -> NSDictionary {
    var result: [String: Any] = ["code": code]
    if let retry { result["retry"] = retry }
    if let requestID { result["requestId"] = requestID }
    return result as NSDictionary
}

private func errorPayload(_ error: Error) -> NSDictionary {
    guard let onlo = error as? OnloError else { return failure("native_operation_failed") }
    if case let .remote(remote) = onlo {
        var retry: [String: Any] = ["directive": remote.retry.directive.rawValue]
        if let retryAfterMs = remote.retry.retryAfterMs { retry["retryAfterMs"] = retryAfterMs }
        return failure(remote.code.rawValue, retry: retry, requestID: nil)
    }
    switch onlo {
    case .invalidUserJWT, .invalidConfiguration: return failure("invalid_argument")
    default: return failure("native_operation_failed")
    }
}

private extension Data {
    init?(onloHexString: String) {
        let text = onloHexString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count.isMultiple(of: 2), text.count <= 1024 else { return nil }
        var value = Data()
        value.reserveCapacity(text.count / 2)
        var index = text.startIndex
        while index < text.endIndex {
            let end = text.index(index, offsetBy: 2)
            guard let byte = UInt8(text[index..<end], radix: 16) else { return nil }
            value.append(byte)
            index = end
        }
        self = value
    }
}
#endif
