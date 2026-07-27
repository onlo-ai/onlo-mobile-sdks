#if DEBUG
@_spi(DevelopmentSupport) import OnloSDK
#else
import OnloSDK
#endif
import SwiftUI
import UIKit
@preconcurrency import UserNotifications
import os

@main
struct OnloLocalE2EApp: App {
    @UIApplicationDelegateAdaptor(LocalAppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            LocalE2ERootView()
                .onOpenURL { appDelegate.forwardDeepLink($0) }
        }
    }
}

private struct LocalE2ERootView: View {
    @StateObject private var model = LocalE2EModel()

    var body: some View {
        Group {
            if model.isSignedIn {
                supportScreen
            } else {
                loginScreen
            }
        }
        .padding()
    }

    private var loginScreen: some View {
        VStack(spacing: 16) {
            Text("Merchant app")
                .font(.largeTitle.bold())
            Text("Local E2E test host")
                .foregroundStyle(.secondary)
            SecureField("Local test login code", text: $model.loginCode)
                .textFieldStyle(.roundedBorder)
            Button("Log in") { Task { await model.login() } }
                .buttonStyle(.borderedProminent)
                .disabled(!model.canLogIn)
            Button("Continue anonymously") { Task { await model.continueAnonymously() } }
                .buttonStyle(.bordered)
            Text(model.status)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
    }

    private var supportScreen: some View {
        VStack(spacing: 16) {
            Text("Merchant app")
                .font(.largeTitle.bold())
            Text("Customer support")
                .foregroundStyle(.secondary)
            if model.isSupportLoading {
                ProgressView("Preparing Support")
            } else if !model.isSupportReady {
                Button("Retry Support") { Task { await model.retrySupport() } }
                    .buttonStyle(.bordered)
            }
            Button("Support") { model.presentMessenger() }
                .buttonStyle(.borderedProminent)
                .disabled(!model.isSupportReady)
            Text("Image attachments use the native picker and camera controls.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            if model.isAnonymous {
                Button("Back") { model.leaveAnonymousSupport() }
                    .buttonStyle(.bordered)
            } else {
                Button("Log out") { Task { await model.logout() } }
                    .buttonStyle(.bordered)
            }
            Text(model.status)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
    }
}

@MainActor
private final class LocalE2EModel: ObservableObject {
    @Published var loginCode = ""
    @Published private(set) var isSignedIn = false
    @Published private(set) var isSupportReady = false
    @Published private(set) var isSupportLoading = false
    @Published private(set) var status = "Enter a local test account"

    private enum SessionMode {
        case anonymous
        case identified
    }

    private let backend = LocalMerchantBackend()
    private let sdk = LocalSDKEnvironment.sdk
    private var presenter: OnloMessengerPresenter?
    private var supportConfiguration: LocalSupportConfiguration?
    private var sessionMode: SessionMode?

    var canLogIn: Bool {
        !loginCode.isEmpty
    }

    var isAnonymous: Bool {
        sessionMode == .anonymous
    }

    func continueAnonymously() async {
        guard let configuration = LocalSupportConfiguration.fromBundle else {
            status = "Add the safe local SDK configuration"
            return
        }
        supportConfiguration = configuration
        sessionMode = .anonymous
        isSignedIn = true
        await prepareAnonymousSupport(configuration)
    }

    private func prepareAnonymousSupport(_ configuration: LocalSupportConfiguration) async {
        isSupportLoading = true
        isSupportReady = false
        do {
            let state = try await initialize(configuration)
            if state == .logoutPending {
                _ = try await sdk.logout()
            }
            _ = try await sdk.loginUnidentifiedUser()
            presenter = OnloMessengerPresenter(sdk: sdk)
            isSupportReady = true
            status = "Anonymous support is ready"
        } catch {
            isSupportReady = false
            status = "Support is unavailable (\(safeDiagnosticCode(for: error)))"
        }
        isSupportLoading = false
    }

    func login() async {
        let startedAt = Date()
        status = "Signing in"
        E2ESafeDiagnostics.record(operation: "merchant_login", code: "started")
        do {
            let result = try await backend.login(loginCode: loginCode)
            E2ESafeDiagnostics.record(
                operation: "merchant_login",
                code: "backend_accepted",
                durationMs: elapsedMilliseconds(since: startedAt)
            )
            loginCode = ""
            isSignedIn = true
            isSupportReady = false
            sessionMode = .identified
            supportConfiguration = LocalSupportConfiguration(
                sdkKey: result.sdkKey,
                onloDevelopmentOrigin: LocalSupportConfiguration.usesDevelopmentOrigin
                    ? result.onloDevelopmentOrigin
                    : nil
            )
            status = "Signed in. Preparing Support"
            await prepareSupport(userJwt: result.userJwt)
        } catch {
            let code = safeDiagnosticCode(for: error)
            status = "Merchant login failed (\(code))"
            E2ESafeDiagnostics.record(
                operation: "merchant_login",
                code: code,
                durationMs: elapsedMilliseconds(since: startedAt)
            )
        }
    }

    func retrySupport() async {
        guard let supportConfiguration else { return }
        if sessionMode == .anonymous {
            await prepareAnonymousSupport(supportConfiguration)
            return
        }
        do {
            let userJwt = try await backend.refreshUserJwt()
            await prepareSupport(userJwt: userJwt, configuration: supportConfiguration)
        } catch {
            let code = safeDiagnosticCode(for: error)
            status = "Support is unavailable (\(code))"
            E2ESafeDiagnostics.record(operation: "sdk_support_retry", code: code)
        }
    }

    private func prepareSupport(userJwt: String, configuration: LocalSupportConfiguration? = nil) async {
        guard let configuration = configuration ?? supportConfiguration else { return }
        isSupportLoading = true
        isSupportReady = false
        E2ESafeDiagnostics.record(operation: "sdk_initialize", code: "started")
        do {
            _ = try await initialize(configuration)
            E2ESafeDiagnostics.record(operation: "sdk_initialize", code: "complete")
            E2ESafeDiagnostics.record(operation: "sdk_identify", code: "started")
            _ = try await sdk.loginIdentifiedUser(userJwt: userJwt)
            E2ESafeDiagnostics.record(operation: "sdk_identify", code: "complete")
            presenter = OnloMessengerPresenter(sdk: sdk)
            isSupportReady = true
            status = "Support is ready"
            E2ESafeDiagnostics.record(operation: "sdk_support", code: "ready")
        } catch {
            let code = safeDiagnosticCode(for: error)
            status = "Support is unavailable (\(code))"
            E2ESafeDiagnostics.record(operation: "sdk_support", code: code)
        }
        isSupportLoading = false
    }

    private func initialize(_ configuration: LocalSupportConfiguration) async throws -> SDKState {
        #if DEBUG
        if let origin = configuration.onloDevelopmentOrigin {
            return try await sdk.initializeDevelopment(
                apiKey: configuration.sdkKey,
                onloDevelopmentOrigin: origin
            )
        }
        #endif
        return try await sdk.initialize(apiKey: configuration.sdkKey)
    }

    func presentMessenger() {
        guard let presenter, let host = UIApplication.shared.topOnloViewController else {
            E2ESafeDiagnostics.record(operation: "present_messenger", code: "host_unavailable")
            return
        }
        Task {
            let startedAt = Date()
            do {
                try await presenter.present(from: host)
                E2ESafeDiagnostics.record(
                    operation: "present_messenger",
                    code: "presented",
                    durationMs: elapsedMilliseconds(since: startedAt)
                )
            } catch {
                E2ESafeDiagnostics.record(
                    operation: "present_messenger",
                    code: safeDiagnosticCode(for: error),
                    durationMs: elapsedMilliseconds(since: startedAt)
                )
            }
        }
    }

    func logout() async {
        do {
            _ = try await sdk.logout()
            await backend.clearSession()
            resetHostSession(status: "Logged out")
            E2ESafeDiagnostics.record(operation: "merchant_logout", code: "complete")
        } catch {
            status = "Support logout is pending"
            E2ESafeDiagnostics.record(operation: "merchant_logout", code: safeDiagnosticCode(for: error))
        }
    }

    func leaveAnonymousSupport() {
        resetHostSession(status: "Anonymous support closed")
        E2ESafeDiagnostics.record(operation: "anonymous_support", code: "closed")
    }

    private func resetHostSession(status: String) {
        isSignedIn = false
        isSupportReady = false
        isSupportLoading = false
        supportConfiguration = nil
        presenter = nil
        sessionMode = nil
        self.status = status
    }

    private func safeDiagnosticCode(for error: Error) -> String {
        if let onloError = error as? OnloError { return onloError.safeCode }
        if error is LocalMerchantBackendError { return "merchant_login_rejected" }
        if error is URLError { return "merchant_network_unavailable" }
        if error is DecodingError { return "merchant_invalid_response" }
        return "unexpected_error"
    }

    private func elapsedMilliseconds(since startedAt: Date) -> Int {
        max(0, Int(Date().timeIntervalSince(startedAt) * 1_000))
    }
}

private actor LocalMerchantBackend {
    private let baseURL = URL(string: "https://127.0.0.1:8444")!
    private var merchantSession: String?

    func login(loginCode: String) async throws -> LocalMerchantLogin {
        var request = URLRequest(url: baseURL.appendingPathComponent("v1/test-login"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(LoginRequest(loginCode: loginCode))
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode) else {
            throw LocalMerchantBackendError.rejected
        }
        let result = try JSONDecoder().decode(LocalMerchantLogin.self, from: data)
        merchantSession = result.merchantSession
        return result
    }

    func clearSession() {
        merchantSession = nil
    }

    func refreshUserJwt() async throws -> String {
        guard let merchantSession else { throw LocalMerchantBackendError.rejected }
        var request = URLRequest(url: baseURL.appendingPathComponent("v1/onlo-user-jwt"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(merchantSession)", forHTTPHeaderField: "Authorization")
        request.httpBody = Data("{}".utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode) else {
            throw LocalMerchantBackendError.rejected
        }
        return try JSONDecoder().decode(RefreshedUserJWT.self, from: data).userJwt
    }
}

private struct LoginRequest: Encodable {
    let loginCode: String
}

private struct LocalMerchantLogin: Decodable {
    let merchantSession: String
    let sdkKey: String
    let onloDevelopmentOrigin: URL
    let userJwt: String
}

private struct RefreshedUserJWT: Decodable {
    let userJwt: String
}

private struct LocalSupportConfiguration {
    let sdkKey: String
    let onloDevelopmentOrigin: URL?

    static var usesDevelopmentOrigin: Bool {
        let value = Bundle.main.object(forInfoDictionaryKey: "ONLO_USE_DEVELOPMENT_ORIGIN")
        if let enabled = value as? Bool { return enabled }
        guard let raw = value as? String else { return false }
        return ["1", "true", "yes"].contains(raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }

    static var fromBundle: Self? {
        guard let sdkKey = Bundle.main.object(forInfoDictionaryKey: "ONLO_SDK_KEY") as? String,
              !sdkKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              sdkKey != "paste-your-public-ios-sdk-key-here" else {
            return nil
        }
        guard usesDevelopmentOrigin else {
            return Self(sdkKey: sdkKey, onloDevelopmentOrigin: nil)
        }
        guard let originString = Bundle.main.object(forInfoDictionaryKey: "ONLO_DEVELOPMENT_ORIGIN") as? String,
              let origin = URL(string: originString),
              origin.scheme?.lowercased() == "https",
              origin.host != nil else { return nil }
        return Self(sdkKey: sdkKey, onloDevelopmentOrigin: origin)
    }
}

private enum LocalMerchantBackendError: Error { case rejected }

private enum LocalSDKEnvironment {
    static let sdk = OnloSDK(logger: LocalE2ESDKLogger())
}

@MainActor
private final class LocalAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        let notificationCenter = UNUserNotificationCenter.current()
        notificationCenter.delegate = self
        notificationCenter.requestAuthorization(options: [.alert, .badge, .sound]) { granted, _ in
            guard granted else { return }
            DispatchQueue.main.async {
                application.registerForRemoteNotifications()
            }
        }
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken token: Data) {
        Task { _ = try? await LocalSDKEnvironment.sdk.setAPNsPushToken(token) }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let payload = Self.pushPayload(response.notification.request.content.userInfo)
        completionHandler()
        Task { @MainActor in
            guard let payload,
                  case .handled(.messenger(let conversationId)) =
                    try? await LocalSDKEnvironment.sdk.handlePushNotification(payload),
                  let conversationId else { return }
            await presentAuthorisedConversation(conversationId)
        }
    }

    func forwardDeepLink(_ url: URL) {
        let segments = url.pathComponents.filter { $0 != "/" }
        guard url.host == "support", segments.count == 2, segments[0] == "conversations" else { return }
        Task {
            guard case .messenger(let conversationId) =
                    try? await LocalSDKEnvironment.sdk.openConversation(segments[1]),
                  let conversationId else { return }
            await presentAuthorisedConversation(conversationId)
        }
    }

    private func presentAuthorisedConversation(_ conversationId: String) async {
        guard let host = UIApplication.shared.topOnloViewController else { return }
        try? await OnloMessengerPresenter(sdk: LocalSDKEnvironment.sdk)
            .present(from: host, conversationId: conversationId)
    }

    nonisolated private static func pushPayload(
        _ userInfo: [AnyHashable: Any]
    ) -> PushNotificationPayload? {
        guard let conversationId = userInfo["conversationId"] as? String,
              let messageId = userInfo["messageId"] as? String,
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

private actor LocalE2ESDKLogger: SDKLogging {
    func record(_ event: SDKLogEvent) async {
        E2ESafeDiagnostics.record(
            operation: "sdk_\(event.operation)",
            code: event.code,
            requestId: event.requestId,
            durationMs: event.durationMs
        )
    }
}

/// Writes only fixed operation names and safe error codes. It intentionally
/// excludes login input, SDK keys, JWTs, request headers, message content, and
/// service URLs. The cache file is disposable and never used by the SDK.
private enum E2ESafeDiagnostics {
    private static let logger = Logger(subsystem: "ai.onlo.locale2e", category: "diagnostics")

    static func record(
        operation: String,
        code: String,
        requestId: String? = nil,
        durationMs: Int? = nil
    ) {
        let requestField = requestId.map { " requestId=\(sanitize($0))" } ?? ""
        let durationField = durationMs.map { " durationMs=\(max(0, $0))" } ?? ""
        let line = "\(ISO8601DateFormatter().string(from: Date())) operation=\(sanitize(operation)) code=\(sanitize(code))\(requestField)\(durationField)\n"
        logger.info("\(line, privacy: .public)")
        guard let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return }
        let fileURL = directory.appendingPathComponent("onlo-e2e-diagnostics.log")
        guard let data = line.data(using: .utf8) else { return }
        do {
            if FileManager.default.fileExists(atPath: fileURL.path) {
                let handle = try FileHandle(forWritingTo: fileURL)
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
                try handle.close()
            } else {
                try data.write(to: fileURL, options: .atomic)
            }
        } catch {
            // Diagnostics must never affect customer login or support.
        }
    }

    private static func sanitize(_ value: String) -> String {
        String(value.prefix(128).map { character in
            character.isLetter || character.isNumber || "._:-".contains(character)
                ? character
                : "_"
        })
    }
}

private extension UIApplication {
    var topOnloViewController: UIViewController? {
        connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }
            .first?.rootViewController
    }
}
