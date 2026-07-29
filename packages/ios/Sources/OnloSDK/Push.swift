import Foundation
import Security

/// Owner-bound APNs registration work. The token is protected Keychain data and
/// can never be reused after its recorded owner scope is no longer current.
struct ProtectedPushIntent: Codable, Sendable, Equatable {
    enum Action: String, Codable, Sendable { case register, unregister }

    let ownerScope: OwnerScope
    let action: Action
    let token: String?
    let notificationPreference: PushTokenRequest.NotificationPreference?
    let locale: String?
    let attemptCount: Int
    let eligibleAt: Date?
    /// The exact v1 directive that produced this pending state. A transport
    /// failure has no directive; it is separately bounded local retry work.
    let retryDirective: RetryDirective?
    /// A process-death-safe prerequisite: a fresh bearer must be obtained
    /// before this intent can be retried. It is never inferred from a token.
    let requiresFreshBearer: Bool
    /// A completed active registration is retained to avoid duplicate writes
    /// while this owner remains current; it is not work to replay.
    let isRegistered: Bool
    /// False means a server prerequisite cannot be supplied by this SDK build
    /// or a `never` directive was received. A new host action is required.
    let automaticallyRetryable: Bool

    init(
        ownerScope: OwnerScope,
        action: Action,
        token: String? = nil,
        notificationPreference: PushTokenRequest.NotificationPreference? = nil,
        locale: String? = nil,
        attemptCount: Int = 0,
        eligibleAt: Date? = nil,
        retryDirective: RetryDirective? = nil,
        requiresFreshBearer: Bool = false,
        isRegistered: Bool = false,
        automaticallyRetryable: Bool = true
    ) {
        self.ownerScope = ownerScope
        self.action = action
        self.token = token
        self.notificationPreference = notificationPreference
        self.locale = locale
        self.attemptCount = attemptCount
        self.eligibleAt = eligibleAt
        self.retryDirective = retryDirective
        self.requiresFreshBearer = requiresFreshBearer
        self.isRegistered = isRegistered
        self.automaticallyRetryable = automaticallyRetryable
    }
}

/// The SDK never asks for notification permission. The host supplies an APNs
/// token only after its own permission and registration flow.
public enum OnloPushRegistrationState: Sendable, Equatable {
    case registered
    case pendingRetry
    case requiresHostAction
}

/// A push is only a refetch hint. Returning an intent does not present UI or
/// navigate; the host retains control of messenger placement.
public enum OnloPushNotificationHandling: Sendable, Equatable {
    case handled(OnloPresentationIntent)
    case deferred
    case notOnlo
}

protocol PushIntentStoring: Sendable {
    func load() async throws -> ProtectedPushIntent?
    func save(_ intent: ProtectedPushIntent) async throws
    func clear() async throws
}

protocol AuthorityFencedPushIntentStoring: Sendable {
    func activateAuthority(_ authority: PersistenceAuthority) async
    func revokeAuthority(for scope: OwnerScope) async
    func save(_ intent: ProtectedPushIntent, authority: PersistenceAuthority) async throws -> Bool
    func save(
        _ intent: ProtectedPushIntent,
        replacing expected: ProtectedPushIntent,
        authority: PersistenceAuthority
    ) async throws -> Bool
    func clear(authority: PersistenceAuthority) async throws -> Bool
    func clear(replacing expected: ProtectedPushIntent, authority: PersistenceAuthority) async throws -> Bool
}

