import Foundation
import Security
import CryptoKit
#if canImport(SQLite3)
import SQLite3
#else
import CSQLite
#endif

enum InstallationCredential {
    private static let byteCount = 32

    static func generate() -> String {
        var generator = SystemRandomNumberGenerator()
        let bytes = (0..<byteCount).map { _ in
            UInt8.random(in: .min ... .max, using: &generator)
        }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// A non-identity-bearing local partition key. It is never derived from an email,
/// phone number, JWT subject, or raw user JWT.
public struct OwnerScope: Codable, Sendable, Hashable, Equatable {
    public enum Kind: String, Codable, Sendable { case anonymous, identified }

    public let kind: Kind
    public let id: UUID

    public init(kind: Kind, id: UUID = UUID()) {
        self.kind = kind
        self.id = id
    }
}

/// The only session material persisted by the core. The credential is written only
/// through `CredentialStoring`, whose production implementation is Keychain-backed.
public struct StoredSessionCredential: Codable, Sendable, Equatable {
    public let installationId: String
    public let generation: Int
    public let proposedCredential: String
    public let identityClass: IdentityClass
    public let ownerScope: OwnerScope
    public let logoutPending: Bool

    public init(
        installationId: String,
        generation: Int,
        proposedCredential: String,
        identityClass: IdentityClass,
        ownerScope: OwnerScope,
        logoutPending: Bool = false
    ) {
        self.installationId = installationId
        self.generation = generation
        self.proposedCredential = proposedCredential
        self.identityClass = identityClass
        self.ownerScope = ownerScope
        self.logoutPending = logoutPending
    }
}

/// Protected recovery metadata for a session request whose response may have
/// been lost. It intentionally excludes a user JWT and any user-derived data.
enum PendingSessionTransition: Codable, Sendable, Equatable {
    case bootstrap(transitionId: String, installationId: String, proposedCredential: String)
    case resume(transitionId: String, installationId: String, expectedGeneration: Int, presentedCredential: String, proposedCredential: String)
    case identify(transitionId: String, installationId: String, expectedGeneration: Int, presentedCredential: String, proposedCredential: String)
    case logout(transitionId: String, installationId: String, expectedGeneration: Int, presentedCredential: String, proposedCredential: String)

    private enum CodingKeys: String, CodingKey { case type, transitionId, installationId, expectedGeneration, presentedCredential, proposedCredential }
    private enum Kind: String, Codable { case bootstrap, resume, identify, logout }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .type)
        let transitionId = try container.decode(String.self, forKey: .transitionId)
        let installationId = try container.decode(String.self, forKey: .installationId)
        let proposedCredential = try container.decode(String.self, forKey: .proposedCredential)
        switch kind {
        case .bootstrap:
            self = .bootstrap(transitionId: transitionId, installationId: installationId, proposedCredential: proposedCredential)
        case .resume, .identify, .logout:
            let expectedGeneration = try container.decode(Int.self, forKey: .expectedGeneration)
            let presentedCredential = try container.decode(String.self, forKey: .presentedCredential)
            switch kind {
            case .resume: self = .resume(transitionId: transitionId, installationId: installationId, expectedGeneration: expectedGeneration, presentedCredential: presentedCredential, proposedCredential: proposedCredential)
            case .identify: self = .identify(transitionId: transitionId, installationId: installationId, expectedGeneration: expectedGeneration, presentedCredential: presentedCredential, proposedCredential: proposedCredential)
            case .logout: self = .logout(transitionId: transitionId, installationId: installationId, expectedGeneration: expectedGeneration, presentedCredential: presentedCredential, proposedCredential: proposedCredential)
            case .bootstrap: fatalError("unreachable")
            }
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .bootstrap(transitionId, installationId, proposedCredential):
            try container.encode(Kind.bootstrap, forKey: .type)
            try container.encode(transitionId, forKey: .transitionId)
            try container.encode(installationId, forKey: .installationId)
            try container.encode(proposedCredential, forKey: .proposedCredential)
        case let .resume(transitionId, installationId, expectedGeneration, presentedCredential, proposedCredential),
             let .identify(transitionId, installationId, expectedGeneration, presentedCredential, proposedCredential),
             let .logout(transitionId, installationId, expectedGeneration, presentedCredential, proposedCredential):
            let kind: Kind
            switch self { case .resume: kind = .resume; case .identify: kind = .identify; case .logout: kind = .logout; case .bootstrap: fatalError("unreachable") }
            try container.encode(kind, forKey: .type)
            try container.encode(transitionId, forKey: .transitionId)
            try container.encode(installationId, forKey: .installationId)
            try container.encode(expectedGeneration, forKey: .expectedGeneration)
            try container.encode(presentedCredential, forKey: .presentedCredential)
            try container.encode(proposedCredential, forKey: .proposedCredential)
        }
    }

    func sessionOperation(userJwt: String? = nil) throws -> SessionOperation {
        switch self {
        case let .bootstrap(transitionId, _, proposedCredential): return .bootstrap(transitionId: transitionId, proposedCredential: proposedCredential, userJwt: nil)
        case let .resume(transitionId, _, expectedGeneration, presentedCredential, proposedCredential): return .resume(transitionId: transitionId, expectedGeneration: expectedGeneration, presentedCredential: presentedCredential, proposedCredential: proposedCredential)
        case let .identify(transitionId, _, expectedGeneration, presentedCredential, proposedCredential):
            guard let userJwt else { throw OnloError.invalidState }
            return .identify(transitionId: transitionId, expectedGeneration: expectedGeneration, presentedCredential: presentedCredential, proposedCredential: proposedCredential, userJwt: userJwt)
        case let .logout(transitionId, _, expectedGeneration, presentedCredential, proposedCredential): return .logout(transitionId: transitionId, expectedGeneration: expectedGeneration, presentedCredential: presentedCredential, proposedCredential: proposedCredential)
        }
    }
}

extension PendingSessionTransition {
    var installationId: String {
        switch self {
        case let .bootstrap(_, installationId, _), let .resume(_, installationId, _, _, _), let .identify(_, installationId, _, _, _), let .logout(_, installationId, _, _, _): return installationId
        }
    }

    var isBootstrap: Bool { if case .bootstrap = self { return true }; return false }
    var isIdentify: Bool { if case .identify = self { return true }; return false }

    var usesLegacyUUIDCredential: Bool {
        let proposedCredential: String
        switch self {
        case let .bootstrap(_, _, value),
             let .resume(_, _, _, _, value),
             let .identify(_, _, _, _, value),
             let .logout(_, _, _, _, value):
            proposedCredential = value
        }
        return UUID(uuidString: proposedCredential) != nil
    }

    func matchesResume(_ credential: StoredSessionCredential) -> Bool {
        guard case let .resume(_, installationId, generation, presentedCredential, _) = self else { return false }
        return installationId == credential.installationId && generation == credential.generation && presentedCredential == credential.proposedCredential
    }

