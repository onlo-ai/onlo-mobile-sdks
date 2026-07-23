import Foundation

/// The version accepted by the mobile SDK server contract.
public enum OnloProtocol {
    public static let version = 1
    public static let maximumImagesPerMessage = 5
    public static let maximumSourceImageBytes = 25 * 1024 * 1024
    public static let maximumImageBytes = 8 * 1024 * 1024
    public static let maximumImageDimension = 4_096
    public static let maximumImagePixels = 16_000_000
}

public enum RuntimePlatform: String, Codable, Sendable {
    case ios
    case android
}

public enum SDKFamily: String, Codable, Sendable {
    case ios
    case android
    case reactNative = "react-native"
    case flutter
}

public enum IdentityClass: String, Codable, Sendable {
    case anonymous
    case identified
}

public enum PublicationState: String, Codable, Sendable {
    case testing
    case production
}

public enum RetryDirective: String, Codable, Sendable, Equatable {
    case never
    case afterTokenRefresh = "after_token_refresh"
    case afterAttestation = "after_attestation"
    case afterBackoff = "after_backoff"
    case afterFullSync = "after_full_sync"
}

public enum APIErrorCode: String, Codable, Sendable, Equatable {
    case invalidRequest = "invalid_request"
    case invalidTargetKey = "invalid_target_key"
    case sdkNotAvailable = "sdk_not_available"
    case targetDisabled = "target_disabled"
    case incompatibleClient = "incompatible_client"
    case proofRequired = "proof_required"
    case invalidProof = "invalid_proof"
    case expiredProof = "expired_proof"
    case identityDisabled = "identity_disabled"
    case attestationRequired = "attestation_required"
    case invalidAttestation = "invalid_attestation"
    case sessionExpired = "session_expired"
    case sessionRevoked = "session_revoked"
    case forbiddenPrincipal = "forbidden_principal"
    case staleCursor = "stale_cursor"
    case idempotencyConflict = "idempotency_conflict"
    case configUnavailable = "config_unavailable"
    case mediaUnavailable = "media_unavailable"
    case rateLimited = "rate_limited"
    case dependencyUnavailable = "dependency_unavailable"
}

public struct APIRetry: Codable, Sendable, Equatable {
    public let directive: RetryDirective
    public let retryAfterMs: Int?

    public init(directive: RetryDirective, retryAfterMs: Int? = nil) throws {
        guard retryAfterMs.map({ $0 >= 0 }) ?? true else {
            throw OnloError.invalidResponse
        }
        self.directive = directive
        self.retryAfterMs = retryAfterMs
    }

    private enum CodingKeys: String, CodingKey { case directive, retryAfterMs }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let directive = try container.decode(RetryDirective.self, forKey: .directive)
        let retryAfterMs = try container.decodeIfPresent(Int.self, forKey: .retryAfterMs)
        try self.init(directive: directive, retryAfterMs: retryAfterMs)
    }
}

public struct APIError: Codable, Sendable, Equatable {
    public let code: APIErrorCode
    public let message: String
    public let retry: APIRetry
    /// Correlation metadata copied from the containing v1 envelope. It is
    /// intentionally excluded from the nested wire error object.
    public let requestId: String?

    public init(code: APIErrorCode, message: String, retry: APIRetry, requestId: String? = nil) {
        self.code = code
        self.message = message
        self.retry = retry
        self.requestId = requestId
    }

    private enum CodingKeys: String, CodingKey {
        case code
        case message
        case retry
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        code = try container.decode(APIErrorCode.self, forKey: .code)
        message = try container.decode(String.self, forKey: .message)
        retry = try container.decode(APIRetry.self, forKey: .retry)
        requestId = nil
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(code, forKey: .code)
        try container.encode(message, forKey: .message)
        try container.encode(retry, forKey: .retry)
    }
}

public struct APIResponse<Result: Codable & Sendable>: Codable, Sendable {
    public let requestId: String
    public let serverTime: String
    public let protocolVersion: Int
    public let minimumProtocolVersion: Int
    public let ok: Bool
    public let result: Result
}

public struct APIFailure: Codable, Sendable, Equatable {
    public let requestId: String
    public let serverTime: String
    public let protocolVersion: Int
    public let minimumProtocolVersion: Int
    public let ok: Bool
    public let error: APIError
}