/// A single protected record is sufficient because an installation can only
/// have one current owner scope. It is deliberately separate from the session
/// credential record so retry metadata cannot alter session transitions.
actor KeychainPushIntentStore: PushIntentStoring, AuthorityFencedPushIntentStoring {
    private let service = "ai.onlo.sdk.push-intent"
    private let account = "v1"
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var activeAuthority: PersistenceAuthority?

    func load() async throws -> ProtectedPushIntent? {
        try loadSynchronously()
    }

    private func loadSynchronously() throws -> ProtectedPushIntent? {
        var query: [String: Any] = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw OnloError.credentialStore(code: "push_intent_read_failed") }
        do { return try decoder.decode(ProtectedPushIntent.self, from: data) }
        catch { throw OnloError.credentialStore(code: "push_intent_decode_failed") }
    }

    func save(_ intent: ProtectedPushIntent) async throws {
        try saveSynchronously(intent)
    }

    private func saveSynchronously(_ intent: ProtectedPushIntent) throws {
        let data: Data
        do { data = try encoder.encode(intent) }
        catch { throw OnloError.credentialStore(code: "push_intent_encode_failed") }
        let attributes: [String: Any] = [kSecValueData as String: data, kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let update = SecItemUpdate(baseQuery as CFDictionary, attributes as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw OnloError.credentialStore(code: "push_intent_write_failed") }
        var add = baseQuery
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        guard SecItemAdd(add as CFDictionary, nil) == errSecSuccess else { throw OnloError.credentialStore(code: "push_intent_write_failed") }
    }

    func clear() async throws {
        try clearSynchronously()
    }

    private func clearSynchronously() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw OnloError.credentialStore(code: "push_intent_delete_failed") }
    }

    func activateAuthority(_ authority: PersistenceAuthority) {
        activeAuthority = authority
    }

    func revokeAuthority(for scope: OwnerScope) {
        if activeAuthority?.ownerScope == scope { activeAuthority = nil }
    }

    func save(_ intent: ProtectedPushIntent, authority: PersistenceAuthority) async throws -> Bool {
        guard activeAuthority == authority, intent.ownerScope == authority.ownerScope else { return false }
        try saveSynchronously(intent)
        return true
    }

    func save(
        _ intent: ProtectedPushIntent,
        replacing expected: ProtectedPushIntent,
        authority: PersistenceAuthority
    ) async throws -> Bool {
        guard activeAuthority == authority,
              intent.ownerScope == authority.ownerScope,
              try loadSynchronously() == expected else { return false }
        try saveSynchronously(intent)
        return true
    }

    func clear(authority: PersistenceAuthority) async throws -> Bool {
        guard activeAuthority == authority else { return false }
        try clearSynchronously()
        return true
    }

    func clear(replacing expected: ProtectedPushIntent, authority: PersistenceAuthority) async throws -> Bool {
        guard activeAuthority == authority,
              try loadSynchronously() == expected else { return false }
        try clearSynchronously()
        return true
    }

    private var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }
}

actor InMemoryPushIntentStore: PushIntentStoring, AuthorityFencedPushIntentStoring {
    private var intent: ProtectedPushIntent?
    private var activeAuthority: PersistenceAuthority?
    func load() async throws -> ProtectedPushIntent? { intent }
    func save(_ intent: ProtectedPushIntent) async throws { self.intent = intent }
    func clear() async throws { intent = nil }
    func activateAuthority(_ authority: PersistenceAuthority) { activeAuthority = authority }
    func revokeAuthority(for scope: OwnerScope) {
        if activeAuthority?.ownerScope == scope { activeAuthority = nil }
    }
    func save(_ intent: ProtectedPushIntent, authority: PersistenceAuthority) async throws -> Bool {
        guard activeAuthority == authority, intent.ownerScope == authority.ownerScope else { return false }
        self.intent = intent
        return true
    }
    func save(
        _ intent: ProtectedPushIntent,
        replacing expected: ProtectedPushIntent,
        authority: PersistenceAuthority
    ) async throws -> Bool {
        guard activeAuthority == authority,
              intent.ownerScope == authority.ownerScope,
              self.intent == expected else { return false }
        self.intent = intent
        return true
    }
    func clear(authority: PersistenceAuthority) async throws -> Bool {
        guard activeAuthority == authority else { return false }
        intent = nil
        return true
    }
    func clear(replacing expected: ProtectedPushIntent, authority: PersistenceAuthority) async throws -> Bool {
        guard activeAuthority == authority, intent == expected else { return false }
        intent = nil
        return true
    }
}