    func matchesLogout(_ credential: StoredSessionCredential) -> Bool {
        guard case let .logout(_, installationId, generation, presentedCredential, _) = self else { return false }
        return installationId == credential.installationId && generation == credential.generation && presentedCredential == credential.proposedCredential
    }

    func accepts(_ result: SessionResult) -> Bool {
        switch self {
        case let .bootstrap(_, installationId, proposedCredential),
             let .resume(_, installationId, _, _, proposedCredential),
             let .identify(_, installationId, _, _, proposedCredential),
             let .logout(_, installationId, _, _, proposedCredential):
            return installationId == result.installationId && proposedCredential == result.proposedCredential
        }
    }
}

/// All session recovery state is one Keychain value so a process cannot observe
/// a newly committed credential beside a stale completed transition.
struct ProtectedSessionState: Codable, Sendable, Equatable {
    var credential: StoredSessionCredential?
    var pendingTransition: PendingSessionTransition?
    var retryGate: SessionRetryGate?
}

enum SessionRetryGate: Codable, Sendable, Equatable {
    case afterTokenRefresh
    case afterAttestation
    case afterBackoff(eligibleAt: Date, fallbackAttempt: Int)
}

protocol CredentialStoring: Sendable {
    func loadState() async throws -> ProtectedSessionState
    func saveState(_ state: ProtectedSessionState) async throws
}

/// Keychain-backed protected credential storage. It never falls back to files,
/// UserDefaults, or another ordinary persistence mechanism.
final class KeychainCredentialStore: CredentialStoring, @unchecked Sendable {
    private let service: String
    private let account: String
    private let accessGroup: String?
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(
        service: String = "ai.onlo.sdk.session",
        account: String = "primary",
        accessGroup: String? = nil
    ) {
        self.service = service
        self.account = account
        self.accessGroup = accessGroup
    }

    func loadState() async throws -> ProtectedSessionState {
        if let state = try await load(ProtectedSessionState.self, account: stateAccount) { return state }
        // Pre-release migration: promote the old protected items into one record
        // before deleting them. A crash leaves either the new authoritative value
        // or the old values intact; it never combines generations.
        let legacyCredential = try await load(StoredSessionCredential.self, account: account)
        let accountScopedLegacyPending = try await load(PendingSessionTransition.self, account: legacyPendingAccount)
        let legacyPending: PendingSessionTransition?
        if let accountScopedLegacyPending {
            legacyPending = accountScopedLegacyPending
        } else {
            legacyPending = try await load(PendingSessionTransition.self, account: "pending-transition")
        }
        let state = ProtectedSessionState(credential: legacyCredential, pendingTransition: legacyPending, retryGate: nil)
        guard legacyCredential != nil || legacyPending != nil else { return state }
        try await save(state, account: stateAccount)
        try await delete(account: account)
        try await delete(account: legacyPendingAccount)
        if legacyPendingAccount != "pending-transition" { try await delete(account: "pending-transition") }
        return state
    }

    func saveState(_ state: ProtectedSessionState) async throws {
        try await save(state, account: stateAccount)
    }

    private func load<Value: Decodable>(_ type: Value.Type, account: String) async throws -> Value? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw OnloError.credentialStore(code: "keychain_read_failed") }
        do { return try decoder.decode(type, from: data) } catch { throw OnloError.credentialStore(code: "keychain_decode_failed") }
    }

    private func save<Value: Encodable>(_ value: Value, account: String) async throws {
        let data: Data
        do { data = try encoder.encode(value) } catch { throw OnloError.credentialStore(code: "keychain_encode_failed") }
        let updateAttributes: [String: Any] = [kSecValueData as String: data, kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let updateStatus = SecItemUpdate(baseQuery(account: account) as CFDictionary, updateAttributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else { throw OnloError.credentialStore(code: "keychain_write_failed") }
        var addQuery = baseQuery(account: account)
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        guard SecItemAdd(addQuery as CFDictionary, nil) == errSecSuccess else { throw OnloError.credentialStore(code: "keychain_write_failed") }
    }

    private func delete(account: String) async throws {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw OnloError.credentialStore(code: "keychain_delete_failed") }
    }

    private func baseQuery(account: String? = nil) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account ?? self.account,
        ]
        if let accessGroup { query[kSecAttrAccessGroup as String] = accessGroup }
        return query
    }

    private var stateAccount: String { "\(account).protected-state" }
    private var legacyPendingAccount: String { "\(account).pending-transition" }
}

public enum OutboxState: String, Codable, Sendable, Equatable {
    case queued
    case sending
    case accepted
    case reconciled
    case failedRetryable = "failed_retryable"
    case failedTerminal = "failed_terminal"
    case cancelled
}

/// A durable outbox attachment reference. Do not write raw attachment URLs to logs.
public struct OutboxAttachment: Codable, Sendable, Equatable {
    public let attachment: ChatAttachment
    public let receiptExpiresAt: String?
    let stagedData: Data?
    let uploadConversationId: String?

    public init(attachment: ChatAttachment, receiptExpiresAt: String? = nil) {
        self.attachment = attachment
        self.receiptExpiresAt = receiptExpiresAt
        self.stagedData = nil
        self.uploadConversationId = nil
    }

    init(
        attachment: ChatAttachment,
        grantExpiresAt: String,
        stagedData: Data,
        uploadConversationId: String?
    ) {
        self.attachment = attachment
        self.receiptExpiresAt = grantExpiresAt
        self.stagedData = stagedData
        self.uploadConversationId = uploadConversationId
    }
}

/// A message is inserted before network work. `clientMessageId` is immutable and
/// must be reused with the same logical payload for every retry.
public struct OutboxEntry: Codable, Sendable, Equatable {
    public let clientMessageId: UUID
    public let ownerScope: OwnerScope
    public let conversationId: String?
    public let routingSessionId: String?
    public let message: String
    public let attachments: [OutboxAttachment]
    public let createdAt: Date
    public let orderingKey: Int64
    public var state: OutboxState
    public var attemptCount: Int
    public var nextAttemptAt: Date?
    public var lastErrorCode: String?
    public var serverMessageId: String?
    public var aiRunId: String?

    public init(
        clientMessageId: UUID = UUID(),
        ownerScope: OwnerScope,
        conversationId: String? = nil,
        routingSessionId: String? = nil,
        message: String,
        attachments: [OutboxAttachment] = [],
        createdAt: Date = Date(),
        orderingKey: Int64,
        state: OutboxState = .queued,
        attemptCount: Int = 0,
        nextAttemptAt: Date? = nil,
        lastErrorCode: String? = nil,
        serverMessageId: String? = nil,
        aiRunId: String? = nil
    ) {
        self.clientMessageId = clientMessageId
        self.ownerScope = ownerScope
        self.conversationId = conversationId
        self.routingSessionId = routingSessionId
        self.message = message
        self.attachments = attachments
        self.createdAt = createdAt
        self.orderingKey = orderingKey
        self.state = state
        self.attemptCount = attemptCount
        self.nextAttemptAt = nextAttemptAt
        self.lastErrorCode = lastErrorCode
        self.serverMessageId = serverMessageId
        self.aiRunId = aiRunId
    }
}