public enum APIEnvelope<Result: Codable & Sendable>: Codable, Sendable {
    case success(APIResponse<Result>)
    case failure(APIFailure)

    private enum CodingKeys: String, CodingKey { case ok }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if try container.decode(Bool.self, forKey: .ok) {
            self = .success(try APIResponse(from: decoder))
        } else {
            self = .failure(try APIFailure(from: decoder))
        }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .success(let response): try response.encode(to: encoder)
        case .failure(let response): try response.encode(to: encoder)
        }
    }
}

public struct SDKClientDescriptor: Codable, Sendable, Equatable {
    public let protocolVersion: Int
    public let installationId: String
    public let runtimePlatform: RuntimePlatform
    public let sdkFamily: SDKFamily
    public let sdkVersion: String
    public let appVersion: String?
    public let appBuild: String?
    public let capabilities: [String]

    public init(
        installationId: String,
        runtimePlatform: RuntimePlatform = .ios,
        sdkFamily: SDKFamily = .ios,
        sdkVersion: String,
        appVersion: String? = nil,
        appBuild: String? = nil,
        capabilities: [String]
    ) {
        self.protocolVersion = OnloProtocol.version
        self.installationId = installationId
        self.runtimePlatform = runtimePlatform
        self.sdkFamily = sdkFamily
        self.sdkVersion = sdkVersion
        self.appVersion = appVersion
        self.appBuild = appBuild
        self.capabilities = capabilities
    }
}

public enum SessionOperation: Sendable, Equatable {
    case bootstrap(transitionId: String, proposedCredential: String, userJwt: String?)
    case resume(transitionId: String, expectedGeneration: Int, presentedCredential: String, proposedCredential: String)
    case identify(transitionId: String, expectedGeneration: Int, presentedCredential: String, proposedCredential: String, userJwt: String)
    case logout(transitionId: String, expectedGeneration: Int, presentedCredential: String, proposedCredential: String)
}

extension SessionOperation: Codable {
    private enum CodingKeys: String, CodingKey {
        case type, transitionId, expectedGeneration, presentedCredential, proposedCredential, userJwt
    }

    private enum OperationType: String, Codable { case bootstrap, resume, identify, logout }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(OperationType.self, forKey: .type)
        let transitionId = try container.decode(String.self, forKey: .transitionId)
        let proposedCredential = try container.decode(String.self, forKey: .proposedCredential)

        switch type {
        case .bootstrap:
            self = .bootstrap(
                transitionId: transitionId,
                proposedCredential: proposedCredential,
                userJwt: try container.decodeIfPresent(String.self, forKey: .userJwt)
            )
        case .resume:
            self = .resume(
                transitionId: transitionId,
                expectedGeneration: try container.decode(Int.self, forKey: .expectedGeneration),
                presentedCredential: try container.decode(String.self, forKey: .presentedCredential),
                proposedCredential: proposedCredential
            )
        case .identify:
            self = .identify(
                transitionId: transitionId,
                expectedGeneration: try container.decode(Int.self, forKey: .expectedGeneration),
                presentedCredential: try container.decode(String.self, forKey: .presentedCredential),
                proposedCredential: proposedCredential,
                userJwt: try container.decode(String.self, forKey: .userJwt)
            )
        case .logout:
            self = .logout(
                transitionId: transitionId,
                expectedGeneration: try container.decode(Int.self, forKey: .expectedGeneration),
                presentedCredential: try container.decode(String.self, forKey: .presentedCredential),
                proposedCredential: proposedCredential
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .bootstrap(let transitionId, let proposedCredential, let userJwt):
            try container.encode(OperationType.bootstrap, forKey: .type)
            try container.encode(transitionId, forKey: .transitionId)
            try container.encode(proposedCredential, forKey: .proposedCredential)
            try container.encodeIfPresent(userJwt, forKey: .userJwt)
        case .resume(let transitionId, let expectedGeneration, let presentedCredential, let proposedCredential):
            try container.encode(OperationType.resume, forKey: .type)
            try container.encode(transitionId, forKey: .transitionId)
            try container.encode(expectedGeneration, forKey: .expectedGeneration)
            try container.encode(presentedCredential, forKey: .presentedCredential)
            try container.encode(proposedCredential, forKey: .proposedCredential)
        case .identify(let transitionId, let expectedGeneration, let presentedCredential, let proposedCredential, let userJwt):
            try container.encode(OperationType.identify, forKey: .type)
            try container.encode(transitionId, forKey: .transitionId)
            try container.encode(expectedGeneration, forKey: .expectedGeneration)
            try container.encode(presentedCredential, forKey: .presentedCredential)
            try container.encode(proposedCredential, forKey: .proposedCredential)
            try container.encode(userJwt, forKey: .userJwt)
        case .logout(let transitionId, let expectedGeneration, let presentedCredential, let proposedCredential):
            try container.encode(OperationType.logout, forKey: .type)
            try container.encode(transitionId, forKey: .transitionId)
            try container.encode(expectedGeneration, forKey: .expectedGeneration)
            try container.encode(presentedCredential, forKey: .presentedCredential)
            try container.encode(proposedCredential, forKey: .proposedCredential)
        }
    }
}

