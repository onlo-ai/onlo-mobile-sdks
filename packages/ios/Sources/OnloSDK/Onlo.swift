import Foundation

#if canImport(UIKit)
import UIKit
#endif

/// Customer-facing lifecycle facade for the single Onlo integration owned by
/// a host app. Native/framework adapters may use `OnloSDK` directly when they
/// need explicit instance ownership.
public enum Onlo {
    private static let sdk = OnloSDK()

    #if canImport(UIKit)
    @MainActor
    private static var messenger = OnloMessengerPresenter(sdk: sdk)
    #endif

    /// Controls structured, PII-free SDK diagnostics for this process.
    public static func setLogLevel(_ level: OnloLogLevel) {
        OnloConsoleLogger.shared.setLevel(level)
    }

    /// Initializes the production SDK for this app integration.
    @discardableResult
    public static func initialize(apiKey: String) async throws -> SDKState {
        try await sdk.initialize(apiKey: apiKey)
    }

    /// Creates or resumes an installation-scoped anonymous customer session.
    @discardableResult
    public static func loginUnidentifiedUser() async throws -> SDKState {
        try await sdk.loginUnidentifiedUser()
    }

    /// Exchanges a short-lived JWT minted by the authenticated merchant
    /// backend. The mobile SDK never creates, stores, or logs this JWT.
    @discardableResult
    public static func loginIdentifiedUser(userJwt: String) async throws -> SDKState {
        try await sdk.loginIdentifiedUser(userJwt: userJwt)
    }

    /// Obtains a fresh JWT from host code and immediately exchanges it.
    @discardableResult
    public static func loginIdentifiedUser(
        using userJWTProvider: @Sendable () async throws -> String
    ) async throws -> SDKState {
        try await sdk.loginIdentifiedUser(using: userJWTProvider)
    }

    /// Ends the current Onlo account boundary before another app user starts.
    @discardableResult
    public static func logout() async throws -> SDKState {
        try await sdk.logout()
    }

    /// Token-free lifecycle state for enabling or disabling host-owned UI.
    public static func observeState() async -> AsyncStream<SDKState> {
        await sdk.observeState()
    }

    /// Identified-customer unread total. Anonymous and account-boundary states
    /// emit `nil`, allowing the host to clear its badge immediately.
    public static func observeUnreadCount() async -> AsyncStream<Int?> {
        let snapshots = await sdk.observeFrameworkState()
        return AsyncStream { continuation in
            let task = Task {
                for await snapshot in snapshots {
                    continuation.yield(snapshot.unreadCount)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Registers the APNs token without exposing it to application storage.
    #if canImport(UIKit)
    @discardableResult
    public static func setAPNsPushToken(_ token: Data) async throws -> OnloPushRegistrationState {
        try await sdk.setAPNsPushToken(token)
    }

    /// Re-authorises a contract-shaped Onlo push before returning a route.
    public static func handlePushNotification(
        _ payload: PushNotificationPayload
    ) async throws -> OnloPushNotificationHandling {
        try await sdk.handlePushNotification(payload)
    }

    /// Handles a user-tapped notification: validates its contract fields,
    /// re-authorises the conversation through the core, and opens it from the
    /// host-selected controller. Receiving a push without a tap never invokes
    /// this method and therefore never takes over app navigation.
    @MainActor
    public static func handleNotificationTap(
        _ userInfo: [AnyHashable: Any],
        from host: UIViewController
    ) async throws -> Bool {
        guard let conversationId = userInfo["conversationId"] as? String,
              !conversationId.isEmpty,
              let messageId = userInfo["messageId"] as? String,
              !messageId.isEmpty,
              userInfo["notificationType"] as? String == PushNotificationType.messageAvailable.rawValue else {
            return false
        }
        let payload = PushNotificationPayload(
            conversationId: conversationId,
            messageId: messageId,
            notificationType: .messageAvailable
        )
        switch try await sdk.handlePushNotification(payload) {
        case .handled(.messenger(let authorisedConversationId)):
            try await messenger.present(from: host, conversationId: authorisedConversationId)
            return true
        case .deferred:
            return true
        case .notOnlo:
            return false
        }
    }

    /// Applies host restrictions to future messenger presentations. Dashboard
    /// configuration remains authoritative for all settings not restricted here.
    @MainActor
    public static func configureMessenger(
        _ options: OnloMessengerOptions
    ) {
        messenger.dismiss(animated: false)
        messenger = OnloMessengerPresenter(sdk: sdk, options: options)
    }

    /// Presents the SDK-owned messenger from the host-selected controller.
    /// Supplying the controller avoids guessing the active scene/window.
    @MainActor
    public static func present(from host: UIViewController) async throws {
        try await messenger.present(from: host)
    }

    /// Opens a server-authorised conversation from a push or host route.
    @MainActor
    public static func openConversation(
        _ conversationId: String,
        from host: UIViewController
    ) async throws {
        try await messenger.present(from: host, conversationId: conversationId)
    }
    #endif
}
