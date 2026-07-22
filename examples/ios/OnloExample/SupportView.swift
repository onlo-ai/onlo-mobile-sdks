import OnloSDK
import SwiftUI
import UIKit

/// A merchant-hosted entry point. The host provides only a public SDK key and
/// a callback to its already-authenticated backend. It never signs, stores, or
/// decodes the returned Onlo user JWT.
struct SupportView: View {
    typealias OnloUserJwtProvider = @Sendable () async throws -> String

    let sdkKey: String
    let fetchOnloUserJwt: OnloUserJwtProvider

    @State private var sdk = OnloSDK()
    @State private var presenter: OnloMessengerPresenter?
    @State private var status = "Preparing support"
    @State private var isIdentified = false

    init(sdkKey: String, fetchOnloUserJwt: @escaping OnloUserJwtProvider) {
        self.sdkKey = sdkKey
        self.fetchOnloUserJwt = fetchOnloUserJwt
    }

    var body: some View {
        VStack(spacing: 16) {
            Text(status).multilineTextAlignment(.center)
            Button("Connect signed-in customer") {
                Task { await identifyCurrentMerchantCustomer() }
            }
            .disabled(presenter == nil || isIdentified)
            Button("Support") { presentMessenger() }
                .disabled(presenter == nil)
            Button("Log out of support") {
                Task { await logoutFromSupport() }
            }
            .disabled(presenter == nil || !isIdentified)
        }
        .padding()
        .task { await initialize() }
    }

    @MainActor
    private func initialize() async {
        do {
            _ = try await sdk.initialize(apiKey: sdkKey)
            presenter = OnloMessengerPresenter(sdk: sdk)
            status = "Support ready"
        } catch {
            status = "Support is unavailable"
        }
    }

    @MainActor
    private func identifyCurrentMerchantCustomer() async {
        do {
            let userJwt = try await fetchOnloUserJwt()
            _ = try await sdk.identify(userJwt: userJwt)
            isIdentified = true
            status = "Signed-in support ready"
        } catch {
            status = "Could not connect the signed-in customer"
        }
    }

    @MainActor
    private func presentMessenger() {
        guard let presenter, let host = UIApplication.shared.topOnloViewController else { return }
        Task { try? await presenter.present(from: host) }
    }

    @MainActor
    private func logoutFromSupport() async {
        do {
            _ = try await sdk.logout()
            isIdentified = false
            status = "Support logged out"
        } catch {
            status = "Support logout is pending"
        }
    }
}

private extension UIApplication {
    var topOnloViewController: UIViewController? {
        connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }
            .first?.rootViewController
    }
}