public struct SessionRequest: Codable, Sendable, Equatable {
    public let sdkKey: String
    public let appIdentifier: String
    public let client: SDKClientDescriptor
    public let operation: SessionOperation

    public init(sdkKey: String, appIdentifier: String, client: SDKClientDescriptor, operation: SessionOperation) {
        self.sdkKey = sdkKey
        self.appIdentifier = appIdentifier
        self.client = client
        self.operation = operation
    }
}

public struct SessionResult: Codable, Sendable, Equatable {
    public let sessionId: String
    public let chatToken: String
    public let installationId: String
    public let generation: Int
    public let proposedCredential: String
    public let identityClass: IdentityClass
    public let publicationState: PublicationState
    public let attestationState: String
    public let configRevision: String
    public let configSchemaVersion: Int
    public let configEtag: String
}

/// Represents server-defined transcript attachments, whose inner shape remains
/// intentionally opaque in the v1 handoff.
public indirect enum JSONValue: Codable, Sendable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([String: JSONValue].self) { self = .object(value) }
        else { self = .array(try container.decode([JSONValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }
}

public enum ImageMimeType: String, Codable, Sendable {
    case jpeg = "image/jpeg"
    case png = "image/png"
    case webp = "image/webp"
}

public struct AttachmentIntentRequest: Codable, Sendable, Equatable {
    public let conversationId: String
    public let mimeType: ImageMimeType
    public let byteSize: Int
    public let sha256: String
    public let filename: String

    public init(conversationId: String, mimeType: ImageMimeType, byteSize: Int, sha256: String, filename: String) {
        self.conversationId = conversationId
        self.mimeType = mimeType
        self.byteSize = byteSize
        self.sha256 = sha256
        self.filename = filename
    }
}

public struct AttachmentIntentResult: Codable, Sendable, Equatable {
    public struct Completion: Codable, Sendable, Equatable {
        public let method: String
        public let endpoint: String
    }

    public let attachmentId: String
    public let intent: String
    public let expiresAt: String
    public let completion: Completion
}

public struct CompletedAttachment: Codable, Sendable, Equatable {
    public let id: String
    public let url: String
    public let type: ImageMimeType
    public let name: String
    public let size: Int
    public let sha256: String
}

public struct AttachmentCompleteResult: Codable, Sendable, Equatable {
    public let attachment: CompletedAttachment
    public let receipt: String
    public let receiptExpiresAt: String
    public let authenticatedDownload: String
}

public struct ChatAttachment: Codable, Sendable, Equatable {
    public let id: String?
    public let url: String
    public let type: String
    public let name: String
    public let size: Int
    public let sha256: String?
    public let receipt: String?

    public init(id: String? = nil, url: String, type: String, name: String, size: Int, sha256: String? = nil, receipt: String? = nil) {
        self.id = id
        self.url = url
        self.type = type
        self.name = name
        self.size = size
        self.sha256 = sha256
        self.receipt = receipt
    }
}

public struct ChatRequest: Codable, Sendable, Equatable {
    public let sessionId: String
    public let clientMessageId: String
    public let message: String
    public let attachments: [ChatAttachment]?

    public init(sessionId: String, clientMessageId: String, message: String, attachments: [ChatAttachment]? = nil) {
        self.sessionId = sessionId
        self.clientMessageId = clientMessageId
        self.message = message
        self.attachments = attachments
    }
}

public enum ChatEvent: Codable, Sendable, Equatable {
    case accepted(clientMessageId: String, messageId: String, conversationId: String, acceptedAt: String, duplicate: Bool, processingStatus: String)
    case text(content: String)
    case done(conversationId: String, duplicate: Bool?, processingStatus: String?, gated: Bool?, reason: String?)
    case error(error: String, retryable: Bool)

    private enum CodingKeys: String, CodingKey {
        case type, clientMessageId, messageId, conversationId, acceptedAt, duplicate, processingStatus, content, gated, reason, error, retryable
    }
    private enum EventType: String, Codable { case accepted, text, done, error }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(EventType.self, forKey: .type) {
        case .accepted:
            self = .accepted(
                clientMessageId: try container.decode(String.self, forKey: .clientMessageId),
                messageId: try container.decode(String.self, forKey: .messageId),
                conversationId: try container.decode(String.self, forKey: .conversationId),
                acceptedAt: try container.decode(String.self, forKey: .acceptedAt),
                duplicate: try container.decode(Bool.self, forKey: .duplicate),
                processingStatus: try container.decode(String.self, forKey: .processingStatus)
            )
        case .text:
            self = .text(content: try container.decode(String.self, forKey: .content))
        case .done:
            self = .done(
                conversationId: try container.decode(String.self, forKey: .conversationId),
                duplicate: try container.decodeIfPresent(Bool.self, forKey: .duplicate),
                processingStatus: try container.decodeIfPresent(String.self, forKey: .processingStatus),
                gated: try container.decodeIfPresent(Bool.self, forKey: .gated),
                reason: try container.decodeIfPresent(String.self, forKey: .reason)
            )
        case .error:
            self = .error(
                error: try container.decode(String.self, forKey: .error),
                retryable: try container.decode(Bool.self, forKey: .retryable)
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .accepted(let clientMessageId, let messageId, let conversationId, let acceptedAt, let duplicate, let processingStatus):
            try container.encode(EventType.accepted, forKey: .type)
            try container.encode(clientMessageId, forKey: .clientMessageId)
            try container.encode(messageId, forKey: .messageId)
            try container.encode(conversationId, forKey: .conversationId)
            try container.encode(acceptedAt, forKey: .acceptedAt)
            try container.encode(duplicate, forKey: .duplicate)
            try container.encode(processingStatus, forKey: .processingStatus)
        case .text(let content):
            try container.encode(EventType.text, forKey: .type)
            try container.encode(content, forKey: .content)
        case .done(let conversationId, let duplicate, let processingStatus, let gated, let reason):
            try container.encode(EventType.done, forKey: .type)
            try container.encode(conversationId, forKey: .conversationId)
            try container.encodeIfPresent(duplicate, forKey: .duplicate)
            try container.encodeIfPresent(processingStatus, forKey: .processingStatus)
            try container.encodeIfPresent(gated, forKey: .gated)
            try container.encodeIfPresent(reason, forKey: .reason)
        case .error(let error, let retryable):
            try container.encode(EventType.error, forKey: .type)
            try container.encode(error, forKey: .error)
            try container.encode(retryable, forKey: .retryable)
        }
    }
}

public struct WidgetErrorResponse: Codable, Sendable, Equatable {
    public let error: String
}

public struct ConversationSummary: Codable, Sendable, Equatable {
    public let id: String
    public let sessionId: String
    public let title: String
    public let unread: Bool
    public let unreadCount: Int
    public let status: String
    public let updatedAt: String
    public let messageCount: Int
    public let lastMessageRole: String?
}

public struct ConversationListResult: Codable, Sendable, Equatable {
    public let conversations: [ConversationSummary]
    public let totalUnreadCount: Int
}

public struct ConversationReadRequest: Codable, Sendable, Equatable {
    public let throughMessageId: String

    public init(throughMessageId: String) {
        self.throughMessageId = throughMessageId
    }
}

public struct ConversationReadResult: Codable, Sendable, Equatable {
    public let conversationId: String
    public let readThroughMessageId: String
    public let unread: Bool
    public let unreadCount: Int
}

public struct HelpCenterCatalog: Codable, Sendable, Equatable {
    public let topics: [HelpCenterTopic]
}

public struct HelpCenterTopic: Codable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let count: Int
    public let articles: [HelpCenterArticleSummary]
}

public struct HelpCenterArticleSummary: Codable, Sendable, Equatable {
    public let id: String
    public let title: String
    public let updatedAt: String
}

public struct HelpCenterArticleResult: Codable, Sendable, Equatable {
    public let article: HelpCenterArticle
}

public struct HelpCenterArticle: Codable, Sendable, Equatable {
    public let id: String
    public let title: String
    public let topic: String?
    public let body: String
    public let sourceType: String
    public let faqQuestion: String?
    public let updatedAt: String
    public let related: [HelpCenterRelatedArticle]
}

public struct HelpCenterRelatedArticle: Codable, Sendable, Equatable {
    public let id: String
    public let title: String
    public let topic: String?
}

public struct ConversationDetail: Codable, Sendable, Equatable {
    public let id: String
    public let sessionId: String
    public let status: String
    public let isHumanTakeover: Bool
}

public struct TranscriptMessage: Codable, Sendable, Equatable {
    public let id: String
    public let externalId: String?
    public let role: String
    public let senderType: String?
    public let senderName: String?
    public let senderTeam: String?
    public let text: String
    public let attachments: [JSONValue]
    public let timestamp: Int64
}

public struct TranscriptSync: Codable, Sendable, Equatable {
    public let previousCursor: String?
    public let nextCursor: String?
    public let limit: Int
}

public struct ConversationTranscriptResult: Codable, Sendable, Equatable {
    public let conversation: ConversationDetail
    public let messages: [TranscriptMessage]
    public let sync: TranscriptSync

    public init(conversation: ConversationDetail, messages: [TranscriptMessage], sync: TranscriptSync) {
        self.conversation = conversation
        self.messages = messages
        self.sync = sync
    }
}

public enum ConversationPageQuery: Sendable, Equatable {
    case latest(limit: Int? = nil)
    case before(String, limit: Int? = nil)
    case after(String, limit: Int? = nil)
}

public enum StreamEvent: Codable, Sendable, Equatable {
    case ready
    case configChanged(revision: String)
    case inboxConversation(conversationId: String)
    case inboxMessage(conversationId: String)

    private enum CodingKeys: String, CodingKey { case type, revision, conversationId }
    private enum EventType: String, Codable { case ready, configChanged = "config_changed", inboxConversation = "inbox.conversation", inboxMessage = "inbox.message" }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(EventType.self, forKey: .type) {
        case .ready: self = .ready
        case .configChanged: self = .configChanged(revision: try container.decode(String.self, forKey: .revision))
        case .inboxConversation: self = .inboxConversation(conversationId: try container.decode(String.self, forKey: .conversationId))
        case .inboxMessage: self = .inboxMessage(conversationId: try container.decode(String.self, forKey: .conversationId))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .ready:
            try container.encode(EventType.ready, forKey: .type)
        case .configChanged(let revision):
            try container.encode(EventType.configChanged, forKey: .type)
            try container.encode(revision, forKey: .revision)
        case .inboxConversation(let conversationId):
            try container.encode(EventType.inboxConversation, forKey: .type)
            try container.encode(conversationId, forKey: .conversationId)
        case .inboxMessage(let conversationId):
            try container.encode(EventType.inboxMessage, forKey: .type)
            try container.encode(conversationId, forKey: .conversationId)
        }
    }
}

