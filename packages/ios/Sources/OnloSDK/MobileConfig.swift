import Foundation
import Security

/// The complete, supported v1 mobile configuration.  All documented fields are
/// required; Codable deliberately ignores additive fields the server may add.
public struct MobileConfig: Codable, Sendable, Equatable {
    public let schemaVersion: Int
    public let revision: String
    public let compatibility: Compatibility
    public let securityPolicy: SecurityPolicy
    public let appearance: Appearance
    public let features: Features
    public let mediaPolicy: MediaPolicy
    public let content: Content
    public let identityMode: IdentityMode
    public let unsupportedWidgetSettings: [UnsupportedWidgetSetting]

    public init(from decoder: Decoder) throws {
        let value = try Self.decodeKnownFields(from: decoder)
        guard value.schemaVersion == 1,
              value.compatibility.requestedSchemaVersion == 1,
              value.compatibility.appliedSchemaVersion == 1,
              value.securityPolicy.minimumProtocolVersion == OnloProtocol.version,
              value.securityPolicy.identityMode == .sdkInterface,
              value.securityPolicy.anonymousScope == .installationGeneration,
              value.securityPolicy.nativePlacement == .hostApp,
              value.identityMode == .sdkInterface else {
            throw OnloError.incompatibleProtocol
        }
        self = value
    }

    private static func decodeKnownFields(from decoder: Decoder) throws -> MobileConfig {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        return try MobileConfig(
            schemaVersion: c.decode(Int.self, forKey: .schemaVersion),
            revision: c.decode(String.self, forKey: .revision),
            compatibility: c.decode(Compatibility.self, forKey: .compatibility),
            securityPolicy: c.decode(SecurityPolicy.self, forKey: .securityPolicy),
            appearance: c.decode(Appearance.self, forKey: .appearance),
            features: c.decode(Features.self, forKey: .features),
            mediaPolicy: c.decode(MediaPolicy.self, forKey: .mediaPolicy),
            content: c.decode(Content.self, forKey: .content),
            identityMode: c.decode(IdentityMode.self, forKey: .identityMode),
            unsupportedWidgetSettings: c.decode([UnsupportedWidgetSetting].self, forKey: .unsupportedWidgetSettings)
        )
    }

    private init(schemaVersion: Int, revision: String, compatibility: Compatibility, securityPolicy: SecurityPolicy, appearance: Appearance, features: Features, mediaPolicy: MediaPolicy, content: Content, identityMode: IdentityMode, unsupportedWidgetSettings: [UnsupportedWidgetSetting]) {
        self.schemaVersion = schemaVersion; self.revision = revision; self.compatibility = compatibility; self.securityPolicy = securityPolicy
        self.appearance = appearance; self.features = features; self.mediaPolicy = mediaPolicy; self.content = content; self.identityMode = identityMode; self.unsupportedWidgetSettings = unsupportedWidgetSettings
    }