/// Isolates protected, durable owner data from the session core. Every operation
/// is owner-scoped so User A's rows cannot become eligible for User B.
public protocol OwnerScopedPersisting: Sendable {
    func prepare(scope: OwnerScope) async throws
    func beginLogout(for scope: OwnerScope) async throws
    func finishLogout(for scope: OwnerScope) async throws
    func enqueue(_ entry: OutboxEntry) async throws
    func enqueueAssigningOrder(_ entry: OutboxEntry) async throws -> OutboxEntry
    func update(_ entry: OutboxEntry) async throws
    func outboxEntries(for scope: OwnerScope) async throws -> [OutboxEntry]
    /// Recovers interrupted sends after process restart and returns only entries
    /// eligible for dispatch. Ordering is retained by each entry's stable key.
    func recoverEligibleEntries(for scope: OwnerScope, now: Date) async throws -> [OutboxEntry]
}

protocol TranscriptPersisting: Sendable {
    func replaceTranscript(_ transcript: ConversationTranscriptResult, for scope: OwnerScope) async throws
    func transcript(conversationId: String, for scope: OwnerScope) async throws -> ConversationTranscriptResult?
}

struct PersistenceAuthority: Sendable, Equatable {
    let ownerScope: OwnerScope
    let sessionGeneration: Int
    let sessionId: String
    let bearerContext: UUID
}

protocol AuthorityFencedPersisting: Sendable {
    func activateAuthority(_ authority: PersistenceAuthority) async
    func revokeAuthority(for scope: OwnerScope) async
    func update(
        _ entry: OutboxEntry,
        expectedState: OutboxState,
        expectedAttemptCount: Int,
        authority: PersistenceAuthority
    ) async throws -> Bool
    func recoverEligibleEntries(
        for scope: OwnerScope,
        now: Date,
        authority: PersistenceAuthority
    ) async throws -> [OutboxEntry]?
    func replaceTranscript(
        _ transcript: ConversationTranscriptResult,
        authority: PersistenceAuthority
    ) async throws -> Bool
    func replaceConversationList(
        _ conversationList: ConversationListResult,
        authority: PersistenceAuthority
    ) async throws -> Bool
    func conversationList(
        authority: PersistenceAuthority
    ) async throws -> ConversationListResult?
    func reconcileAccepted(
        _ entry: OutboxEntry,
        transcript: ConversationTranscriptResult,
        expectedServerMessageId: String,
        authority: PersistenceAuthority
    ) async throws -> Bool
}

protocol OutboxEncryptionKeyStoring: Sendable {
    func loadOrCreate() async throws -> SymmetricKey
}

private final class KeychainOutboxEncryptionKeyStore: OutboxEncryptionKeyStoring, @unchecked Sendable {
    private let service = "ai.onlo.sdk.outbox-key"
    private let account = "v1"

    func loadOrCreate() async throws -> SymmetricKey {
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecSuccess, let data = result as? Data { return SymmetricKey(data: data) }
        guard status == errSecItemNotFound else { throw OnloError.credentialStore(code: "outbox_key_read_failed") }

        let key = SymmetricKey(size: .bits256)
        let data = key.withUnsafeBytes { Data($0) }
        query.removeValue(forKey: kSecReturnData as String)
        query.removeValue(forKey: kSecMatchLimit as String)
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(query as CFDictionary, nil)
        if addStatus == errSecSuccess { return key }
        if addStatus == errSecDuplicateItem { return try await loadOrCreate() }
        throw OnloError.credentialStore(code: "outbox_key_write_failed")
    }
}