public enum PushProvider: String, Codable, Sendable { case apns, fcm }
public enum PushEnvironment: String, Codable, Sendable { case sandbox, production }

public enum PushTokenRequest: Codable, Sendable, Equatable {
    case register(provider: PushProvider, token: String, notificationPreference: NotificationPreference?, locale: String?)
    case unregister

    public enum NotificationPreference: String, Codable, Sendable { case enabled, muted }
    private enum CodingKeys: String, CodingKey { case action, provider, token, notificationPreference, locale }
    private enum Action: String, Codable { case register, unregister }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Action.self, forKey: .action) {
        case .register:
            self = .register(
                provider: try container.decode(PushProvider.self, forKey: .provider),
                token: try container.decode(String.self, forKey: .token),
                notificationPreference: try container.decodeIfPresent(NotificationPreference.self, forKey: .notificationPreference),
                locale: try container.decodeIfPresent(String.self, forKey: .locale)
            )
        case .unregister: self = .unregister
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .register(let provider, let token, let notificationPreference, let locale):
            try container.encode(Action.register, forKey: .action)
            try container.encode(provider, forKey: .provider)
            try container.encode(token, forKey: .token)
            try container.encodeIfPresent(notificationPreference, forKey: .notificationPreference)
            try container.encodeIfPresent(locale, forKey: .locale)
        case .unregister:
            try container.encode(Action.unregister, forKey: .action)
        }
    }
}