    public struct Compatibility: Codable, Sendable, Equatable { public let requestedSchemaVersion: Int; public let appliedSchemaVersion: Int; public let capabilities: [MobileCapability]; public let unsupportedSettings: [UnsupportedSetting] }
    public struct UnsupportedSetting: Codable, Sendable, Equatable { public let code: String; public let setting: String; public let reason: String; public let requiredCapabilities: [MobileCapability]? }
    public struct SecurityPolicy: Codable, Sendable, Equatable {
        public let minimumProtocolVersion: Int; public let minimumSdkVersion: String?; public let identityMode: IdentityMode; public let anonymousScope: AnonymousScope; public let nativePlacement: NativePlacement
        private enum CodingKeys: String, CodingKey { case minimumProtocolVersion, minimumSdkVersion, identityMode, anonymousScope, nativePlacement }
        public init(from decoder: Decoder) throws { let c = try decoder.container(keyedBy: CodingKeys.self); minimumProtocolVersion = try c.decode(Int.self, forKey: .minimumProtocolVersion); minimumSdkVersion = try c.decodeIfPresent(String.self, forKey: .minimumSdkVersion); identityMode = try c.decode(IdentityMode.self, forKey: .identityMode); anonymousScope = try c.decode(AnonymousScope.self, forKey: .anonymousScope); nativePlacement = try c.decode(NativePlacement.self, forKey: .nativePlacement) }
    }
    public struct Appearance: Codable, Sendable, Equatable { public let accent: String; public let botName: String; public let botSubtitle: String; public let greeting: String; public let headerAvatar: HeaderAvatar; public let light: ColorTheme; public let dark: DarkColorTheme }
    public struct HeaderAvatar: Codable, Sendable, Equatable {
        public let mode: AvatarMode; public let text: String; public let data: String?
        private enum CodingKeys: String, CodingKey { case mode, text, data }
        public init(from decoder: Decoder) throws { let c = try decoder.container(keyedBy: CodingKeys.self); mode = try c.decode(AvatarMode.self, forKey: .mode); text = try c.decode(String.self, forKey: .text); data = try c.decodeIfPresent(String.self, forKey: .data) }
    }
    public struct ColorTheme: Codable, Sendable, Equatable { public let background: String; public let outgoing: String; public let outgoingText: String; public let incoming: String; public let incomingText: String }
    public struct DarkColorTheme: Codable, Sendable, Equatable { public let enabled: Bool; public let background: String; public let outgoing: String; public let outgoingText: String; public let incoming: String; public let incomingText: String }
    public struct Features: Codable, Sendable, Equatable { public let insertLink: Bool; public let insertCode: Bool; public let emoji: Bool; public let gifs: Bool; public let voice: Bool; public let fileUpload: Bool; public let transcriptDownload: Bool; public let soundNotifications: Bool; public let showTimestamps: Bool; public let faqButton: FAQButton }
    public struct MediaPolicy: Codable, Sendable, Equatable {
        public let enabled: Bool
        public let maximumImagesPerMessage: Int
        public let maximumImageBytes: Int

        private enum CodingKeys: String, CodingKey {
            case enabled, maximumImagesPerMessage, maximumImageBytes
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            enabled = try c.decode(Bool.self, forKey: .enabled)
            maximumImagesPerMessage = try c.decode(Int.self, forKey: .maximumImagesPerMessage)
            maximumImageBytes = try c.decode(Int.self, forKey: .maximumImageBytes)
            guard (0...OnloProtocol.maximumImagesPerMessage).contains(maximumImagesPerMessage),
                  (1...OnloProtocol.maximumImageBytes).contains(maximumImageBytes) else {
                throw OnloError.invalidResponse
            }
        }

        public var effectiveMaximumImagesPerMessage: Int {
            min(maximumImagesPerMessage, OnloProtocol.maximumImagesPerMessage)
        }

        public var effectiveMaximumImageBytes: Int {
            min(maximumImageBytes, OnloProtocol.maximumImageBytes)
        }
    }
    public struct FAQButton: Codable, Sendable, Equatable { public let enabled: Bool; public let label: String }
    public struct Content: Codable, Sendable, Equatable { public let faqs: [FAQ]; public let tabs: Tabs; public let search: Search; public let onboarding: Onboarding; public let homeSections: [HomeSection] }
    public struct FAQ: Codable, Sendable, Equatable { public let question: String; public let answer: String? }
    public struct Tabs: Codable, Sendable, Equatable { public let enabled: Bool; public let tabs: [Tab]; public let defaultTab: String }
    public struct Tab: Codable, Sendable, Equatable { public let id: String; public let label: String; public let icon: String; public let enabled: Bool }
    public struct Search: Codable, Sendable, Equatable { public let enabled: Bool; public let placeholder: String; public let showSearchInHome: Bool }
    public struct Onboarding: Codable, Sendable, Equatable { public let enabled: Bool; public let title: String; public let showProgress: Bool; public let items: [OnboardingItem] }
    public struct OnboardingItem: Codable, Sendable, Equatable { public let id: String; public let title: String; public let description: String?; public let completed: Bool; public let actionUrl: String? }
    public struct HomeSection: Codable, Sendable, Equatable { public let id: String; public let type: HomeSectionType; public let title: String?; public let content: String?; public let enabled: Bool; public let order: Int }
    public struct UnsupportedWidgetSetting: Codable, Sendable, Equatable { public let setting: String; public let reason: String }
}