/// SQLite-backed durable outbox. The database has iOS file protection and is
/// excluded from backups. Message, attachment, conversation, and server payload
/// fields are AES-GCM encrypted; only opaque scope, status, and ordering metadata
/// remain available for queue scheduling.
public actor SQLiteOwnerScopedStore: OwnerScopedPersisting, TranscriptPersisting, AuthorityFencedPersisting {
    private final class SQLiteConnection: @unchecked Sendable {
        let handle: OpaquePointer

        init(handle: OpaquePointer) { self.handle = handle }

        deinit { sqlite3_close(handle) }
    }

    private struct EncryptedPayload: Codable, Sendable {
        let conversationId: String?
        let routingSessionId: String?
        let message: String
        let attachments: [OutboxAttachment]
        let createdAt: Date
        let lastErrorCode: String?
        let serverMessageId: String?
        let aiRunId: String?
    }

    private let databaseURL: URL
    private let keyStore: any OutboxEncryptionKeyStoring
    private var connection: SQLiteConnection?
    private var encryptionKey: SymmetricKey?
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var activeAuthority: PersistenceAuthority?

    public init() {
        self.databaseURL = Self.defaultDatabaseURL()
        self.keyStore = KeychainOutboxEncryptionKeyStore()
    }

    init(databaseURL: URL, keyStore: any OutboxEncryptionKeyStoring) {
        self.databaseURL = databaseURL
        self.keyStore = keyStore
    }

    public func prepare(scope: OwnerScope) async throws {
        let db = try await database()
        try transaction(db) {
            if try isBlocked(scope, db: db) { throw OnloError.invalidState }
            try execute("INSERT OR IGNORE INTO owner_scopes(scope_id, scope_kind, blocked) VALUES(?, ?, 0)", values: [scope.id.uuidString, scope.kind.rawValue], db: db)
        }
    }

    public func beginLogout(for scope: OwnerScope) async throws {
        let db = try await database()
        try transaction(db) {
            try execute("INSERT INTO owner_scopes(scope_id, scope_kind, blocked) VALUES(?, ?, 1) ON CONFLICT(scope_id) DO UPDATE SET blocked = 1", values: [scope.id.uuidString, scope.kind.rawValue], db: db)
        }
    }

    public func finishLogout(for scope: OwnerScope) async throws {
        let db = try await database()
        try transaction(db) {
            try execute("DELETE FROM outbox WHERE scope_id = ?", values: [scope.id.uuidString], db: db)
            try execute("DELETE FROM transcripts WHERE scope_id = ?", values: [scope.id.uuidString], db: db)
            try execute("DELETE FROM inbox_cache WHERE scope_id = ?", values: [scope.id.uuidString], db: db)
            try execute("DELETE FROM owner_scopes WHERE scope_id = ?", values: [scope.id.uuidString], db: db)
        }
    }

    public func enqueue(_ entry: OutboxEntry) async throws {
        let db = try await database()
        let payload = try encrypt(entry)
        try transaction(db) {
            guard !(try isBlocked(entry.ownerScope, db: db)) else { throw OnloError.invalidState }
            try execute("INSERT INTO outbox(client_message_id, scope_id, state, attempt_count, next_attempt_at, ordering_key, payload) VALUES(?, ?, ?, ?, ?, ?, ?)", values: [entry.clientMessageId.uuidString, entry.ownerScope.id.uuidString, entry.state.rawValue, entry.attemptCount, entry.nextAttemptAt?.timeIntervalSince1970, entry.orderingKey, payload], db: db)
        }
    }

    public func enqueueAssigningOrder(_ entry: OutboxEntry) async throws -> OutboxEntry {
        let db = try await database()
        var assigned: OutboxEntry?
        try transaction(db) {
            guard !(try isBlocked(entry.ownerScope, db: db)) else { throw OnloError.invalidState }
            let row = try statement("SELECT COALESCE(MAX(ordering_key), 0) FROM outbox WHERE scope_id = ?", db: db)
            defer { sqlite3_finalize(row) }
            try bind([entry.ownerScope.id.uuidString], to: row)
            guard sqlite3_step(row) == SQLITE_ROW else { throw OnloError.persistenceUnavailable }
            let next = sqlite3_column_int64(row, 0) + 1
            let value = OutboxEntry(clientMessageId: entry.clientMessageId, ownerScope: entry.ownerScope, conversationId: entry.conversationId, routingSessionId: entry.routingSessionId, message: entry.message, attachments: entry.attachments, createdAt: entry.createdAt, orderingKey: next, state: entry.state, attemptCount: entry.attemptCount, nextAttemptAt: entry.nextAttemptAt, lastErrorCode: entry.lastErrorCode, serverMessageId: entry.serverMessageId, aiRunId: entry.aiRunId)
            let payload = try encrypt(value)
            try execute("INSERT INTO outbox(client_message_id, scope_id, state, attempt_count, next_attempt_at, ordering_key, payload) VALUES(?, ?, ?, ?, ?, ?, ?)", values: [value.clientMessageId.uuidString, value.ownerScope.id.uuidString, value.state.rawValue, value.attemptCount, value.nextAttemptAt?.timeIntervalSince1970, value.orderingKey, payload], db: db)
            assigned = value
        }
        guard let assigned else { throw OnloError.persistenceUnavailable }
        return assigned
    }

    public func update(_ entry: OutboxEntry) async throws {
        let db = try await database()
        let payload = try encrypt(entry)
        try transaction(db) {
            guard !(try isBlocked(entry.ownerScope, db: db)) else { throw OnloError.invalidState }
            let changed = try execute("UPDATE outbox SET state = ?, attempt_count = ?, next_attempt_at = ?, ordering_key = ?, payload = ? WHERE client_message_id = ? AND scope_id = ?", values: [entry.state.rawValue, entry.attemptCount, entry.nextAttemptAt?.timeIntervalSince1970, entry.orderingKey, payload, entry.clientMessageId.uuidString, entry.ownerScope.id.uuidString], db: db)
            guard changed == 1 else { throw OnloError.invalidState }
        }
    }

    func activateAuthority(_ authority: PersistenceAuthority) {
        activeAuthority = authority
    }

    func revokeAuthority(for scope: OwnerScope) {
        if activeAuthority?.ownerScope == scope { activeAuthority = nil }
    }

    func update(
        _ entry: OutboxEntry,
        expectedState: OutboxState,
        expectedAttemptCount: Int,
        authority: PersistenceAuthority
    ) async throws -> Bool {
        let db = try await database()
        guard activeAuthority == authority else { return false }
        let payload = try encrypt(entry)
        var changed = false
        try transaction(db) {
            guard !(try isBlocked(entry.ownerScope, db: db)) else { throw OnloError.invalidState }
            changed = try execute(
                "UPDATE outbox SET state = ?, attempt_count = ?, next_attempt_at = ?, ordering_key = ?, payload = ? WHERE client_message_id = ? AND scope_id = ? AND state = ? AND attempt_count = ?",
                values: [
                    entry.state.rawValue,
                    entry.attemptCount,
                    entry.nextAttemptAt?.timeIntervalSince1970,
                    entry.orderingKey,
                    payload,
                    entry.clientMessageId.uuidString,
                    entry.ownerScope.id.uuidString,
                    expectedState.rawValue,
                    expectedAttemptCount,
                ],
                db: db
            ) == 1
        }
        return changed
    }

    func recoverEligibleEntries(
        for scope: OwnerScope,
        now: Date,
        authority: PersistenceAuthority
    ) async throws -> [OutboxEntry]? {
        let db = try await database()
        guard activeAuthority == authority, authority.ownerScope == scope else { return nil }
        try transaction(db) {
            guard !(try isBlocked(scope, db: db)) else { throw OnloError.invalidState }
            try execute(
                "UPDATE outbox SET state = ?, next_attempt_at = ? WHERE scope_id = ? AND state = ?",
                values: [
                    OutboxState.failedRetryable.rawValue,
                    now.timeIntervalSince1970,
                    scope.id.uuidString,
                    OutboxState.sending.rawValue,
                ],
                db: db
            )
        }
        guard activeAuthority == authority else { return nil }
        return try await outboxEntries(for: scope).filter {
            ($0.state == .queued || $0.state == .failedRetryable) &&
                ($0.nextAttemptAt.map { $0 <= now } ?? true)
        }
    }

    public func outboxEntries(for scope: OwnerScope) async throws -> [OutboxEntry] {
        let db = try await database()
        guard !(try isBlocked(scope, db: db)) else { throw OnloError.invalidState }
        let statement = try statement("SELECT client_message_id, state, attempt_count, next_attempt_at, ordering_key, payload FROM outbox WHERE scope_id = ? ORDER BY ordering_key, client_message_id", db: db)
        try bind([scope.id.uuidString], to: statement)
        var entries: [OutboxEntry] = []
        var stepResult = sqlite3_step(statement)
        do {
            while stepResult == SQLITE_ROW {
                guard let idText = sqliteText(statement, 0), let id = UUID(uuidString: idText),
                      let stateText = sqliteText(statement, 1), let state = OutboxState(rawValue: stateText),
                      let payloadData = sqliteData(statement, 5) else { throw OnloError.invalidState }
                let payload = try decrypt(payloadData)
                entries.append(OutboxEntry(clientMessageId: id, ownerScope: scope, conversationId: payload.conversationId, routingSessionId: payload.routingSessionId, message: payload.message, attachments: payload.attachments, createdAt: payload.createdAt, orderingKey: sqlite3_column_int64(statement, 4), state: state, attemptCount: Int(sqlite3_column_int(statement, 2)), nextAttemptAt: sqlite3_column_type(statement, 3) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: sqlite3_column_double(statement, 3)), lastErrorCode: payload.lastErrorCode, serverMessageId: payload.serverMessageId, aiRunId: payload.aiRunId))
                stepResult = sqlite3_step(statement)
            }
        } catch {
            sqlite3_finalize(statement)
            if isUnreadableProtectedPayload(error, code: "owner_store_decrypt_failed") {
                try? purge(scope, db: db)
            }
            throw error
        }
        sqlite3_finalize(statement)
        guard stepResult == SQLITE_DONE else { throw sqliteError("owner_store_query_failed", db: db) }
        return entries
    }

    public func recoverEligibleEntries(for scope: OwnerScope, now: Date) async throws -> [OutboxEntry] {
        let db = try await database()
        try transaction(db) {
            guard !(try isBlocked(scope, db: db)) else { throw OnloError.invalidState }
            // One transaction prevents a crash or concurrent reader observing a
            // subset of interrupted sends recovered after process restart.
            try execute("UPDATE outbox SET state = ?, next_attempt_at = ? WHERE scope_id = ? AND state = ?", values: [OutboxState.failedRetryable.rawValue, now.timeIntervalSince1970, scope.id.uuidString, OutboxState.sending.rawValue], db: db)
        }
        return try await outboxEntries(for: scope).filter {
            ($0.state == .queued || $0.state == .failedRetryable) && ($0.nextAttemptAt.map { $0 <= now } ?? true)
        }
    }

    func replaceTranscript(_ transcript: ConversationTranscriptResult, for scope: OwnerScope) async throws {
        let db = try await database()
        guard !(try isBlocked(scope, db: db)) else { throw OnloError.invalidState }
        let previous: ConversationTranscriptResult?
        do {
            previous = try storedTranscript(conversationID: transcript.conversation.id, scope: scope, db: db)
        } catch {
            if isUnreadableProtectedPayload(error, code: "transcript_decrypt_failed") {
                try? purge(scope, db: db)
            }
            throw error
        }
        var merged = Dictionary(uniqueKeysWithValues: (previous?.messages ?? []).map { ($0.id, $0) })
        for message in transcript.messages { merged[message.id] = message }
        let uniqueMessages = merged.values.sorted { $0.timestamp < $1.timestamp }
        let authoritative = ConversationTranscriptResult(conversation: transcript.conversation, messages: uniqueMessages, sync: transcript.sync)
        guard let key = encryptionKey else { throw OnloError.invalidState }
        let payload = try AES.GCM.seal(encoder.encode(authoritative), using: key).combined
        guard let payload else { throw OnloError.credentialStore(code: "transcript_encrypt_failed") }
        try transaction(db) {
            try execute("INSERT INTO transcripts(scope_id, conversation_id, payload) VALUES(?, ?, ?) ON CONFLICT(scope_id, conversation_id) DO UPDATE SET payload = excluded.payload", values: [scope.id.uuidString, transcript.conversation.id, payload], db: db)
        }
    }

    func replaceTranscript(
        _ transcript: ConversationTranscriptResult,
        authority: PersistenceAuthority
    ) async throws -> Bool {
        let db = try await database()
        guard activeAuthority == authority else { return false }
        do {
            try transaction(db) {
                try replaceTranscriptSynchronously(transcript, for: authority.ownerScope, db: db)
            }
        } catch {
            if isUnreadableProtectedPayload(error, code: "transcript_decrypt_failed") {
                try? purge(authority.ownerScope, db: db)
            }
            throw error
        }
        return true
    }

    func replaceConversationList(
        _ conversationList: ConversationListResult,
        authority: PersistenceAuthority
    ) async throws -> Bool {
        let db = try await database()
        guard activeAuthority == authority else { return false }
        guard !(try isBlocked(authority.ownerScope, db: db)) else {
            throw OnloError.invalidState
        }
        guard let key = encryptionKey,
              let payload = try AES.GCM.seal(encoder.encode(conversationList), using: key).combined else {
            throw OnloError.credentialStore(code: "inbox_encrypt_failed")
        }
        try transaction(db) {
            try execute(
                "INSERT INTO inbox_cache(scope_id, payload) VALUES(?, ?) ON CONFLICT(scope_id) DO UPDATE SET payload = excluded.payload",
                values: [authority.ownerScope.id.uuidString, payload],
                db: db
            )
        }
        return activeAuthority == authority
    }

    func conversationList(
        authority: PersistenceAuthority
    ) async throws -> ConversationListResult? {
        let db = try await database()
        guard activeAuthority == authority,
              !(try isBlocked(authority.ownerScope, db: db)) else { return nil }
        let statement = try statement(
            "SELECT payload FROM inbox_cache WHERE scope_id = ?",
            db: db
        )
        defer { sqlite3_finalize(statement) }
        try bind([authority.ownerScope.id.uuidString], to: statement)
        let result = sqlite3_step(statement)
        if result == SQLITE_DONE { return nil }
        guard result == SQLITE_ROW,
              let payload = sqliteData(statement, 0),
              let key = encryptionKey,
              let box = try? AES.GCM.SealedBox(combined: payload) else {
            try? purge(authority.ownerScope, db: db)
            throw OnloError.credentialStore(code: "inbox_decrypt_failed")
        }
        do {
            let decoded = try decoder.decode(ConversationListResult.self, from: AES.GCM.open(box, using: key))
            return activeAuthority == authority ? decoded : nil
        } catch {
            try? purge(authority.ownerScope, db: db)
            throw OnloError.credentialStore(code: "inbox_decrypt_failed")
        }
    }

    func reconcileAccepted(
        _ entry: OutboxEntry,
        transcript: ConversationTranscriptResult,
        expectedServerMessageId: String,
        authority: PersistenceAuthority
    ) async throws -> Bool {
        let db = try await database()
        guard activeAuthority == authority else { return false }
        var changed = false
        do {
            try transaction(db) {
                guard !(try isBlocked(entry.ownerScope, db: db)) else { throw OnloError.invalidState }
                let row = try statement(
                "SELECT state, attempt_count, payload FROM outbox WHERE client_message_id = ? AND scope_id = ?",
                db: db
                )
                defer { sqlite3_finalize(row) }
                try bind([entry.clientMessageId.uuidString, entry.ownerScope.id.uuidString], to: row)
                guard sqlite3_step(row) == SQLITE_ROW,
                      sqliteText(row, 0) == OutboxState.accepted.rawValue,
                      let payloadData = sqliteData(row, 2) else { return }
                let payload = try decrypt(payloadData)
                guard payload.serverMessageId == expectedServerMessageId else { return }
                try replaceTranscriptSynchronously(transcript, for: authority.ownerScope, db: db)
                var reconciled = entry
                reconciled.state = .reconciled
                let encrypted = try encrypt(reconciled)
                changed = try execute(
                "UPDATE outbox SET state = ?, attempt_count = ?, next_attempt_at = ?, ordering_key = ?, payload = ? WHERE client_message_id = ? AND scope_id = ? AND state = ?",
                values: [
                    reconciled.state.rawValue,
                    reconciled.attemptCount,
                    reconciled.nextAttemptAt?.timeIntervalSince1970,
                    reconciled.orderingKey,
                    encrypted,
                    reconciled.clientMessageId.uuidString,
                    reconciled.ownerScope.id.uuidString,
                    OutboxState.accepted.rawValue,
                ],
                    db: db
                ) == 1
            }
        } catch {
            if isUnreadableProtectedPayload(error, code: "owner_store_decrypt_failed") ||
                isUnreadableProtectedPayload(error, code: "transcript_decrypt_failed") {
                try? purge(authority.ownerScope, db: db)
            }
            throw error
        }
        return changed
    }

    private func replaceTranscriptSynchronously(
        _ transcript: ConversationTranscriptResult,
        for scope: OwnerScope,
        db: SQLiteConnection
    ) throws {
        guard !(try isBlocked(scope, db: db)) else { throw OnloError.invalidState }
        let previous = try storedTranscript(conversationID: transcript.conversation.id, scope: scope, db: db)
        var merged = Dictionary(uniqueKeysWithValues: (previous?.messages ?? []).map { ($0.id, $0) })
        for message in transcript.messages { merged[message.id] = message }
        let uniqueMessages = merged.values.sorted { $0.timestamp < $1.timestamp }
        let authoritative = ConversationTranscriptResult(
            conversation: transcript.conversation,
            messages: uniqueMessages,
            sync: transcript.sync
        )
        guard let key = encryptionKey else { throw OnloError.invalidState }
        guard let payload = try AES.GCM.seal(encoder.encode(authoritative), using: key).combined else {
            throw OnloError.credentialStore(code: "transcript_encrypt_failed")
        }
        try execute(
            "INSERT INTO transcripts(scope_id, conversation_id, payload) VALUES(?, ?, ?) ON CONFLICT(scope_id, conversation_id) DO UPDATE SET payload = excluded.payload",
            values: [scope.id.uuidString, transcript.conversation.id, payload],
            db: db
        )
    }

    func transcript(conversationId: String, for scope: OwnerScope) async throws -> ConversationTranscriptResult? {
        let db = try await database()
        guard !(try isBlocked(scope, db: db)) else { throw OnloError.invalidState }
        return try storedTranscript(conversationID: conversationId, scope: scope, db: db)
    }

    private func database() async throws -> SQLiteConnection {
        if let connection { return connection }
        let directoryURL = databaseURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        var directoryValues = URLResourceValues()
        directoryValues.isExcludedFromBackup = true
        var protectedDirectoryURL = directoryURL
        try protectedDirectoryURL.setResourceValues(directoryValues)
        #if os(iOS)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: directoryURL.path)
        #endif
        var handle: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &handle, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK, let handle else { throw OnloError.credentialStore(code: "owner_store_open_failed") }
        let db = SQLiteConnection(handle: handle)
        do {
            try execute("PRAGMA foreign_keys = ON", values: [], db: db)
            try execute("CREATE TABLE IF NOT EXISTS owner_scopes (scope_id TEXT PRIMARY KEY NOT NULL, scope_kind TEXT NOT NULL, blocked INTEGER NOT NULL CHECK(blocked IN (0, 1)))", values: [], db: db)
            try execute("CREATE TABLE IF NOT EXISTS outbox (client_message_id TEXT PRIMARY KEY NOT NULL, scope_id TEXT NOT NULL REFERENCES owner_scopes(scope_id), state TEXT NOT NULL, attempt_count INTEGER NOT NULL, next_attempt_at REAL, ordering_key INTEGER NOT NULL, payload BLOB NOT NULL)", values: [], db: db)
            try execute("CREATE INDEX IF NOT EXISTS outbox_scope_order ON outbox(scope_id, ordering_key, client_message_id)", values: [], db: db)
            try execute("CREATE TABLE IF NOT EXISTS outbox_metadata (key TEXT PRIMARY KEY NOT NULL, value BLOB NOT NULL)", values: [], db: db)
            try execute("CREATE TABLE IF NOT EXISTS transcripts (scope_id TEXT NOT NULL REFERENCES owner_scopes(scope_id), conversation_id TEXT NOT NULL, payload BLOB NOT NULL, PRIMARY KEY(scope_id, conversation_id))", values: [], db: db)
            try execute("CREATE TABLE IF NOT EXISTS inbox_cache (scope_id TEXT PRIMARY KEY NOT NULL REFERENCES owner_scopes(scope_id), payload BLOB NOT NULL)", values: [], db: db)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var protectedURL = databaseURL
            try protectedURL.setResourceValues(values)
            #if os(iOS)
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: databaseURL.path)
            #endif
            let loadedKey = try await keyStore.loadOrCreate()
            guard loadedKey.withUnsafeBytes({ $0.count }) == 32 else {
                try purgeAll(db: db)
                throw OnloError.credentialStore(code: "outbox_key_invalid")
            }
            let keyFingerprint = Data(SHA256.hash(data: loadedKey.withUnsafeBytes { Data($0) }))
            if let storedFingerprint = try metadataValue(for: "key_fingerprint", db: db), storedFingerprint != keyFingerprint {
                try purgeAll(db: db)
            }
            try execute("INSERT INTO outbox_metadata(key, value) VALUES('key_fingerprint', ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value", values: [keyFingerprint], db: db)
            encryptionKey = loadedKey
            connection = db
            return db
        } catch {
            throw error
        }
    }

    private func encrypt(_ entry: OutboxEntry) throws -> Data {
        guard let encryptionKey else { throw OnloError.invalidState }
        let payload = EncryptedPayload(conversationId: entry.conversationId, routingSessionId: entry.routingSessionId, message: entry.message, attachments: entry.attachments, createdAt: entry.createdAt, lastErrorCode: entry.lastErrorCode, serverMessageId: entry.serverMessageId, aiRunId: entry.aiRunId)
        let data = try encoder.encode(payload)
        guard let combined = try AES.GCM.seal(data, using: encryptionKey).combined else {
            throw OnloError.credentialStore(code: "owner_store_encrypt_failed")
        }
        return combined
    }

    private func decrypt(_ data: Data) throws -> EncryptedPayload {
        guard let encryptionKey, let box = try? AES.GCM.SealedBox(combined: data) else { throw OnloError.credentialStore(code: "owner_store_decrypt_failed") }
        do { return try decoder.decode(EncryptedPayload.self, from: AES.GCM.open(box, using: encryptionKey)) }
        catch { throw OnloError.credentialStore(code: "owner_store_decrypt_failed") }
    }

    private func isUnreadableProtectedPayload(_ error: Error, code: String) -> Bool {
        guard case let OnloError.credentialStore(actualCode) = error else { return false }
        return actualCode == code
    }

    private func purge(_ scope: OwnerScope, db: SQLiteConnection) throws {
        try transaction(db) {
            try execute("DELETE FROM outbox WHERE scope_id = ?", values: [scope.id.uuidString], db: db)
            try execute("DELETE FROM transcripts WHERE scope_id = ?", values: [scope.id.uuidString], db: db)
            try execute("DELETE FROM inbox_cache WHERE scope_id = ?", values: [scope.id.uuidString], db: db)
            try execute("DELETE FROM owner_scopes WHERE scope_id = ?", values: [scope.id.uuidString], db: db)
        }
    }

    private func purgeAll(db: SQLiteConnection) throws {
        try transaction(db) {
            try execute("DELETE FROM outbox", values: [], db: db)
            try execute("DELETE FROM transcripts", values: [], db: db)
            try execute("DELETE FROM inbox_cache", values: [], db: db)
            try execute("DELETE FROM owner_scopes", values: [], db: db)
        }
    }

    private func metadataValue(for key: String, db: SQLiteConnection) throws -> Data? {
        let statement = try statement("SELECT value FROM outbox_metadata WHERE key = ?", db: db)
        defer { sqlite3_finalize(statement) }
        try bind([key], to: statement)
        let result = sqlite3_step(statement)
        if result == SQLITE_DONE { return nil }
        guard result == SQLITE_ROW, let value = sqliteData(statement, 0) else {
            throw sqliteError("owner_store_query_failed", db: db)
        }
        return value
    }

    private func storedTranscript(conversationID: String, scope: OwnerScope, db: SQLiteConnection) throws -> ConversationTranscriptResult? {
        let statement = try statement("SELECT payload FROM transcripts WHERE scope_id = ? AND conversation_id = ?", db: db)
        defer { sqlite3_finalize(statement) }
        try bind([scope.id.uuidString, conversationID], to: statement)
        let result = sqlite3_step(statement)
        if result == SQLITE_DONE { return nil }
        guard result == SQLITE_ROW, let payload = sqliteData(statement, 0), let key = encryptionKey,
              let box = try? AES.GCM.SealedBox(combined: payload) else { throw OnloError.credentialStore(code: "transcript_decrypt_failed") }
        do { return try decoder.decode(ConversationTranscriptResult.self, from: AES.GCM.open(box, using: key)) }
        catch { throw OnloError.credentialStore(code: "transcript_decrypt_failed") }
    }

    private func isBlocked(_ scope: OwnerScope, db: SQLiteConnection) throws -> Bool {
        let statement = try statement("SELECT blocked FROM owner_scopes WHERE scope_id = ?", db: db)
        defer { sqlite3_finalize(statement) }
        try bind([scope.id.uuidString], to: statement)
        let result = sqlite3_step(statement)
        if result == SQLITE_DONE { return false }
        guard result == SQLITE_ROW else { throw sqliteError("owner_store_query_failed", db: db) }
        return sqlite3_column_int(statement, 0) != 0
    }

    private func transaction(_ db: SQLiteConnection, _ body: () throws -> Void) throws {
        try execute("BEGIN IMMEDIATE", values: [], db: db)
        do { try body(); try execute("COMMIT", values: [], db: db) }
        catch { _ = try? execute("ROLLBACK", values: [], db: db); throw error }
    }

    @discardableResult private func execute(_ sql: String, values: [Any?], db: SQLiteConnection) throws -> Int32 {
        let statement = try statement(sql, db: db)
        defer { sqlite3_finalize(statement) }
        try bind(values, to: statement)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw sqliteError("owner_store_write_failed", db: db) }
        return sqlite3_changes(db.handle)
    }

    private func statement(_ sql: String, db: SQLiteConnection) throws -> OpaquePointer {
        var result: OpaquePointer?
        guard sqlite3_prepare_v2(db.handle, sql, -1, &result, nil) == SQLITE_OK, let result else { throw sqliteError("owner_store_prepare_failed", db: db) }
        return result
    }

    private func bind(_ values: [Any?], to statement: OpaquePointer) throws {
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            let result: Int32
            switch value {
            case nil: result = sqlite3_bind_null(statement, index)
            case let value as String: result = sqlite3_bind_text(statement, index, value, -1, sqliteTransient)
            case let value as Int: result = sqlite3_bind_int64(statement, index, Int64(value))
            case let value as Int64: result = sqlite3_bind_int64(statement, index, value)
            case let value as Double: result = sqlite3_bind_double(statement, index, value)
            case let value as Data: result = value.withUnsafeBytes { sqlite3_bind_blob(statement, index, $0.baseAddress, Int32(value.count), sqliteTransient) }
            default: throw OnloError.invalidState
            }
            guard result == SQLITE_OK else { throw OnloError.credentialStore(code: "owner_store_bind_failed") }
        }
    }

    private func sqliteText(_ statement: OpaquePointer, _ column: Int32) -> String? { sqlite3_column_text(statement, column).map { String(cString: $0) } }
    private func sqliteData(_ statement: OpaquePointer, _ column: Int32) -> Data? { guard let bytes = sqlite3_column_blob(statement, column) else { return nil }; return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, column))) }
    private func sqliteError(_ code: String, db: SQLiteConnection) -> OnloError { OnloError.credentialStore(code: code) }
    private static func defaultDatabaseURL() -> URL { FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("OnloSDK", isDirectory: true).appendingPathComponent("outbox.sqlite", isDirectory: false) }
}

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Non-durable test support for exercising owner and outbox invariants. Production
/// integrations must provide a transactional native database implementation.
public actor InMemoryOwnerScopedStore: OwnerScopedPersisting, TranscriptPersisting, AuthorityFencedPersisting {
    private var entries: [OwnerScope: [UUID: OutboxEntry]] = [:]
    private var transcripts: [OwnerScope: [String: ConversationTranscriptResult]] = [:]
    private var conversationLists: [OwnerScope: ConversationListResult] = [:]
    private var activeAuthority: PersistenceAuthority?
    private var blockedScopes = Set<OwnerScope>()

    public init() {}

    public func prepare(scope: OwnerScope) async throws {
        guard !blockedScopes.contains(scope) else { throw OnloError.invalidState }
        if entries[scope] == nil { entries[scope] = [:] }
    }

    public func beginLogout(for scope: OwnerScope) async throws {
        blockedScopes.insert(scope)
    }

    public func finishLogout(for scope: OwnerScope) async throws {
        entries[scope] = nil
        transcripts[scope] = nil
        conversationLists[scope] = nil
    }

    public func enqueue(_ entry: OutboxEntry) async throws {
        guard !blockedScopes.contains(entry.ownerScope) else { throw OnloError.invalidState }
        var scopeEntries = entries[entry.ownerScope, default: [:]]
        guard scopeEntries[entry.clientMessageId] == nil else { throw OnloError.invalidState }
        scopeEntries[entry.clientMessageId] = entry
        entries[entry.ownerScope] = scopeEntries
    }

    public func enqueueAssigningOrder(_ entry: OutboxEntry) async throws -> OutboxEntry {
        guard !blockedScopes.contains(entry.ownerScope) else { throw OnloError.invalidState }
        let next = (entries[entry.ownerScope, default: [:]].values.map(\.orderingKey).max() ?? 0) + 1
        let value = OutboxEntry(clientMessageId: entry.clientMessageId, ownerScope: entry.ownerScope, conversationId: entry.conversationId, routingSessionId: entry.routingSessionId, message: entry.message, attachments: entry.attachments, createdAt: entry.createdAt, orderingKey: next, state: entry.state, attemptCount: entry.attemptCount, nextAttemptAt: entry.nextAttemptAt, lastErrorCode: entry.lastErrorCode, serverMessageId: entry.serverMessageId, aiRunId: entry.aiRunId)
        entries[entry.ownerScope, default: [:]][value.clientMessageId] = value
        return value
    }

    public func update(_ entry: OutboxEntry) async throws {
        guard !blockedScopes.contains(entry.ownerScope), entries[entry.ownerScope]?[entry.clientMessageId] != nil else {
            throw OnloError.invalidState
        }
        entries[entry.ownerScope]?[entry.clientMessageId] = entry
    }

    func activateAuthority(_ authority: PersistenceAuthority) {
        activeAuthority = authority
    }

    func revokeAuthority(for scope: OwnerScope) {
        if activeAuthority?.ownerScope == scope { activeAuthority = nil }
    }

    func update(
        _ entry: OutboxEntry,
        expectedState: OutboxState,
        expectedAttemptCount: Int,
        authority: PersistenceAuthority
    ) async throws -> Bool {
        guard activeAuthority == authority,
              let current = entries[entry.ownerScope]?[entry.clientMessageId],
              current.state == expectedState,
              current.attemptCount == expectedAttemptCount else { return false }
        entries[entry.ownerScope]?[entry.clientMessageId] = entry
        return true
    }

    func recoverEligibleEntries(
        for scope: OwnerScope,
        now: Date,
        authority: PersistenceAuthority
    ) async throws -> [OutboxEntry]? {
        guard activeAuthority == authority, authority.ownerScope == scope,
              !blockedScopes.contains(scope) else { return nil }
        var scoped = entries[scope, default: [:]]
        for id in scoped.keys where scoped[id]?.state == .sending {
            scoped[id]?.state = .failedRetryable
            scoped[id]?.nextAttemptAt = now
        }
        entries[scope] = scoped
        return scoped.values.sorted { $0.orderingKey < $1.orderingKey }.filter {
            ($0.state == .queued || $0.state == .failedRetryable) &&
                ($0.nextAttemptAt.map { $0 <= now } ?? true)
        }
    }

    public func outboxEntries(for scope: OwnerScope) async throws -> [OutboxEntry] {
        guard !blockedScopes.contains(scope) else { throw OnloError.invalidState }
        return entries[scope, default: [:]].values.sorted { $0.orderingKey < $1.orderingKey }
    }

    public func recoverEligibleEntries(for scope: OwnerScope, now: Date) async throws -> [OutboxEntry] {
        guard !blockedScopes.contains(scope) else { throw OnloError.invalidState }
        var scoped = entries[scope, default: [:]]
        for id in scoped.keys where scoped[id]?.state == .sending {
            scoped[id]?.state = .failedRetryable
            scoped[id]?.nextAttemptAt = now
        }
        entries[scope] = scoped
        return scoped.values.sorted { $0.orderingKey < $1.orderingKey }.filter {
            ($0.state == .queued || $0.state == .failedRetryable) && ($0.nextAttemptAt.map { $0 <= now } ?? true)
        }
    }

    func replaceTranscript(_ transcript: ConversationTranscriptResult, for scope: OwnerScope) async throws {
        try replaceTranscriptSynchronously(transcript, for: scope)
    }

    private func replaceTranscriptSynchronously(
        _ transcript: ConversationTranscriptResult,
        for scope: OwnerScope
    ) throws {
        guard !blockedScopes.contains(scope) else { throw OnloError.invalidState }
        let unique = Dictionary(transcript.messages.map { ($0.id, $0) }, uniquingKeysWith: { _, newest in newest }).values.sorted { $0.timestamp < $1.timestamp }
        transcripts[scope, default: [:]][transcript.conversation.id] = ConversationTranscriptResult(conversation: transcript.conversation, messages: unique, sync: transcript.sync)
    }

    func transcript(conversationId: String, for scope: OwnerScope) async throws -> ConversationTranscriptResult? {
        guard !blockedScopes.contains(scope) else { throw OnloError.invalidState }
        return transcripts[scope]?[conversationId]
    }

    func replaceTranscript(
        _ transcript: ConversationTranscriptResult,
        authority: PersistenceAuthority
    ) async throws -> Bool {
        guard activeAuthority == authority else { return false }
        try replaceTranscriptSynchronously(transcript, for: authority.ownerScope)
        return true
    }

    func replaceConversationList(
        _ conversationList: ConversationListResult,
        authority: PersistenceAuthority
    ) async throws -> Bool {
        guard activeAuthority == authority,
              !blockedScopes.contains(authority.ownerScope) else { return false }
        conversationLists[authority.ownerScope] = conversationList
        return true
    }

    func conversationList(
        authority: PersistenceAuthority
    ) async throws -> ConversationListResult? {
        guard activeAuthority == authority,
              !blockedScopes.contains(authority.ownerScope) else { return nil }
        return conversationLists[authority.ownerScope]
    }

    func reconcileAccepted(
        _ entry: OutboxEntry,
        transcript: ConversationTranscriptResult,
        expectedServerMessageId: String,
        authority: PersistenceAuthority
    ) async throws -> Bool {
        guard activeAuthority == authority,
              let current = entries[entry.ownerScope]?[entry.clientMessageId],
              current.state == .accepted,
              current.serverMessageId == expectedServerMessageId else { return false }
        try replaceTranscriptSynchronously(transcript, for: authority.ownerScope)
        var reconciled = current
        reconciled.state = .reconciled
        entries[entry.ownerScope]?[entry.clientMessageId] = reconciled
        return true
    }
}

/// Injectable protected storage for tests. It is memory-only and never a
/// persistence fallback for the production Keychain store.
actor InMemoryCredentialStore: CredentialStoring {
    private var state: ProtectedSessionState

    init(_ value: StoredSessionCredential? = nil, pendingTransition: PendingSessionTransition? = nil) {
        self.state = ProtectedSessionState(credential: value, pendingTransition: pendingTransition, retryGate: nil)
    }

    func loadState() async throws -> ProtectedSessionState { state }
    func saveState(_ state: ProtectedSessionState) async throws { self.state = state }
}