public enum PushTokenResult: Codable, Sendable, Equatable {
    case active(state: State, provider: PushProvider, environment: PushEnvironment, fingerprint: String, registeredAt: String)
    case inactive(state: State)

    public enum State: String, Codable, Sendable { case active, muted, inactive }
    private enum CodingKeys: String, CodingKey { case state, provider, environment, fingerprint, registeredAt }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let state = try container.decode(State.self, forKey: .state)
        switch state {
        case .active, .muted:
            self = .active(
                state: state,
                provider: try container.decode(PushProvider.self, forKey: .provider),
                environment: try container.decode(PushEnvironment.self, forKey: .environment),
                fingerprint: try container.decode(String.self, forKey: .fingerprint),
                registeredAt: try container.decode(String.self, forKey: .registeredAt)
            )
        case .inactive: self = .inactive(state: state)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .active(let state, let provider, let environment, let fingerprint, let registeredAt):
            try container.encode(state, forKey: .state)
            try container.encode(provider, forKey: .provider)
            try container.encode(environment, forKey: .environment)
            try container.encode(fingerprint, forKey: .fingerprint)
            try container.encode(registeredAt, forKey: .registeredAt)
        case .inactive(let state): try container.encode(state, forKey: .state)
        }
    }
}

public enum PushNotificationType: String, Codable, Sendable {
    case messageAvailable = "message_available"
}

