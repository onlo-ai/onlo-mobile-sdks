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

    @State private var status = "Preparing support"
    @State private var supportReady = false
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
            .disabled(!supportReady || isIdentified)
            Button("Support") { presentMessenger() }
                .disabled(!supportReady)
            Button("Enable support notifications") {
                (UIApplication.shared.delegate as? OnloExampleAppDelegate)?
                    .requestSupportNotificationPermission()
            }
            .disabled(!isIdentified)
            Button("Log out of support") {
                Task { await logoutFromSupport() }
            }
            .disabled(!supportReady || !isIdentified)
        }
        .padding()
        .task { await initialize() }
    }

    @MainActor
    private func initialize() async {
        do {
            _ = try await Onlo.initialize(apiKey: sdkKey)
            supportReady = true
            status = "Support ready"
        } catch {
            status = "Support is unavailable"
        }
    }

    @MainActor
    private func identifyCurrentMerchantCustomer() async {
        do {
            let userJwt = try await fetchOnloUserJwt()
            _ = try await Onlo.loginIdentifiedUser(userJwt: userJwt)
            isIdentified = true
            status = "Signed-in support ready"
        } catch {
            status = "Could not connect the signed-in customer"
        }
    }

    @MainActor
    private func presentMessenger() {
        guard let host = UIApplication.shared.topOnloViewController else { return }
        Task { try? await Onlo.present(from: host) }
    }

    @MainActor
    private func logoutFromSupport() async {
        do {
            (UIApplication.shared.delegate as? OnloExampleAppDelegate)?
                .clearPendingSupportNotification()
            _ = try await Onlo.logout()
            isIdentified = false
            status = "Support logged out"
        } catch {
            status = "Support logout is pending"
        }
    }
}
