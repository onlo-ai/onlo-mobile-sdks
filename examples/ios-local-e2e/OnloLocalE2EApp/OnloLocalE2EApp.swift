#if DEBUG
@_spi(DevelopmentSupport) import OnloSDK
#else
import OnloSDK
#endif
import SwiftUI
import UIKit
import os

@main
struct OnloLocalE2EApp: App {
    var body: some Scene {
        WindowGroup { LocalE2ERootView() }
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
            Button("Log out") { Task { await model.logout() } }
                .buttonStyle(.bordered)
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

    private let backend = LocalMerchantBackend()
    private let sdk = OnloSDK(logger: LocalE2ESDKLogger())
    private var presenter: OnloMessengerPresenter?
    private var supportConfiguration: LocalSupportConfiguration?

    var canLogIn: Bool {
        !loginCode.isEmpty
    }

    func login() async {
        status = "Signing in"
        E2ESafeDiagnostics.record(operation: "merchant_login", code: "started")
        do {
            let result = try await backend.login(loginCode: loginCode)
            E2ESafeDiagnostics.record(operation: "merchant_login", code: "backend_accepted")
            loginCode = ""
            isSignedIn = true
            isSupportReady = false
            supportConfiguration = LocalSupportConfiguration(
                sdkKey: result.sdkKey,
                onloDevelopmentOrigin: result.onloDevelopmentOrigin
            )
            status = "Signed in. Preparing Support"
            await prepareSupport(userJwt: result.userJwt)
        } catch {
            let code = safeDiagnosticCode(for: error)
            status = "Merchant login failed (\(code))"
            E2ESafeDiagnostics.record(operation: "merchant_login", code: code)
        }
    }

    func retrySupport() async {
        guard let supportConfiguration else { return }
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
            #if DEBUG
            _ = try await sdk.initializeDevelopment(
                apiKey: configuration.sdkKey,
                onloDevelopmentOrigin: configuration.onloDevelopmentOrigin
            )
            #else
            _ = try await sdk.initialize(apiKey: configuration.sdkKey)
            #endif
            E2ESafeDiagnostics.record(operation: "sdk_initialize", code: "complete")
            E2ESafeDiagnostics.record(operation: "sdk_identify", code: "started")
            _ = try await sdk.identify(userJwt: userJwt)
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

    func presentMessenger() {
        guard let presenter, let host = UIApplication.shared.topOnloViewController else {
            E2ESafeDiagnostics.record(operation: "present_messenger", code: "host_unavailable")
            return
        }
        Task {
            do {
                try await presenter.present(from: host)
                E2ESafeDiagnostics.record(operation: "present_messenger", code: "presented")
            } catch {
                E2ESafeDiagnostics.record(operation: "present_messenger", code: safeDiagnosticCode(for: error))
            }
        }
    }

    func logout() async {
        do {
            _ = try await sdk.logout()
            await backend.clearSession()
            isSignedIn = false
            isSupportReady = false
            supportConfiguration = nil
            presenter = nil
            status = "Logged out"
            E2ESafeDiagnostics.record(operation: "merchant_logout", code: "complete")
        } catch {
            status = "Support logout is pending"
            E2ESafeDiagnostics.record(operation: "merchant_logout", code: safeDiagnosticCode(for: error))
        }
    }

    private func safeDiagnosticCode(for error: Error) -> String {
        if let onloError = error as? OnloError { return onloError.safeCode }
        if error is LocalMerchantBackendError { return "merchant_login_rejected" }
        if error is URLError { return "merchant_network_unavailable" }
        if error is DecodingError { return "merchant_invalid_response" }
        return "unexpected_error"
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
    let onloDevelopmentOrigin: URL
}

private enum LocalMerchantBackendError: Error { case rejected }

private actor LocalE2ESDKLogger: SDKLogging {
    func record(_ event: SDKLogEvent) async {
        E2ESafeDiagnostics.record(operation: "sdk_\(event.operation)", code: event.code)
    }
}

/// Writes only fixed operation names and safe error codes. It intentionally
/// excludes login input, SDK keys, JWTs, request headers, message content, and
/// service URLs. The cache file is disposable and never used by the SDK.
private enum E2ESafeDiagnostics {
    private static let logger = Logger(subsystem: "ai.onlo.locale2e", category: "diagnostics")

    static func record(operation: String, code: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) operation=\(operation) code=\(code)\n"
        logger.info("operation=\(operation, privacy: .public) code=\(code, privacy: .public)")
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
}

private extension UIApplication {
    var topOnloViewController: UIViewController? {
        connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }
            .first?.rootViewController
    }
}