public struct PushNotificationPayload: Codable, Sendable, Equatable {
    public let conversationId: String
    public let messageId: String
    public let notificationType: PushNotificationType

    public init(conversationId: String, messageId: String, notificationType: PushNotificationType) {
        self.conversationId = conversationId
        self.messageId = messageId
        self.notificationType = notificationType
    }

    public var isOnloMessageAvailable: Bool { notificationType == .messageAvailable }
}

public enum OnloError: Error, Sendable, Equatable {
    case invalidConfiguration
    case configUnavailable
    case persistenceUnavailable
    case invalidUserJWT
    case notInitialized
    case invalidState
    case requiresNetwork
    case incompatibleProtocol
    case invalidResponse
    case remote(APIError)
    case transport(code: String)
    case correlatedTransport(code: String, requestId: String)
    case credentialStore(code: String)

    /// Safe for structured logs; never contains credentials, JWTs, message text, or URLs.
    public var safeCode: String {
        switch self {
        case .invalidConfiguration: "invalid_configuration"
        case .configUnavailable: "config_unavailable"
        case .persistenceUnavailable: "persistence_unavailable"
        case .invalidUserJWT: "invalid_user_jwt"
        case .notInitialized: "not_initialized"
        case .invalidState: "invalid_state"
        case .requiresNetwork: "requires_network"
        case .incompatibleProtocol: "incompatible_protocol"
        case .invalidResponse: "invalid_response"
        case .remote(let error): error.code.rawValue
        case .transport(let code): code
        case .correlatedTransport(let code, _): code
        case .credentialStore(let code): code
        }
    }

    /// Server-generated request IDs are opaque and safe to use for correlating
    /// a client failure with the matching PII-free server trace.
    public var requestId: String? {
        if case .remote(let error) = self { return error.requestId }
        if case .correlatedTransport(_, let requestId) = self { return requestId }
        return nil
    }

    public var transportCode: String? {
        switch self {
        case .transport(let code), .correlatedTransport(let code, _): code
        default: nil
        }
    }
}
