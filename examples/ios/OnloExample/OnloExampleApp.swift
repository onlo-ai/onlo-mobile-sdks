import OnloSDK
import SwiftUI
import UIKit
import UserNotifications

@main
struct OnloExampleApp: App {
    @UIApplicationDelegateAdaptor(OnloExampleAppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            VStack(spacing: 12) {
                Image(systemName: "questionmark.bubble")
                Text("Embed SupportView in your merchant app")
                Text("Pass your public SDK key and an authenticated backend callback.")
                    .multilineTextAlignment(.center)
            }
            .padding()
        }
    }
}

/// Merge these callbacks into the merchant app's existing app delegate. The
/// delegate retains only a bounded in-memory tap/token while native Onlo state
/// restores; credentials and customer state stay inside the SDK.
@MainActor
final class OnloExampleAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    private var pendingAPNsToken: Data?
    private var pendingPushPayload: PushNotificationPayload?
    private var stateTask: Task<Void, Never>?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        let notificationCenter = UNUserNotificationCenter.current()
        notificationCenter.delegate = self
        notificationCenter.getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized ||
                    settings.authorizationStatus == .provisional ||
                    settings.authorizationStatus == .ephemeral else { return }
            DispatchQueue.main.async { application.registerForRemoteNotifications() }
        }
        stateTask = Task { [weak self] in
            guard let self else { return }
            for await state in await Onlo.observeState() {
                guard !Task.isCancelled else { return }
                if state != .uninitialized { await self.forwardPendingAPNsToken() }
                if state == .anonymousReady || state == .identifiedReady {
                    await self.routePendingPush()
                }
            }
        }
        return true
    }

    func applicationDidBecomeActive(_ application: UIApplication) {
        Task { await routePendingPush() }
    }

    func requestSupportNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) { granted, _ in
            guard granted else { return }
            DispatchQueue.main.async { UIApplication.shared.registerForRemoteNotifications() }
        }
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        pendingAPNsToken = deviceToken
        Task { await forwardPendingAPNsToken() }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        let isOnlo = Self.pushPayload(notification.request.content.userInfo) != nil
        completionHandler(isOnlo ? [.banner, .list, .sound] : [])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let payload = Self.pushPayload(response.notification.request.content.userInfo)
        completionHandler()
        guard let payload else { return }
        Task { @MainActor [weak self] in
            self?.pendingPushPayload = payload
            await self?.routePendingPush()
        }
    }

    func clearPendingSupportNotification() {
        pendingPushPayload = nil
    }

    private func forwardPendingAPNsToken() async {
        guard let pendingAPNsToken else { return }
        do {
            _ = try await Onlo.setAPNsPushToken(pendingAPNsToken)
            self.pendingAPNsToken = nil
        } catch {
            // Initialization or network recovery will produce another state
            // transition; retain only this in-memory token until then.
        }
    }

    private func routePendingPush() async {
        guard let pendingPushPayload,
              let host = UIApplication.shared.topOnloViewController else { return }
        do {
            switch try await Onlo.handlePushNotification(pendingPushPayload) {
            case .handled(.messenger(let conversationId)):
                self.pendingPushPayload = nil
                if let conversationId {
                    try await Onlo.openConversation(conversationId, from: host)
                }
            case .deferred:
                break
            case .notOnlo:
                self.pendingPushPayload = nil
            }
        } catch {
            // Keep the bounded in-memory tap for foreground/network recovery.
        }
    }

    nonisolated private static func pushPayload(
        _ userInfo: [AnyHashable: Any]
    ) -> PushNotificationPayload? {
        guard let conversationId = userInfo["conversationId"] as? String,
              !conversationId.isEmpty,
              let messageId = userInfo["messageId"] as? String,
              !messageId.isEmpty,
              userInfo["notificationType"] as? String == "message_available" else {
            return nil
        }
        return PushNotificationPayload(
            conversationId: conversationId,
            messageId: messageId,
            notificationType: .messageAvailable
        )
    }
}

extension UIApplication {
    var topOnloViewController: UIViewController? {
        connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }
            .first?.rootViewController
    }
}