public enum MobileCapability: String, Codable, Sendable, Equatable { case secureStorage = "secure_storage", persistentOutbox = "persistent_outbox", foregroundStream = "foreground_stream", apns, fcm, mediaPicker = "media_picker", attachmentUpload = "attachment_upload", configSchemaV1 = "config_schema_v1", identityJWT = "identity_jwt", appAttestation = "app_attestation", deepLinkRouting = "deep_link_routing" }
public enum IdentityMode: String, Codable, Sendable, Equatable { case sdkInterface = "sdk_interface" }
public enum AnonymousScope: String, Codable, Sendable, Equatable { case installationGeneration = "installation_generation" }
public enum NativePlacement: String, Codable, Sendable, Equatable { case hostApp = "host_app" }
public enum AvatarMode: String, Codable, Sendable, Equatable { case image, initials }
public enum HomeSectionType: String, Codable, Sendable, Equatable { case welcome, search, faqs, checklist, custom }

struct ProtectedMobileConfigState: Codable, Sendable, Equatable {
    let config: MobileConfig?
    let etag: String?
    let retry: ConfigRetryState?
}

extension ProtectedMobileConfigState {
    func validated() throws -> ProtectedMobileConfigState {
        // A retry-only state has neither value. Every cached configuration must
        // have the validator that authorises its conditional reuse, and vice versa.
        guard (config == nil) == (etag == nil) else { throw OnloError.credentialStore(code: "config_state_invariant_failed") }
        return self
    }
}

enum ConfigRetryState: Codable, Sendable, Equatable { case afterBackoff(eligibleAt: Date, attempt: Int) }

protocol MobileConfigStoring: Sendable {
    func loadConfigState() async throws -> ProtectedMobileConfigState
    func saveConfigState(_ state: ProtectedMobileConfigState) async throws
}

protocol AuthorityFencedConfigStoring: Sendable {
    func activateAuthority(_ authority: PersistenceAuthority) async
    func revokeAuthority(for scope: OwnerScope) async
    func saveConfigState(
        _ state: ProtectedMobileConfigState,
        authority: PersistenceAuthority
    ) async throws -> Bool
}

/// A single Keychain record makes config and ETag updates atomic and prevents a
/// process observing a new ETag beside an older configuration. Keychain is the
/// protected/encrypted persistence boundary; no configuration is stored in
/// UserDefaults or an ordinary file.
actor KeychainMobileConfigStore: MobileConfigStoring, AuthorityFencedConfigStoring {
    private let service = "ai.onlo.sdk.mobile-config"
    private let account = "v1"
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var activeAuthority: PersistenceAuthority?

    func loadConfigState() async throws -> ProtectedMobileConfigState {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return ProtectedMobileConfigState(config: nil, etag: nil, retry: nil) }
        guard status == errSecSuccess, let data = result as? Data else { throw OnloError.credentialStore(code: "config_keychain_read_failed") }
        do { return try decoder.decode(ProtectedMobileConfigState.self, from: data).validated() }
        catch { throw OnloError.credentialStore(code: "config_keychain_decode_failed") }
    }

    func saveConfigState(_ state: ProtectedMobileConfigState) async throws {
        try saveConfigStateSynchronously(state)
    }

    private func saveConfigStateSynchronously(_ state: ProtectedMobileConfigState) throws {
        _ = try state.validated()
        let data: Data
        do { data = try encoder.encode(state) } catch { throw OnloError.credentialStore(code: "config_keychain_encode_failed") }
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        let attributes: [String: Any] = [kSecValueData as String: data, kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let update = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw OnloError.credentialStore(code: "config_keychain_write_failed") }
        var add = query; add.merge(attributes) { _, new in new }
        guard SecItemAdd(add as CFDictionary, nil) == errSecSuccess else { throw OnloError.credentialStore(code: "config_keychain_write_failed") }
    }

    func activateAuthority(_ authority: PersistenceAuthority) {
        activeAuthority = authority
    }

    func revokeAuthority(for scope: OwnerScope) {
        if activeAuthority?.ownerScope == scope { activeAuthority = nil }
    }

    func saveConfigState(
        _ state: ProtectedMobileConfigState,
        authority: PersistenceAuthority
    ) async throws -> Bool {
        guard activeAuthority == authority else { return false }
        try saveConfigStateSynchronously(state)
        return true
    }
}
