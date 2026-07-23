import Foundation
import CryptoKit

public enum SDKState: String, Sendable, Equatable {
    case uninitialized
    case restoring
    case anonymousReady
    case identifiedReady
    case offlineReady
    case identifying
    case logoutPending
    case reauthRequired
}

/// Token- and content-free native state for framework adapters.
@_spi(FrameworkBridge)
public struct SDKFrameworkState: Sendable, Equatable {
    public let state: SDKState
    public let unreadCount: Int?

    init(state: SDKState, unreadCount: Int?) {
        self.state = state
        self.unreadCount = unreadCount
    }
}

/// An adapter-safe request to present native messenger UI. The core authorizes a
/// supplied conversation ID before returning it; a UIKit or SwiftUI adapter owns
/// the actual presentation.
public enum OnloPresentationIntent: Sendable, Equatable {
    case messenger(conversationId: String?)
}

public actor OnloSDK {
    static let productionOrigin = URL(string: "https://onlo.ai")!
    static let implementedCapabilities = [
        "secure_storage",
        "persistent_outbox",
        "foreground_stream",
        "apns",
        "media_picker",
        "attachment_upload",
        "identity_jwt",
        "config_schema_v1",
    ]
    /// Internal dependency configuration used only by package tests and future
    /// native adapters. It is deliberately not part of the host-app API.
    struct Configuration: Sendable, Equatable {
        let sdkKey: String
        let appIdentifier: String
        let apiBaseURL: URL
        let sdkVersion: String
        let appVersion: String?
        let appBuild: String?
        let capabilities: [String]
        let sdkFamily: SDKFamily

        init(
            sdkKey: String,
            appIdentifier: String,
            apiBaseURL: URL,
            sdkVersion: String = "0.1.0",
            appVersion: String? = nil,
            appBuild: String? = nil,
            capabilities: [String] = [],
            sdkFamily: SDKFamily = .ios
        ) {
            self.sdkKey = sdkKey
            self.appIdentifier = appIdentifier
            self.apiBaseURL = apiBaseURL
            self.sdkVersion = sdkVersion
            self.appVersion = appVersion
            self.appBuild = appBuild
            self.capabilities = capabilities
            self.sdkFamily = sdkFamily
        }
    }

    private struct RuntimeSession: Sendable {
        let sessionId: String
        let chatToken: String
        let credential: StoredSessionCredential
    }

    private let credentialStore: any CredentialStoring
    private let configStore: any MobileConfigStoring
    private let pushIntentStore: any PushIntentStoring
    private let ownerStore: any OwnerScopedPersisting
    private let transport: any OnloHTTPTransport
    private let logger: any SDKLogging
    private let hostAppIdentifier: String?
    private let hostAppVersion: String?
    private let hostAppBuild: String?
    private let now: @Sendable () -> Date
    private let backoffJitter: @Sendable (Int) -> Double
    private let lifecycleBindingEnabled: Bool
    private var configuration: Configuration?
    private var requestFactory: OnloRequestFactory?
    private var runtimeSession: RuntimeSession?
    private var stateObservers: [UUID: AsyncStream<SDKState>.Continuation] = [:]
    private var frameworkStateObservers: [UUID: AsyncStream<SDKFrameworkState>.Continuation] = [:]
    private var unreadCount: Int? {
        didSet {
            guard oldValue != unreadCount else { return }
            publishFrameworkState()
        }
    }
    private var state: SDKState = .uninitialized {
        didSet {
            guard oldValue != state else { return }
            if state != .identifiedReady { unreadCount = nil }
            for observer in stateObservers.values { observer.yield(state) }
            publishFrameworkState()
        }
    }
    private var activeSendTasks: [OwnerScope: [UUID: Task<Void, Never>]] = [:]
    private var activeDispatchIDs: [OwnerScope: UUID] = [:]
    private var sendObservers: [OwnerScope: [UUID: AsyncThrowingStream<ChatEvent, Error>.Continuation]] = [:]
    private var retryWakeTasks: [OwnerScope: Task<Void, Never>] = [:]
    private var foregroundStreamTask: Task<Void, Never>?
    private var foregroundStreamScope: OwnerScope?
    private var foregroundStreamID: UUID?
    private var configRetryTask: Task<Void, Never>?
    private var suppressAutomaticConfigRefresh = false
    private var configAuthority = UUID()
    private var pushRetryTask: Task<Void, Never>?
    private var pushReconciliationInProgress = false
    private struct PendingAPNsRegistration: Sendable {
        let token: Data
        let notificationPreference: PushTokenRequest.NotificationPreference?
        let locale: String?
    }
    private var pendingAPNsRegistration: PendingAPNsRegistration?
    private var lifecycleBinding: OnloNativeLifecycleBinding?
    /// UIKit presenters register a weak-capturing MainActor invalidator. The
    /// core awaits these before progressing a logout/account boundary, so an
    /// old transcript cannot remain visible while a new owner becomes usable.
    private var messengerPresentationInvalidators: [UUID: @MainActor @Sendable () -> Void] = [:]

    /// Creates the native core with SDK-owned storage boundaries. The public API
    /// never accepts a host persistence implementation or plain-text fallback.
    public init(logger: any SDKLogging = OnloConsoleLogger.shared) {
        self.credentialStore = KeychainCredentialStore()
        self.configStore = KeychainMobileConfigStore()
        self.pushIntentStore = KeychainPushIntentStore()
        self.ownerStore = SQLiteOwnerScopedStore()
        self.transport = URLSessionOnloTransport()
        self.logger = logger
        self.hostAppIdentifier = Bundle.main.bundleIdentifier
        self.hostAppVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        self.hostAppBuild = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        self.now = Date.init
        self.backoffJitter = { _ in Double.random(in: -0.2...0.2) }
        self.lifecycleBindingEnabled = true
    }

    init(
        credentialStore: any CredentialStoring,
        configStore: any MobileConfigStoring = KeychainMobileConfigStore(),
        pushIntentStore: any PushIntentStoring = KeychainPushIntentStore(),
        ownerStore: any OwnerScopedPersisting,
        transport: any OnloHTTPTransport,
        logger: any SDKLogging = NoopSDKLogger(),
        hostAppIdentifier: String? = nil,
        hostAppVersion: String? = nil,
        hostAppBuild: String? = nil,
        now: @escaping @Sendable () -> Date = Date.init,
        backoffJitter: @escaping @Sendable (Int) -> Double = { _ in Double.random(in: -0.2...0.2) },
        lifecycleBindingEnabled: Bool = true
    ) {
        self.credentialStore = credentialStore
        self.configStore = configStore
        self.pushIntentStore = pushIntentStore
        self.ownerStore = ownerStore
        self.transport = transport
        self.logger = logger
        self.hostAppIdentifier = hostAppIdentifier
        self.hostAppVersion = hostAppVersion
        self.hostAppBuild = hostAppBuild
        self.now = now
        self.backoffJitter = backoffJitter
        self.lifecycleBindingEnabled = lifecycleBindingEnabled
    }

    @discardableResult
    public func initialize(sdkKey: String) async throws -> SDKState {
        guard !sdkKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw OnloError.invalidConfiguration
        }
        guard let appIdentifier = hostAppIdentifier, !appIdentifier.isEmpty else {
            throw OnloError.invalidConfiguration
        }
        return try await initialize(
            Configuration(
                sdkKey: sdkKey,
                appIdentifier: appIdentifier,
                apiBaseURL: Self.productionOrigin,
                appVersion: hostAppVersion,
                appBuild: hostAppBuild,
                capabilities: Self.implementedCapabilities
            )
        )
    }

    /// Initializes Onlo for this Operator app. `apiKey` is the public SDK key
    /// issued for the app integration; it is not an end-customer credential.
    ///
    /// This guide-style spelling is the preferred merchant-facing entry point.
    @discardableResult
    public func initialize(apiKey: String) async throws -> SDKState {
        try await initialize(sdkKey: apiKey)
    }

    /// Debug-only local integration entry point. The caller must supply the
    /// exact HTTPS origin of a development Onlo service; it is unavailable
    /// from release builds and never changes the production initializer.
    #if DEBUG
    @_spi(DevelopmentSupport)
    @discardableResult
    public func initializeDevelopment(sdkKey: String, onloDevelopmentOrigin: URL) async throws -> SDKState {
        guard !sdkKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let appIdentifier = hostAppIdentifier,
              !appIdentifier.isEmpty,
              onloDevelopmentOrigin.scheme?.lowercased() == "https",
              onloDevelopmentOrigin.host != nil else {
            throw OnloError.invalidConfiguration
        }
        return try await initialize(
            Configuration(
                sdkKey: sdkKey,
                appIdentifier: appIdentifier,
                apiBaseURL: onloDevelopmentOrigin,
                appVersion: hostAppVersion,
                appBuild: hostAppBuild,
                capabilities: Self.implementedCapabilities
            )
        )
    }

    /// SDK-team-only local integration spelling matching `initialize(apiKey:)`.
    @_spi(DevelopmentSupport)
    @discardableResult
    public func initializeDevelopment(apiKey: String, onloDevelopmentOrigin: URL) async throws -> SDKState {
        try await initializeDevelopment(sdkKey: apiKey, onloDevelopmentOrigin: onloDevelopmentOrigin)
    }
    #endif

    /// Framework adapters may declare their actual wrapper family without
    /// changing the native iOS runtime platform. This is SPI to avoid allowing
    /// ordinary host apps to spoof client family metadata.
    @_spi(FrameworkBridge)
    @discardableResult
    public func initializeFrameworkBridge(sdkKey: String, sdkFamily: SDKFamily) async throws -> SDKState {
        guard sdkFamily == .reactNative || sdkFamily == .flutter,
              !sdkKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let appIdentifier = hostAppIdentifier, !appIdentifier.isEmpty else {
            throw OnloError.invalidConfiguration
        }
        return try await initialize(Configuration(sdkKey: sdkKey, appIdentifier: appIdentifier, apiBaseURL: Self.productionOrigin, appVersion: hostAppVersion, appBuild: hostAppBuild, capabilities: Self.implementedCapabilities, sdkFamily: sdkFamily))
    }

    @discardableResult
    func initialize(_ configuration: Configuration) async throws -> SDKState {
        if let current = self.configuration {
            guard current == configuration else { throw OnloError.invalidState }
            return state
        }
        guard !configuration.sdkKey.isEmpty,
              !configuration.appIdentifier.isEmpty,
              !configuration.sdkVersion.isEmpty else {
            throw OnloError.invalidConfiguration
        }

        self.configuration = configuration
        self.requestFactory = try OnloRequestFactory(baseURL: configuration.apiBaseURL)
        if lifecycleBindingEnabled { installNativeLifecycleBindingIfNeeded() }
        state = .restoring

        let protectedState = try await credentialStore.loadState()
        let stored = protectedState.credential
        let pendingTransition = protectedState.pendingTransition
        if let stored {
            if stored.logoutPending {
                cancelActiveSends(for: stored.ownerScope)
                await invalidateMessengerPresentations()
                try await ownerStore.beginLogout(for: stored.ownerScope)
                state = .logoutPending
                // Best-effort recovery does not expose the old scope if the
                // network is absent; it simply retains logoutPending.
                try? await continuePendingLogout(stored, pendingTransition: pendingTransition)
            } else if case .identify = pendingTransition {
                // A JWT is intentionally not persisted. The host must supply a
                // fresh one before this exact identity transition can be replayed.
                state = .reauthRequired
            } else if pendingTransition != nil {
                state = .offlineReady
            } else {
                try await resume(stored, pendingTransition: pendingTransition)
            }
        } else if pendingTransition != nil {
            state = .offlineReady
        } else {
            try await bootstrapAnonymous(pendingTransition: pendingTransition)
        }
        return state
    }

    private func installNativeLifecycleBindingIfNeeded() {
        guard lifecycleBinding == nil else { return }
        let binding = OnloNativeLifecycleBinding(sdk: self)
        lifecycleBinding = binding
        binding.install()
    }

    /// Package-test teardown seam. The host app is never expected to manage the
    /// observer; it is installed once for the lifetime of this SDK instance.
    func stopNativeLifecycleBindingForTesting() {
        lifecycleBinding?.stop()
        lifecycleBinding = nil
    }

    @discardableResult
    public func loginUnidentifiedUser() async throws -> SDKState {
        try requireInitialized()
        if state == .offlineReady {
            let protectedState = try await credentialStore.loadState()
            let stored = protectedState.credential
            let pending = protectedState.pendingTransition
            if let stored, !stored.logoutPending, !(pending?.isIdentify ?? false) {
                try await resume(stored, pendingTransition: pending)
                return state
            }
            if stored == nil, pending?.isBootstrap ?? false {
                try await bootstrapAnonymous(pendingTransition: pending)
                return state
            }
        }
        guard let session = runtimeSession else {
            throw state == .offlineReady ? OnloError.requiresNetwork : OnloError.invalidState
        }
        if session.credential.identityClass == .identified {
            return try await logout()
        }
        guard state == .anonymousReady else { throw OnloError.invalidState }
        return state
    }

    @discardableResult
    public func loginIdentifiedUser(userJwt: String) async throws -> SDKState {
        guard isCompactJWT(userJwt) else { throw OnloError.invalidUserJWT }
        try requireInitialized()
        // A previous offline bootstrap leaves a protected pending transition
        // rather than inventing an anonymous owner. An identified host retry
        // must first finish that exact bootstrap, just as
        // `loginUnidentifiedUser()` does, before it can exchange the JWT.
        if state == .offlineReady {
            let protectedState = try await credentialStore.loadState()
            let stored = protectedState.credential
            let pending = protectedState.pendingTransition
            if let stored, !stored.logoutPending, !(pending?.isIdentify ?? false) {
                try await resume(stored, pendingTransition: pending)
            } else if stored == nil, pending?.isBootstrap == true {
                try await bootstrapAnonymous(pendingTransition: pending)
            }
        }
        cancelConfigRetry()
        // No config request authenticated by the prior account may be allowed
        // to complete once an account transition has begun.
        configAuthority = UUID()
        if let scope = runtimeSession?.credential.ownerScope { cancelForegroundStream(for: scope) }
        let protectedState = try await credentialStore.loadState()
        if state == .reauthRequired,
           let stored = protectedState.credential,
           let pending = protectedState.pendingTransition,
           pending.isIdentify,
           stored.identityClass == .anonymous {
            return try await replayPendingIdentify(pending, previous: stored, userJwt: userJwt)
        }
        guard let current = runtimeSession else { throw state == .offlineReady ? OnloError.requiresNetwork : OnloError.invalidState }

        // An account change must unlink the old contact before the new proof is exchanged.
        if current.credential.identityClass == .identified {
            cancelConfigRetry()
            _ = try await logout()
        }
        guard let anonymousSession = runtimeSession,
              anonymousSession.credential.identityClass == .anonymous else {
            throw OnloError.invalidState
        }

        state = .identifying
        let pending = try await pendingIdentify(for: anonymousSession.credential)
        let result: APIResponse<SessionResult>
        do {
            try await ensurePendingReplayAllowed(pending, userJwtProvided: true)
            result = try await sendSession(try pending.sessionOperation(userJwt: userJwt), installationId: pending.installationId)
        } catch {
            try await resolveDefinitiveSessionFailure(error, credential: anonymousSession.credential)
            state = .anonymousReady
            startForegroundStreamIfAvailable()
            throw error
        }

        guard pending.accepts(result.result), result.result.identityClass == .identified else {
            state = .anonymousReady
            throw OnloError.invalidResponse
        }

        // The anonymous partition is no longer usable after the server accepts identity.
        cancelActiveSends(for: anonymousSession.credential.ownerScope)
        await invalidateMessengerPresentations()
        try await ownerStore.beginLogout(for: anonymousSession.credential.ownerScope)
        try await ownerStore.finishLogout(for: anonymousSession.credential.ownerScope)
        let scope = OwnerScope(kind: .identified)
        try await ownerStore.prepare(scope: scope)
        let credential = StoredSessionCredential(
            installationId: result.result.installationId,
            generation: result.result.generation,
            proposedCredential: result.result.proposedCredential,
            identityClass: .identified,
            ownerScope: scope,
            logoutPending: false
        )
        try await commitProtectedState(credential: credential, pendingTransition: nil)
        runtimeSession = RuntimeSession(sessionId: result.result.sessionId, chatToken: result.result.chatToken, credential: credential)
        configAuthority = UUID()
        state = .identifiedReady
        await refreshConfigurationAfterSessionSuccess()
        startDurableDispatchIfNeeded()
        startForegroundStreamIfAvailable()
        await reconcilePushAfterSessionSuccess()
        await registerPendingAPNsAfterIdentify()
        return state
    }

    /// Associates the already authenticated merchant-app customer with Onlo.
    /// The value must be a short-lived HS256 user JWT minted by the Operator
    /// backend; the mobile app must neither mint nor persist it.
    @discardableResult
    public func identify(userJwt: String) async throws -> SDKState {
        try await loginIdentifiedUser(userJwt: userJwt)
    }

    /// Fetches a short-lived user JWT from the Operator backend and immediately
    /// exchanges it for an identified Onlo session. The provider executes in
    /// host-app code; the SDK never receives an Operator signing secret and
    /// does not persist the returned JWT.
    @discardableResult
    public func loginIdentifiedUser(
        using userJWTProvider: @Sendable () async throws -> String
    ) async throws -> SDKState {
        let userJwt = try await userJWTProvider()
        return try await loginIdentifiedUser(userJwt: userJwt)
    }

    /// Revokes/unlinks on the server before destructive local cleanup. If network
    /// work fails, the old owner remains durably blocked in `logoutPending`.
    @discardableResult
    public func logout() async throws -> SDKState {
        try requireInitialized()
        if state == .logoutPending {
            let protectedState = try await credentialStore.loadState()
            guard let stored = protectedState.credential, stored.logoutPending else { throw OnloError.invalidState }
            try await continuePendingLogout(stored, pendingTransition: protectedState.pendingTransition)
            return state
        }
        guard let session = runtimeSession else {
            throw state == .offlineReady ? OnloError.requiresNetwork : OnloError.invalidState
        }
        return try await logout(session.credential, chatToken: session.chatToken, sessionId: session.sessionId)
    }

    public func currentState() -> SDKState { state }

    /// Token-free lifecycle observation for framework-native EventChannels.
    /// It yields the current value first, then only distinct core transitions.
    public func observeState() -> AsyncStream<SDKState> {
        let id = UUID()
        return AsyncStream { continuation in
            continuation.yield(state)
            stateObservers[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeStateObserver(id) }
            }
        }
    }

    private func removeStateObserver(_ id: UUID) { stateObservers[id] = nil }

    /// Token-free framework observation. The first value is immediate.
    @_spi(FrameworkBridge)
    public func observeFrameworkState() -> AsyncStream<SDKFrameworkState> {
        let id = UUID()
        return AsyncStream { continuation in
            continuation.yield(SDKFrameworkState(state: state, unreadCount: unreadCount))
            frameworkStateObservers[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeFrameworkStateObserver(id) }
            }
        }
    }

    private func removeFrameworkStateObserver(_ id: UUID) { frameworkStateObservers[id] = nil }

    private func publishFrameworkState() {
        let snapshot = SDKFrameworkState(state: state, unreadCount: unreadCount)
        for observer in frameworkStateObservers.values { observer.yield(snapshot) }
    }

    func registerMessengerPresentationInvalidator(_ invalidator: @escaping @MainActor @Sendable () -> Void) -> UUID {
        let id = UUID()
        messengerPresentationInvalidators[id] = invalidator
        return id
    }

    func unregisterMessengerPresentationInvalidator(_ id: UUID) {
        messengerPresentationInvalidators[id] = nil
    }

    private func invalidateMessengerPresentations() async {
        let invalidators = Array(messengerPresentationInvalidators.values)
        await MainActor.run {
            for invalidate in invalidators { invalidate() }
        }
    }


    /// Selects exactly one durable text send for the native transport layer.
    /// v1 has no conversation target, so ordering is conservatively global per
    /// owner: a blocked head never permits a later row to overtake it.
    func nextDurableTextDispatch() async throws -> OutboxEntry? {
        guard let session = runtimeSession, state == .anonymousReady || state == .identifiedReady else { throw OnloError.invalidState }
        let authority = configAuthority
        let entries = try await ownerStore.recoverEligibleEntries(for: session.credential.ownerScope, now: now())
        guard configAuthority == authority,
              runtimeSession?.credential.ownerScope == session.credential.ownerScope else { throw OnloError.invalidState }
        let all = try await ownerStore.outboxEntries(for: session.credential.ownerScope)
        // A terminal failure is still the FIFO head. Until the native UI offers
        // an explicit resolution/removal policy, later rows must not overtake it.
        guard let head = all.first(where: { $0.state != .accepted && $0.state != .cancelled }) else { return nil }
        guard entries.contains(where: { $0.clientMessageId == head.clientMessageId }) else { return nil }
        var sending = head
        if sending.attachments.contains(where: { attachment in
            guard let expiresAt = attachment.receiptExpiresAt,
                  let expiry = serverDate(expiresAt) else { return true }
            return expiry <= now()
        }) {
            sending.state = .failedTerminal
            sending.lastErrorCode = APIErrorCode.mediaUnavailable.rawValue
            sending.nextAttemptAt = nil
            try await ownerStore.update(sending)
            return nil
        }
        sending.state = .sending
        sending.attemptCount += 1
        sending.nextAttemptAt = nil
        try await ownerStore.update(sending)
        return sending
    }

    /// Persists bounded retry eligibility for a failed durable attempt. Only
    /// transport/chat-retryable failures may re-enter FIFO; protocol failures
    /// become terminal and therefore cannot accidentally be resent.
    func recordDurableDispatchFailure(_ entry: OutboxEntry, retryable: Bool, safeCode: String) async throws {
        guard let session = runtimeSession,
              session.credential.ownerScope == entry.ownerScope else { throw OnloError.invalidState }
        var updated = entry
        updated.lastErrorCode = safeCode
        if retryable {
            let exponent = min(max(entry.attemptCount - 1, 0), 6)
            let base = min(1_000.0 * pow(2, Double(exponent)), 60_000.0)
            let jitter = min(max(backoffJitter(entry.attemptCount), -0.2), 0.2)
            updated.state = .failedRetryable
            updated.nextAttemptAt = now().addingTimeInterval((base * (1 + jitter)) / 1_000)
        } else {
            updated.state = .failedTerminal
            updated.nextAttemptAt = nil
        }
        try await ownerStore.update(updated)
    }

    /// Token-free last-known-good configuration for native presentation and
    /// bridge adapters. It remains available while offline.
    public func currentConfiguration() async throws -> MobileConfig? {
        try await configStore.loadConfigState().config
    }

    /// Completes the contract-owned image intent/upload flow and returns only
    /// the opaque handle that may be committed to the encrypted native outbox.
    /// Raw image bytes are never persisted by the SDK.
    func uploadImage(
        conversationId: String,
        data: Data,
        mimeType: ImageMimeType,
        filename: String
    ) async throws -> OutboxAttachment {
        guard !conversationId.isEmpty,
              !filename.isEmpty,
              !data.isEmpty else {
            throw OnloError.invalidConfiguration
        }
        guard state == .anonymousReady || state == .identifiedReady,
              let session = runtimeSession,
              let requestFactory else {
            throw state == .offlineReady ? OnloError.requiresNetwork : OnloError.invalidState
        }
        let configState = try await configStore.loadConfigState()
        guard let config = configState.config,
              config.features.fileUpload,
              config.mediaPolicy.enabled,
              config.mediaPolicy.effectiveMaximumImagesPerMessage > 0,
              data.count <= config.mediaPolicy.effectiveMaximumImageBytes else {
            throw OnloError.remote(APIError(
                code: .mediaUnavailable,
                message: "Image upload is unavailable.",
                retry: try APIRetry(directive: .never)
            ))
        }

        let authority = configAuthority
        let scope = session.credential.ownerScope
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let intentBody = AttachmentIntentRequest(
            conversationId: conversationId,
            mimeType: mimeType,
            byteSize: data.count,
            sha256: digest,
            filename: filename
        )
        let intentResponse = try await transport.execute(
            try requestFactory.attachmentIntent(intentBody, chatToken: session.chatToken)
        )
        let intent = try OnloResponseDecoder.envelope(AttachmentIntentResult.self, from: intentResponse).result
        guard configAuthority == authority,
              runtimeSession?.sessionId == session.sessionId,
              runtimeSession?.credential.ownerScope == scope else {
            throw OnloError.invalidState
        }
        guard !intent.attachmentId.isEmpty,
              !intent.intent.isEmpty,
              serverDate(intent.expiresAt) != nil,
              intent.completion.method == "POST",
              intent.completion.endpoint == "/api/sdk/v1/attachments/complete" else {
            throw OnloError.invalidResponse
        }

        let completionResponse = try await transport.execute(
            try requestFactory.attachmentCompletion(
                intent: intent.intent,
                fileData: data,
                filename: filename,
                mimeType: mimeType,
                chatToken: session.chatToken
            )
        )
        let completed = try OnloResponseDecoder.envelope(AttachmentCompleteResult.self, from: completionResponse).result
        guard configAuthority == authority,
              runtimeSession?.sessionId == session.sessionId,
              runtimeSession?.credential.ownerScope == scope else {
            throw OnloError.invalidState
        }
        guard completed.attachment.id == intent.attachmentId,
              completed.attachment.type == mimeType,
              completed.attachment.name == filename,
              completed.attachment.size == data.count,
              completed.attachment.sha256.lowercased() == digest,
              !completed.attachment.url.isEmpty,
              !completed.receipt.isEmpty,
              serverDate(completed.receiptExpiresAt).map({ $0 > now() }) == true,
              !completed.authenticatedDownload.isEmpty else {
            throw OnloError.invalidResponse
        }
        return OutboxAttachment(
            attachment: ChatAttachment(
                id: completed.attachment.id,
                url: completed.attachment.url,
                type: completed.attachment.type.rawValue,
                name: completed.attachment.name,
                size: completed.attachment.size,
                sha256: completed.attachment.sha256,
                receipt: completed.receipt
            ),
            receiptExpiresAt: completed.receiptExpiresAt
        )
    }

    private func serverDate(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) { return date }
        let wholeSeconds = ISO8601DateFormatter()
        wholeSeconds.formatOptions = [.withInternetDateTime]
        return wholeSeconds.date(from: value)
    }

    /// Native messenger-only inbox fetch. Conversation metadata is accepted
    /// only when every result belongs to the bearer session captured before
    /// the request. It is not a headless public transcript API.
    func messengerInbox() async throws -> [ConversationSummary] {
        let startedAt = Date()
        do {
            guard state == .anonymousReady || state == .identifiedReady,
                  let session = runtimeSession else {
                throw state == .offlineReady ? OnloError.requiresNetwork : OnloError.invalidState
            }
            let inbox = try await authorisedInbox(for: session)
            await record(operation: "inbox", code: "ok", requestId: nil, startedAt: startedAt)
            return inbox.conversations
        } catch let error as OnloError {
            await record(operation: "inbox", code: error.safeCode, requestId: nil, startedAt: startedAt)
            throw error
        } catch {
            await record(operation: "inbox", code: "network_unavailable", requestId: nil, startedAt: startedAt)
            throw OnloError.transport(code: "network_unavailable")
        }
    }

    /// The list remains session-authorised. Customer unread state is exposed
    /// only for a verified identity; anonymous summaries are scrubbed.
    private func authorisedInbox(for session: RuntimeSession) async throws -> ConversationListResult {
        guard let requestFactory else { throw OnloError.invalidState }
        let response = try await transport.execute(try requestFactory.conversations(chatToken: session.chatToken, limit: 50))
        let inbox = try OnloResponseDecoder.widget(ConversationListResult.self, from: response)
        var conversationIDs = Set<String>()
        let summariesAreValid = inbox.conversations.allSatisfy { conversation in
                !conversation.id.isEmpty &&
                !conversation.sessionId.isEmpty &&
                conversation.unreadCount >= 0 &&
                conversation.unread == (conversation.unreadCount > 0) &&
                conversation.messageCount >= 0 &&
                conversationIDs.insert(conversation.id).inserted
        }
        guard runtimeSession?.sessionId == session.sessionId,
              runtimeSession?.credential.ownerScope == session.credential.ownerScope,
              inbox.totalUnreadCount >= 0,
              summariesAreValid else {
            throw OnloError.invalidResponse
        }
        if session.credential.identityClass == .identified {
            unreadCount = inbox.totalUnreadCount
            return inbox
        }
        unreadCount = nil
        return ConversationListResult(
            conversations: inbox.conversations.map {
                ConversationSummary(
                    id: $0.id,
                    sessionId: $0.sessionId,
                    title: $0.title,
                    unread: false,
                    unreadCount: 0,
                    status: $0.status,
                    updatedAt: $0.updatedAt,
                    messageCount: $0.messageCount,
                    lastMessageRole: $0.lastMessageRole
                )
            },
            totalUnreadCount: 0
        )
    }

    func messengerHelpCenter() async throws -> [HelpCenterTopic] {
        guard state == .anonymousReady || state == .identifiedReady,
              let session = runtimeSession,
              let requestFactory else {
            throw state == .offlineReady ? OnloError.requiresNetwork : OnloError.invalidState
        }
        let authority = configAuthority
        let response = try await transport.execute(
            try requestFactory.helpCenter(chatToken: session.chatToken)
        )
        let catalog = try OnloResponseDecoder.widget(HelpCenterCatalog.self, from: response)
        var topicIDs = Set<String>()
        var articleIDs = Set<String>()
        let isValid = catalog.topics.count <= 100 && catalog.topics.allSatisfy { topic in
            !topic.id.isEmpty &&
                !topic.name.isEmpty &&
                topic.count == topic.articles.count &&
                topicIDs.insert(topic.id).inserted &&
                topic.articles.allSatisfy { article in
                    !article.id.isEmpty &&
                        !article.title.isEmpty &&
                        articleIDs.insert(article.id).inserted
                }
        }
        guard isValid,
              configAuthority == authority,
              runtimeSession?.sessionId == session.sessionId else {
            throw OnloError.invalidResponse
        }
        return catalog.topics
    }

    func messengerHelpCenterArticle(articleId: String) async throws -> HelpCenterArticle {
        guard !articleId.isEmpty,
              state == .anonymousReady || state == .identifiedReady,
              let session = runtimeSession,
              let requestFactory else {
            throw state == .offlineReady ? OnloError.requiresNetwork : OnloError.invalidState
        }
        let authority = configAuthority
        let response = try await transport.execute(
            try requestFactory.helpCenterArticle(articleId: articleId, chatToken: session.chatToken)
        )
        let result = try OnloResponseDecoder.widget(HelpCenterArticleResult.self, from: response)
        guard result.article.id == articleId,
              !result.article.title.isEmpty,
              result.article.body.count <= 1_000_000,
              configAuthority == authority,
              runtimeSession?.sessionId == session.sessionId else {
            throw OnloError.invalidResponse
        }
        return result.article
    }

    /// Called by the native presenter only after it has committed the fetched
    /// transcript to visible UI. Anonymous sessions intentionally do nothing.
    func acknowledgeRenderedConversation(
        conversationId: String,
        throughMessageId: String
    ) async throws {
        guard state == .identifiedReady,
              let session = runtimeSession,
              session.credential.identityClass == .identified,
              let requestFactory else { return }
        let authority = configAuthority
        let response = try await transport.execute(
            try requestFactory.acknowledgeRead(
                conversationId: conversationId,
                throughMessageId: throughMessageId,
                chatToken: session.chatToken
            )
        )
        let result = try OnloResponseDecoder.widget(ConversationReadResult.self, from: response)
        guard result.conversationId == conversationId,
              result.readThroughMessageId == throughMessageId,
              !result.unread,
              result.unreadCount == 0,
              configAuthority == authority,
              runtimeSession?.sessionId == session.sessionId else {
            throw OnloError.invalidResponse
        }
        _ = try await authorisedInbox(for: session)
    }

    /// Native messenger-only transcript fetch. Offline presentation may render
    /// a previously authorised encrypted transcript, but never one from a
    /// different owner scope.
    func messengerTranscript(conversationId: String) async throws -> ConversationTranscriptResult? {
        let startedAt = Date()
        do {
        guard !conversationId.isEmpty,
              let transcriptStore = ownerStore as? any TranscriptPersisting else {
            throw OnloError.invalidConfiguration
        }
        if state == .offlineReady {
            let protected = try await credentialStore.loadState()
            guard let credential = protected.credential, !credential.logoutPending else { return nil }
            let transcript = try await transcriptStore.transcript(conversationId: conversationId, for: credential.ownerScope)
            await record(operation: "transcript", code: "offline_cache", requestId: nil, startedAt: startedAt)
            return transcript
        }
        guard state == .anonymousReady || state == .identifiedReady,
              let session = runtimeSession,
              let requestFactory else { throw OnloError.invalidState }
        let response = try await transport.execute(try requestFactory.transcript(conversationId: conversationId, query: .latest(limit: 100), chatToken: session.chatToken))
        let transcript = try OnloResponseDecoder.widget(ConversationTranscriptResult.self, from: response)
        guard isAuthorisedTranscript(transcript, conversationId: conversationId, session: session) else {
            throw OnloError.invalidResponse
        }
        try await transcriptStore.replaceTranscript(transcript, for: session.credential.ownerScope)
        guard runtimeSession?.sessionId == session.sessionId,
              runtimeSession?.credential.ownerScope == session.credential.ownerScope else {
            return nil
        }
        await record(operation: "transcript", code: "ok", requestId: nil, startedAt: startedAt)
        return transcript
        } catch let error as OnloError {
            await record(operation: "transcript", code: error.safeCode, requestId: nil, startedAt: startedAt)
            throw error
        } catch {
            await record(operation: "transcript", code: "network_unavailable", requestId: nil, startedAt: startedAt)
            throw OnloError.transport(code: "network_unavailable")
        }
    }

    /// Lifecycle/reachability adapters call this after foreground or recovery.
    public func refreshConfigurationForForeground() async throws {
        try requireInitialized()
        if state == .logoutPending {
            let protected = try await credentialStore.loadState()
            guard let stored = protected.credential, stored.logoutPending else { throw OnloError.invalidState }
            try await continuePendingLogout(stored, pendingTransition: protected.pendingTransition)
            return
        }
        var recoveredSession = false
        if state == .offlineReady || state == .restoring {
            let protected = try await credentialStore.loadState()
            if protected.pendingTransition?.isIdentify == true {
                // The original JWT was intentionally discarded. Preserve the
                // exact transition until the host supplies a fresh one.
                state = .reauthRequired
                return
            }
            if let stored = protected.credential, !stored.logoutPending {
                try await resume(stored, pendingTransition: protected.pendingTransition)
                recoveredSession = state == .anonymousReady || state == .identifiedReady
            } else if protected.credential == nil, protected.pendingTransition?.isBootstrap == true {
                try await bootstrapAnonymous(pendingTransition: protected.pendingTransition)
                recoveredSession = state == .anonymousReady || state == .identifiedReady
            } else if protected.credential == nil, protected.pendingTransition == nil {
                try await bootstrapAnonymous()
                recoveredSession = state == .anonymousReady || state == .identifiedReady
            }
            guard state == .anonymousReady || state == .identifiedReady else { return }
        }
        // Resume/bootstrap already conditionally refreshes config and starts
        // durable dispatch, stream, and push reconciliation on success.
        guard !recoveredSession else { return }
        try await refreshConfiguration()
        startDurableDispatchIfNeeded()
        startForegroundStreamIfAvailable()
        await reconcilePushAfterSessionSuccess()
    }

    /// A `config_changed` stream hint has no payload by contract; refetch it.
    public func configurationChanged() async throws {
        try requireInitialized()
        try await refreshConfiguration()
    }

    /// Queues before opening the SSE request. The same UUID is retained for all
    /// retry attempts; callers consume text as individual SSE events.
    /// Native UI-facing composer entry point. It is intentionally package
    /// internal until the messenger presentation surface is ready; host apps
    /// cannot inject raw payloads or attachment URLs into the transport.
    func sendMessage(
        message: String
    ) async throws -> AsyncThrowingStream<ChatEvent, Error> {
        try await sendMessage(message: message, attachments: [])
    }

    /// Internal-only until the attachment intent/completion lifecycle returns
    /// an opaque completed handle. Host apps cannot supply arbitrary URLs.
    func sendMessage(
        message: String,
        attachments: [OutboxAttachment]
    ) async throws -> AsyncThrowingStream<ChatEvent, Error> {
        try requireInitialized()
        guard !message.isEmpty || !attachments.isEmpty else {
            throw OnloError.invalidConfiguration
        }
        if !attachments.isEmpty {
            let configState = try await configStore.loadConfigState()
            guard let config = configState.config,
                  config.features.fileUpload,
                  config.mediaPolicy.enabled,
                  attachments.count <= config.mediaPolicy.effectiveMaximumImagesPerMessage,
                  attachments.allSatisfy({
                      $0.attachment.size <= config.mediaPolicy.effectiveMaximumImageBytes
                  }) else {
                throw OnloError.invalidConfiguration
            }
        }
        guard attachments.count <= OnloProtocol.maximumImagesPerMessage,
              attachments.allSatisfy({
                  !$0.attachment.url.isEmpty &&
                      !$0.attachment.type.isEmpty &&
                      !$0.attachment.name.isEmpty &&
                      $0.attachment.size > 0 &&
                      $0.attachment.size <= OnloProtocol.maximumImageBytes &&
                      $0.attachment.receipt?.isEmpty == false &&
                      $0.receiptExpiresAt.flatMap(serverDate).map({ $0 > now() }) == true
              }) else {
            throw OnloError.invalidConfiguration
        }
        let ownerScope: OwnerScope
        let canDispatchNow: Bool
        if let session = runtimeSession, state == .anonymousReady || state == .identifiedReady {
            ownerScope = session.credential.ownerScope
            canDispatchNow = true
        } else if state == .offlineReady {
            let protected = try await credentialStore.loadState()
            guard let credential = protected.credential, !credential.logoutPending else { throw OnloError.invalidState }
            ownerScope = credential.ownerScope
            canDispatchNow = false
        } else {
            throw OnloError.invalidState
        }
        // Register the observer before the persistence await. An existing
        // dispatcher can otherwise run while this actor is suspended in the
        // store and accept the newly committed row before its caller has a
        // stream to receive that first SSE event.
        let entry = OutboxEntry(ownerScope: ownerScope, message: message, attachments: attachments, orderingKey: 0)
        var observer: AsyncThrowingStream<ChatEvent, Error>.Continuation?
        let stream = AsyncThrowingStream<ChatEvent, Error> { observer = $0 }
        guard let observer else { throw OnloError.invalidState }
        registerObserver(observer, for: entry)
        observer.onTermination = { [weak self] _ in
            Task { await self?.removeObserver(for: entry) }
        }
        do {
            _ = try await ownerStore.enqueueAssigningOrder(entry)
        } catch {
            finishObserver(for: entry, error: error)
            throw error
        }
        if canDispatchNow { startDurableDispatchIfNeeded() }
        return stream
    }

    public func present(conversationId: String? = nil) async throws -> OnloPresentationIntent {
        guard state == .anonymousReady || state == .identifiedReady || state == .offlineReady else {
            throw OnloError.invalidState
        }
        guard let conversationId else { return .messenger(conversationId: nil) }
        guard state != .offlineReady, let session = runtimeSession, let requestFactory else {
            throw OnloError.requiresNetwork
        }

        let request = try requestFactory.transcript(
            conversationId: conversationId,
            query: .latest(limit: 1),
            chatToken: session.chatToken
        )
        let startedAt = Date()
        do {
            let response = try await transport.execute(request)
            let transcript = try OnloResponseDecoder.widget(ConversationTranscriptResult.self, from: response)
            guard isAuthorisedTranscript(transcript, conversationId: conversationId, session: session) else {
                throw OnloError.invalidResponse
            }
            await record(operation: "present", code: "ok", requestId: nil, startedAt: startedAt)
            return .messenger(conversationId: conversationId)
        } catch let error as OnloError {
            await record(operation: "present", code: error.safeCode, requestId: nil, startedAt: startedAt)
            throw error
        } catch {
            await record(operation: "present", code: "network_unavailable", requestId: nil, startedAt: startedAt)
            throw OnloError.transport(code: "network_unavailable")
        }
    }

    /// Adapter seam that preserves the same authorization check as `present`.
    public func openConversation(_ conversationId: String) async throws -> OnloPresentationIntent {
        guard !conversationId.isEmpty else { throw OnloError.invalidConfiguration }
        return try await present(conversationId: conversationId)
    }

    /// Registers a host-provided APNs device token. The raw token is converted
    /// only for the contract request and protected pending intent; it is never
    /// logged or exposed through framework state.
    @discardableResult
    public func setAPNsPushToken(
        _ token: Data,
        notificationPreference: PushTokenRequest.NotificationPreference? = nil,
        locale: String? = nil
    ) async throws -> OnloPushRegistrationState {
        try requireInitialized()
        guard !token.isEmpty, token.count <= 512 else { throw OnloError.invalidConfiguration }
        let registration = PendingAPNsRegistration(
            token: token,
            notificationPreference: notificationPreference,
            locale: locale
        )
        pendingAPNsRegistration = registration
        guard state == .identifiedReady,
              let session = runtimeSession,
              session.credential.identityClass == .identified else { return .pendingRetry }
        return try await persistAndReconcileAPNs(registration, session: session)
    }

    private func persistAndReconcileAPNs(
        _ registration: PendingAPNsRegistration,
        session: RuntimeSession
    ) async throws -> OnloPushRegistrationState {
        let existing = try await pushIntentStore.load()
        // A pending intent belongs to the scope that created it. A newly
        // authenticated account must never overwrite it or inherit its token.
        if let existing, existing.ownerScope != session.credential.ownerScope {
            throw OnloError.invalidState
        }
        let value = registration.token.map { String(format: "%02x", $0) }.joined()
        let intent = ProtectedPushIntent(
            ownerScope: session.credential.ownerScope,
            action: .register,
            token: value,
            notificationPreference: registration.notificationPreference,
            locale: registration.locale
        )
        try await pushIntentStore.save(intent) // persist before any network work
        return try await reconcilePushIntent(allowTokenRefresh: true)
    }

    private func registerPendingAPNsAfterIdentify() async {
        guard let registration = pendingAPNsRegistration,
              state == .identifiedReady,
              let session = runtimeSession,
              session.credential.identityClass == .identified else { return }
        _ = try? await persistAndReconcileAPNs(registration, session: session)
    }

    /// SPI used by framework-native adapters. It intentionally accepts bytes,
    /// not a JavaScript/Dart string, so a bridge need not retain token state.
    @_spi(FrameworkBridge)
    @discardableResult
    public func setAPNsPushTokenFromBridge(_ token: Data) async throws -> OnloPushRegistrationState {
        try await setAPNsPushToken(token)
    }

    /// Validates an already extracted, contract-shaped Onlo APNs payload,
    /// refetches the authoritative transcript, and only then returns a host
    /// presentation intent. It never displays notification content itself.
    public func handlePushNotification(_ payload: PushNotificationPayload) async throws -> OnloPushNotificationHandling {
        guard payload.isOnloMessageAvailable,
              !payload.conversationId.isEmpty,
              !payload.messageId.isEmpty else { return .notOnlo }
        guard state == .identifiedReady,
              let session = runtimeSession,
              session.credential.identityClass == .identified,
              let requestFactory else { return .deferred }
        let authority = configAuthority
        let scope = session.credential.ownerScope
        let request = try requestFactory.transcript(
            conversationId: payload.conversationId,
            query: .latest(limit: 100),
            chatToken: session.chatToken
        )
        do {
            let response = try await transport.execute(request)
            let transcript = try OnloResponseDecoder.widget(ConversationTranscriptResult.self, from: response)
            guard transcript.conversation.id == payload.conversationId,
                  !transcript.conversation.sessionId.isEmpty,
                  transcript.messages.contains(where: { $0.id == payload.messageId }) else {
                return .notOnlo
            }
            // Network suspension can cross logout/account switch. Check again
            // immediately before persisting or returning a route.
            guard configAuthority == authority,
                  runtimeSession?.sessionId == session.sessionId,
                  runtimeSession?.credential.ownerScope == scope else { return .deferred }
            guard let transcriptStore = ownerStore as? any TranscriptPersisting else {
                throw OnloError.persistenceUnavailable
            }
            try await transcriptStore.replaceTranscript(transcript, for: scope)
            guard configAuthority == authority,
                  runtimeSession?.sessionId == session.sessionId,
                  runtimeSession?.credential.ownerScope == scope else { return .deferred }
            return .handled(.messenger(conversationId: payload.conversationId))
        } catch let error as OnloError {
            if case .transport = error { return .deferred }
            throw error
        } catch {
            return .deferred
        }
    }

    @_spi(FrameworkBridge)
    public func handlePushNotificationFromBridge(_ payload: PushNotificationPayload) async throws -> OnloPushNotificationHandling {
        try await handlePushNotification(payload)
    }

    /// Replays one protected, owner-bound idempotent token operation. This is
    /// called after a usable session returns and on explicit host token change;
    /// it never creates a new token or substitutes a different owner scope.
    @discardableResult
    private func reconcilePushIntent(allowTokenRefresh: Bool) async throws -> OnloPushRegistrationState {
        guard !pushReconciliationInProgress else { return .pendingRetry }
        guard let session = runtimeSession,
              state == .anonymousReady || state == .identifiedReady else {
            throw OnloError.requiresNetwork
        }
        guard let intent = try await pushIntentStore.load() else { return .registered }
        guard intent.ownerScope == session.credential.ownerScope else {
            // Keep the previous account's protected work unavailable rather
            // than attempting to authorise it with the current account.
            return .requiresHostAction
        }
        if intent.isRegistered { return .registered }
        if !intent.automaticallyRetryable { return .requiresHostAction }
        if let eligibleAt = intent.eligibleAt, now() < eligibleAt { return .pendingRetry }
        // This must cover the resume below: a successful Resume triggers its
        // own best-effort reconciliation hook. Without ownership established
        // first, a reconstructed after_token_refresh intent recursively
        // resumes before the durable prerequisite can be consumed.
        pushReconciliationInProgress = true
        defer { pushReconciliationInProgress = false }
        if intent.requiresFreshBearer {
            guard allowTokenRefresh else { return .requiresHostAction }
            try await resume(session.credential)
            guard let refreshed = runtimeSession, refreshed.credential.ownerScope == intent.ownerScope else { return .pendingRetry }
            let once = copiedPushIntent(intent, retryDirective: nil, requiresFreshBearer: false)
            try await pushIntentStore.save(once)
            return try await sendPushIntent(once, session: refreshed, allowTokenRefresh: false, permitsBlockedOwner: false)
        }
        return try await sendPushIntent(intent, session: session, allowTokenRefresh: allowTokenRefresh, permitsBlockedOwner: false)
    }

    /// Runs only after the owner was durably blocked. It uses the exact same
    /// v1 directive handling as ordinary reconciliation, but an ephemeral old
    /// bearer is permitted solely for the unregister request.
    private func reconcileBlockedOwnerPushIntent(_ session: RuntimeSession) async throws -> OnloPushRegistrationState {
        guard let intent = try await pushIntentStore.load(), intent.ownerScope == session.credential.ownerScope else { return .registered }
        guard intent.action == .unregister else { throw OnloError.invalidState }
        if !intent.automaticallyRetryable { return .requiresHostAction }
        if let eligibleAt = intent.eligibleAt, now() < eligibleAt { return .pendingRetry }
        if intent.requiresFreshBearer {
            let result = try await resumeForLogoutUnlink(session.credential)
            let credential = StoredSessionCredential(installationId: result.installationId, generation: result.generation, proposedCredential: result.proposedCredential, identityClass: result.identityClass, ownerScope: intent.ownerScope, logoutPending: true)
            let once = copiedPushIntent(intent, retryDirective: nil, requiresFreshBearer: false)
            try await pushIntentStore.save(once)
            return try await sendPushIntent(once, session: RuntimeSession(sessionId: result.sessionId, chatToken: result.chatToken, credential: credential), allowTokenRefresh: false, permitsBlockedOwner: true)
        }
        return try await sendPushIntent(intent, session: session, allowTokenRefresh: true, permitsBlockedOwner: true)
    }

    private func sendPushIntent(
        _ intent: ProtectedPushIntent,
        session: RuntimeSession,
        allowTokenRefresh: Bool,
        permitsBlockedOwner: Bool
    ) async throws -> OnloPushRegistrationState {
        let authorised: Bool
        if permitsBlockedOwner {
            authorised = state == .logoutPending && session.credential.ownerScope == intent.ownerScope
        } else {
            authorised = runtimeSession?.sessionId == session.sessionId && runtimeSession?.credential.ownerScope == intent.ownerScope
        }
        guard authorised, let requestFactory else { return .pendingRetry }
        let body: PushTokenRequest
        switch intent.action {
        case .register:
            guard let token = intent.token, token.count >= 16 else { throw OnloError.invalidConfiguration }
            body = .register(provider: .apns, token: token, notificationPreference: intent.notificationPreference, locale: intent.locale)
        case .unregister:
            body = .unregister
        }
        do {
            let response = try await transport.execute(try requestFactory.pushToken(body, chatToken: session.chatToken))
            let envelope = try OnloResponseDecoder.envelope(PushTokenResult.self, from: response)
            if !permitsBlockedOwner {
                guard runtimeSession?.sessionId == session.sessionId,
                      runtimeSession?.credential.ownerScope == intent.ownerScope else { return .pendingRetry }
            }
            switch (intent.action, envelope.result) {
            case (.register, .active(let state, let provider, _, _, _)):
                guard provider == .apns, state == .active || state == .muted else { throw OnloError.invalidResponse }
                // Retain the active token only in protected storage. It is
                // needed to durably convert an active association into an
                // unregister intent when this owner logs out.
                try await pushIntentStore.save(ProtectedPushIntent(
                    ownerScope: intent.ownerScope,
                    action: .register,
                    token: intent.token,
                    notificationPreference: intent.notificationPreference,
                    locale: intent.locale,
                    attemptCount: 0,
                    eligibleAt: nil,
                    isRegistered: true,
                    automaticallyRetryable: false
                ))
            case (.unregister, .inactive(let state)):
                guard state == .inactive else { throw OnloError.invalidResponse }
                try await pushIntentStore.clear()
            default:
                throw OnloError.invalidResponse
            }
            pushRetryTask?.cancel(); pushRetryTask = nil
            return .registered
        } catch let error as OnloError {
            if case let .remote(remote) = error {
                switch remote.retry.directive {
                case .afterTokenRefresh where allowTokenRefresh:
                    // Persist this prerequisite before touching session state;
                    // recovery can never retry with the stale bearer.
                    let gated = copiedPushIntent(intent, retryDirective: .afterTokenRefresh, requiresFreshBearer: true)
                    try await pushIntentStore.save(gated)
                    let refreshed: RuntimeSession
                    if permitsBlockedOwner {
                        let result = try await resumeForLogoutUnlink(session.credential)
                        let credential = StoredSessionCredential(installationId: result.installationId, generation: result.generation, proposedCredential: result.proposedCredential, identityClass: result.identityClass, ownerScope: intent.ownerScope, logoutPending: true)
                        refreshed = RuntimeSession(sessionId: result.sessionId, chatToken: result.chatToken, credential: credential)
                    } else {
                        try await resume(session.credential)
                        guard let active = runtimeSession, active.credential.ownerScope == intent.ownerScope else { return .pendingRetry }
                        refreshed = active
                    }
                    let once = copiedPushIntent(gated, retryDirective: nil, requiresFreshBearer: false)
                    try await pushIntentStore.save(once)
                    return try await sendPushIntent(once, session: refreshed, allowTokenRefresh: false, permitsBlockedOwner: permitsBlockedOwner)
                case .afterBackoff:
                    return try await deferPushIntent(intent, serverRetryAfterMs: remote.retry.retryAfterMs, directive: .afterBackoff)
                case .never, .afterAttestation, .afterFullSync, .afterTokenRefresh:
                    try await pushIntentStore.save(copiedPushIntent(intent, retryDirective: remote.retry.directive, requiresFreshBearer: false, automaticallyRetryable: false))
                    return .requiresHostAction
                }
            }
            // A transport outcome is ambiguous. Both operations are
            // idempotent, so retain the exact protected intent with bounded
            // local backoff rather than treating it as server-directed retry.
            if case .transport = error { return try await deferPushIntent(intent, serverRetryAfterMs: nil, directive: nil) }
            throw error
        } catch {
            return try await deferPushIntent(intent, serverRetryAfterMs: nil, directive: nil)
        }
    }

    private func copiedPushIntent(_ intent: ProtectedPushIntent, retryDirective: RetryDirective?, requiresFreshBearer: Bool, automaticallyRetryable: Bool? = nil, eligibleAt: Date? = nil, attemptCount: Int? = nil) -> ProtectedPushIntent {
        ProtectedPushIntent(ownerScope: intent.ownerScope, action: intent.action, token: intent.token, notificationPreference: intent.notificationPreference, locale: intent.locale, attemptCount: attemptCount ?? intent.attemptCount, eligibleAt: eligibleAt, retryDirective: retryDirective, requiresFreshBearer: requiresFreshBearer, isRegistered: false, automaticallyRetryable: automaticallyRetryable ?? intent.automaticallyRetryable)
    }

    private func deferPushIntent(_ intent: ProtectedPushIntent, serverRetryAfterMs: Int?, directive: RetryDirective?) async throws -> OnloPushRegistrationState {
        guard intent.attemptCount < 3 else {
            try await pushIntentStore.save(copiedPushIntent(intent, retryDirective: directive, requiresFreshBearer: false, automaticallyRetryable: false))
            return .requiresHostAction
        }
        let attempt = intent.attemptCount + 1
        let delay: TimeInterval
        if let serverRetryAfterMs {
            delay = TimeInterval(max(0, serverRetryAfterMs)) / 1_000
        } else {
            let base = min(1_000.0 * pow(2, Double(attempt - 1)), 60_000.0)
            let jitter = min(max(backoffJitter(attempt), -0.2), 0.2)
            delay = (base * (1 + jitter)) / 1_000
        }
        let deferred = copiedPushIntent(intent, retryDirective: directive, requiresFreshBearer: false, eligibleAt: now().addingTimeInterval(delay), attemptCount: attempt)
        try await pushIntentStore.save(deferred)
        schedulePushRetry(for: deferred, delay: delay)
        return .pendingRetry
    }

    private func schedulePushRetry(for intent: ProtectedPushIntent, delay: TimeInterval) {
        pushRetryTask?.cancel()
        let scope = intent.ownerScope
        pushRetryTask = Task { [weak self] in
            let maxSleep = Double(UInt64.max) / 1_000_000_000
            if delay > 0, delay.isFinite, delay <= maxSleep {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            } else {
                return // lifecycle recovery observes the persisted eligibility
            }
            guard !Task.isCancelled,
                  await self?.runtimeSession?.credential.ownerScope == scope else { return }
            _ = try? await self?.reconcilePushIntent(allowTokenRefresh: true)
        }
    }

    private func persistPushUnregister(for scope: OwnerScope) async throws {
        guard let intent = try await pushIntentStore.load(), intent.ownerScope == scope else { return }
        // This protected replacement is committed before the account boundary
        // performs any network work. It contains no bearer or identity proof.
        try await pushIntentStore.save(ProtectedPushIntent(ownerScope: scope, action: .unregister))
    }

    private func reconcilePushAfterSessionSuccess() async {
        _ = try? await reconcilePushIntent(allowTokenRefresh: true)
    }

    private func bootstrapAnonymous(pendingTransition: PendingSessionTransition? = nil) async throws {
        let pending: PendingSessionTransition
        if let pendingTransition, !pendingTransition.usesLegacyUUIDCredential {
            guard pendingTransition.isBootstrap else { throw OnloError.invalidState }
            pending = pendingTransition
        } else {
            if let pendingTransition {
                guard pendingTransition.isBootstrap else { throw OnloError.invalidState }
            }
            pending = .bootstrap(
                transitionId: UUID().uuidString,
                installationId: UUID().uuidString,
                proposedCredential: InstallationCredential.generate()
            )
            try await commitProtectedState(credential: nil, pendingTransition: pending)
        }
        let result: APIResponse<SessionResult>
        do {
            try await ensurePendingReplayAllowed(pending, userJwtProvided: false)
            result = try await sendSession(try pending.sessionOperation(), installationId: pending.installationId)
        } catch {
            try await resolveDefinitiveSessionFailure(error, credential: nil)
            if retainsSessionTransition(error) { state = .offlineReady }
            throw error
        }
        guard pending.accepts(result.result), result.result.identityClass == .anonymous else { throw OnloError.invalidResponse }
        let scope = OwnerScope(kind: .anonymous)
        try await ownerStore.prepare(scope: scope)
        let credential = StoredSessionCredential(
            installationId: result.result.installationId,
            generation: result.result.generation,
            proposedCredential: result.result.proposedCredential,
            identityClass: .anonymous,
            ownerScope: scope,
            logoutPending: false
        )
        try await commitProtectedState(credential: credential, pendingTransition: nil)
        runtimeSession = RuntimeSession(sessionId: result.result.sessionId, chatToken: result.result.chatToken, credential: credential)
        configAuthority = UUID()
        state = .anonymousReady
        await refreshConfigurationAfterSessionSuccess()
        startDurableDispatchIfNeeded()
        startForegroundStreamIfAvailable()
        await reconcilePushAfterSessionSuccess()
    }

    private func registerSend(_ task: Task<Void, Never>, id: UUID, scope: OwnerScope) {
        activeSendTasks[scope, default: [:]][id] = task
    }

    private func finishSend(_ id: UUID, scope: OwnerScope) {
        activeSendTasks[scope]?[id] = nil
        if activeSendTasks[scope]?.isEmpty == true { activeSendTasks[scope] = nil }
    }

    private func isSendActive(_ id: UUID, scope: OwnerScope) -> Bool {
        activeSendTasks[scope]?[id] != nil
    }

    private func cancelActiveSends(for scope: OwnerScope) {
        cancelForegroundStream(for: scope)
        let tasks: [Task<Void, Never>]
        if let pending = activeSendTasks.removeValue(forKey: scope) {
            tasks = Array(pending.values)
        } else {
            tasks = []
        }
        tasks.forEach { $0.cancel() }
        retryWakeTasks.removeValue(forKey: scope)?.cancel()
        activeDispatchIDs[scope] = nil
        if let observers = sendObservers.removeValue(forKey: scope) {
            observers.values.forEach { $0.finish() }
        }
    }

    private func registerObserver(_ continuation: AsyncThrowingStream<ChatEvent, Error>.Continuation, for entry: OutboxEntry) {
        sendObservers[entry.ownerScope, default: [:]][entry.clientMessageId] = continuation
    }

    private func removeObserver(for entry: OutboxEntry) {
        sendObservers[entry.ownerScope]?[entry.clientMessageId] = nil
        if sendObservers[entry.ownerScope]?.isEmpty == true { sendObservers[entry.ownerScope] = nil }
    }

    private func yield(_ event: ChatEvent, for entry: OutboxEntry) {
        sendObservers[entry.ownerScope]?[entry.clientMessageId]?.yield(event)
    }

    private func finishObserver(for entry: OutboxEntry, error: Error? = nil) {
        guard let continuation = sendObservers[entry.ownerScope]?[entry.clientMessageId] else { return }
        if let error { continuation.finish(throwing: error) } else { continuation.finish() }
        removeObserver(for: entry)
    }

    /// The only network path for durable text rows. It is deliberately owner- and
    /// session-authority-bound: one unresolved row owns the FIFO slot, while an
    /// accepted row releases it even if its UI observer continues receiving text.
    private func startDurableDispatchIfNeeded() {
        guard let session = runtimeSession,
              state == .anonymousReady || state == .identifiedReady,
              activeDispatchIDs[session.credential.ownerScope] == nil,
              transport is any OnloChatSSETransport,
              requestFactory != nil else { return }
        let dispatchID = UUID()
        let scope = session.credential.ownerScope
        let authority = configAuthority
        activeDispatchIDs[scope] = dispatchID
        // Dispatch must make forward progress independently of the caller that
        // just queued the row. A task inheriting this actor's executor can be
        // delayed behind that caller, leaving a durable row queued with no
        // network attempt.
        let task = Task.detached { [weak self] in
            guard let self else { return }
            await self.runDurableDispatch(dispatchID: dispatchID, scope: scope, authority: authority)
        }
        registerSend(task, id: dispatchID, scope: scope)
    }

    private func releaseDurableDispatch(_ dispatchID: UUID, scope: OwnerScope) {
        guard activeDispatchIDs[scope] == dispatchID else { return }
        activeDispatchIDs[scope] = nil
    }

    private func runDurableDispatch(dispatchID: UUID, scope: OwnerScope, authority: UUID) async {
        defer {
            releaseDurableDispatch(dispatchID, scope: scope)
            finishSend(dispatchID, scope: scope)
        }
        do {
            guard configAuthority == authority,
                  let session = runtimeSession,
                  session.credential.ownerScope == scope,
                  let requestFactory,
                  let streamTransport = transport as? any OnloChatSSETransport,
                  let entry = try await nextDurableTextDispatch() else { return }
            let request = try requestFactory.chat(
                ChatRequest(sessionId: session.sessionId, clientMessageId: entry.clientMessageId.uuidString, message: entry.message, attachments: entry.attachments.map(\.attachment)),
                chatToken: session.chatToken
            )
            let chatStartedAt = Date()
            var accepted = false
            var recordedFirstToken = false
            do {
                for try await event in streamTransport.chatEvents(for: request) {
                    guard !Task.isCancelled,
                          configAuthority == authority,
                          runtimeSession?.credential.ownerScope == scope else { return }
                    if case let .accepted(clientMessageId, messageId, conversationId, _, duplicate, _) = event {
                        try await markChatAccepted(clientMessageId: clientMessageId, messageId: messageId, conversationId: conversationId, entry: entry)
                        accepted = true
                        await record(operation: "chat", code: "accepted", requestId: nil, startedAt: chatStartedAt)
                        yield(event, for: entry)
                        releaseDurableDispatch(dispatchID, scope: scope)
                        startDurableDispatchIfNeeded()
                        // Receipt durability is authoritative. A duplicate's
                        // transcript fetch is convergence work and must never
                        // reclassify or resend this accepted logical message.
                        if duplicate { try? await reconcileTranscript(conversationId: conversationId, session: session) }
                    } else {
                        if case .text = event, !recordedFirstToken {
                            recordedFirstToken = true
                            await record(operation: "chat", code: "first_token", requestId: nil, startedAt: chatStartedAt)
                        }
                        try await handleChatEvent(event, entry: entry, session: session)
                        yield(event, for: entry)
                        if case .done = event {
                            await record(operation: "chat", code: "complete", requestId: nil, startedAt: chatStartedAt)
                        }
                    }
                }
                if !accepted {
                    let error = OnloError.transport(code: "network_unavailable")
                    try await recordDurableDispatchFailure(entry, retryable: true, safeCode: error.safeCode)
                    finishObserver(for: entry, error: error)
                    await scheduleRetryWake(for: scope)
                } else {
                    finishObserver(for: entry)
                }
            } catch let error as OnloError {
                guard !Task.isCancelled, configAuthority == authority,
                      runtimeSession?.credential.ownerScope == scope else { return }
                await record(operation: "chat", code: error.safeCode, requestId: nil, startedAt: chatStartedAt)
                if !accepted {
                    let retryable = isRetryableChatFailure(error)
                    try? await recordDurableDispatchFailure(entry, retryable: retryable, safeCode: error.safeCode)
                    finishObserver(for: entry, error: error)
                    if retryable { await scheduleRetryWake(for: scope) }
                } else {
                    finishObserver(for: entry, error: error)
                }
            } catch {
                guard !Task.isCancelled, configAuthority == authority,
                      runtimeSession?.credential.ownerScope == scope else { return }
                let error = OnloError.transport(code: "network_unavailable")
                await record(operation: "chat", code: error.safeCode, requestId: nil, startedAt: chatStartedAt)
                if accepted {
                    finishObserver(for: entry, error: error)
                } else {
                    try? await recordDurableDispatchFailure(entry, retryable: true, safeCode: error.safeCode)
                    finishObserver(for: entry, error: error)
                    await scheduleRetryWake(for: scope)
                }
            }
        } catch { }
    }

    private func scheduleRetryWake(for scope: OwnerScope) async {
        retryWakeTasks.removeValue(forKey: scope)?.cancel()
        guard let entries = try? await ownerStore.outboxEntries(for: scope),
              let nextAttemptAt = entries.first(where: { $0.state == .failedRetryable })?.nextAttemptAt else { return }
        let delay = max(0, nextAttemptAt.timeIntervalSince(now()))
        retryWakeTasks[scope] = Task {
            if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            guard !Task.isCancelled else { return }
            self.wakeDurableDispatch(scope: scope)
        }
    }

    private func wakeDurableDispatch(scope: OwnerScope) {
        retryWakeTasks[scope] = nil
        guard runtimeSession?.credential.ownerScope == scope else { return }
        startDurableDispatchIfNeeded()
    }

    /// Foreground SSE carries refetch hints only. It never mutates transcripts
    /// from stream payloads and every event is re-authorized after suspension.
    private func startForegroundStreamIfAvailable() {
        guard foregroundStreamTask == nil,
              let session = runtimeSession,
              state == .anonymousReady || state == .identifiedReady,
              let requestFactory,
              let streamTransport = transport as? any OnloForegroundSSETransport else { return }
        let authority = configAuthority
        let scope = session.credential.ownerScope
        let streamID = UUID()
        do {
            let request = try requestFactory.stream(chatToken: session.chatToken)
            foregroundStreamScope = scope
            foregroundStreamID = streamID
            foregroundStreamTask = Task.detached { [weak self] in
                guard let self else { return }
                await self.runForegroundStream(
                    streamID: streamID,
                    authority: authority,
                    scope: scope,
                    session: session,
                    request: request,
                    transport: streamTransport
                )
            }
        } catch { }
    }

    private func runForegroundStream(
        streamID: UUID,
        authority: UUID,
        scope: OwnerScope,
        session: RuntimeSession,
        request: URLRequest,
        transport: any OnloForegroundSSETransport
    ) async {
        defer { finishForegroundStream(streamID, authority: authority) }
        do {
            for try await event in transport.streamEvents(for: request) {
                guard !Task.isCancelled,
                      configAuthority == authority,
                      runtimeSession?.credential.ownerScope == scope else { return }
                switch event {
                case .ready:
                    continue
                case .configChanged:
                    try? await refreshConfiguration()
                    guard configAuthority == authority,
                          runtimeSession?.credential.ownerScope == scope else { return }
                case let .inboxConversation(conversationId), let .inboxMessage(conversationId):
                    try? await reconcileTranscript(conversationId: conversationId, session: session)
                    guard configAuthority == authority,
                          runtimeSession?.credential.ownerScope == scope else { return }
                    _ = try? await authorisedInbox(for: session)
                    guard configAuthority == authority,
                          runtimeSession?.credential.ownerScope == scope else { return }
                }
            }
        } catch { }
    }

    private func finishForegroundStream(_ streamID: UUID, authority: UUID) {
        guard foregroundStreamID == streamID else { return }
        foregroundStreamTask = nil
        foregroundStreamScope = nil
        foregroundStreamID = nil
        // An authority rotation (for example config's bounded token refresh)
        // deliberately replaces the bearer stream. Do not reconnect after an
        // ordinary server close, which has no authority change.
        if configAuthority != authority,
           state == .anonymousReady || state == .identifiedReady {
            startForegroundStreamIfAvailable()
        }
    }

    private func cancelForegroundStream(for scope: OwnerScope) {
        guard foregroundStreamScope == scope else { return }
        foregroundStreamTask?.cancel()
        foregroundStreamTask = nil
        foregroundStreamScope = nil
        foregroundStreamID = nil
    }

    private func isRetryableChatFailure(_ error: OnloError) -> Bool {
        guard case let .transport(code) = error else { return false }
        return code == "network_unavailable" || code == "chat_retryable"
    }

    private func markChatAccepted(clientMessageId: String, messageId: String, conversationId: String, entry: OutboxEntry) async throws {
        guard clientMessageId == entry.clientMessageId.uuidString else { throw OnloError.invalidResponse }
        let accepted = OutboxEntry(
                clientMessageId: entry.clientMessageId,
                ownerScope: entry.ownerScope,
                conversationId: conversationId,
                message: entry.message,
                attachments: entry.attachments,
                createdAt: entry.createdAt,
                orderingKey: entry.orderingKey,
                state: .accepted,
                attemptCount: entry.attemptCount,
                nextAttemptAt: nil,
                lastErrorCode: nil,
                serverMessageId: messageId,
                aiRunId: entry.aiRunId
            )
        try await ownerStore.update(accepted)
    }

    private func handleChatEvent(_ event: ChatEvent, entry: OutboxEntry, session: RuntimeSession) async throws {
        switch event {
        case .accepted:
            throw OnloError.invalidResponse
        case .text:
            return
        case .done(let conversationId, let duplicate, _, _, _):
            if duplicate == true { try await reconcileTranscript(conversationId: conversationId, session: session) }
        case .error(_, let retryable):
            guard retryable else { throw OnloError.invalidResponse }
            throw OnloError.transport(code: "chat_retryable")
        }
    }

    private func reconcileTranscript(conversationId: String, session: RuntimeSession) async throws {
        guard let requestFactory else { throw OnloError.notInitialized }
        let request = try requestFactory.transcript(conversationId: conversationId, query: .latest(limit: 100), chatToken: session.chatToken)
        let response = try await transport.execute(request)
        let transcript = try OnloResponseDecoder.widget(ConversationTranscriptResult.self, from: response)
        guard isAuthorisedTranscript(transcript, conversationId: conversationId, session: session) else {
            throw OnloError.invalidResponse
        }
        guard let transcriptStore = ownerStore as? any TranscriptPersisting else { throw OnloError.persistenceUnavailable }
        try await transcriptStore.replaceTranscript(transcript, for: session.credential.ownerScope)
    }

    /// The server authorises the requested conversation against the active
    /// bearer. A conversation's `sessionId` is historical metadata and may
    /// legitimately differ after the same verified owner starts a new session.
    /// Re-check the captured runtime authority to prevent a response crossing a
    /// logout/account switch before any durable write or UI route.
    private func isAuthorisedTranscript(
        _ transcript: ConversationTranscriptResult,
        conversationId: String,
        session: RuntimeSession
    ) -> Bool {
        transcript.conversation.id == conversationId &&
            !transcript.conversation.sessionId.isEmpty &&
            runtimeSession?.sessionId == session.sessionId &&
            runtimeSession?.credential.ownerScope == session.credential.ownerScope
    }

    private func resume(_ stored: StoredSessionCredential, pendingTransition: PendingSessionTransition? = nil) async throws {
        try await ownerStore.prepare(scope: stored.ownerScope)
        let pending: PendingSessionTransition
        if let pendingTransition {
            guard pendingTransition.matchesResume(stored) else { throw OnloError.invalidState }
            pending = pendingTransition
        } else {
            pending = .resume(transitionId: UUID().uuidString, installationId: stored.installationId, expectedGeneration: stored.generation, presentedCredential: stored.proposedCredential, proposedCredential: InstallationCredential.generate())
            try await commitProtectedState(credential: stored, pendingTransition: pending)
        }
        do {
            try await ensurePendingReplayAllowed(pending, userJwtProvided: false)
            let result = try await sendSession(
                try pending.sessionOperation(), installationId: pending.installationId
            )
            guard pending.accepts(result.result) else { throw OnloError.invalidResponse }
            try await applyResumedSession(result.result, previous: stored)
        } catch let error as OnloError {
            if case .transport = error {
                state = .offlineReady
                return
            }
            try await resolveDefinitiveSessionFailure(error, credential: stored)
            if retainsSessionTransition(error) { state = .offlineReady }
            if case .remote(let apiError) = error, apiError.code == .sessionExpired || apiError.code == .sessionRevoked {
                state = .reauthRequired
                return
            }
            throw error
        }
    }

    /// Recovery-only resume for a scope already marked `logoutPending`. Its
    /// result is kept in memory solely to unlink APNs and create the logout
    /// transition; it never calls `applyResumedSession` or clears the boundary.
    private func resumeForLogoutUnlink(_ stored: StoredSessionCredential) async throws -> SessionResult {
        let protected = try await credentialStore.loadState()
        let pending: PendingSessionTransition
        if let existing = protected.pendingTransition {
            guard existing.matchesResume(stored) else { throw OnloError.invalidState }
            pending = existing
        } else {
            pending = .resume(transitionId: UUID().uuidString, installationId: stored.installationId, expectedGeneration: stored.generation, presentedCredential: stored.proposedCredential, proposedCredential: InstallationCredential.generate())
            // Persist exact replay identity before the request. The account
            // remains logoutPending throughout this acquisition.
            try await commitProtectedState(credential: stored, pendingTransition: pending)
        }
        let result = try await sendSession(try pending.sessionOperation(), installationId: stored.installationId)
        guard result.result.installationId == stored.installationId,
              result.result.identityClass == stored.identityClass,
              pending.accepts(result.result) else {
            throw OnloError.invalidResponse
        }
        let rotated = StoredSessionCredential(installationId: result.result.installationId, generation: result.result.generation, proposedCredential: result.result.proposedCredential, identityClass: result.result.identityClass, ownerScope: stored.ownerScope, logoutPending: true)
        try await commitProtectedState(credential: rotated, pendingTransition: nil)
        return result.result
    }

    private func applyResumedSession(_ result: SessionResult, previous: StoredSessionCredential) async throws {
        let scope: OwnerScope
        if previous.identityClass == result.identityClass {
            scope = previous.ownerScope
        } else {
            // A server-side identity transition cannot expose the old partition locally.
            cancelActiveSends(for: previous.ownerScope)
            await invalidateMessengerPresentations()
            try await ownerStore.beginLogout(for: previous.ownerScope)
            try await ownerStore.finishLogout(for: previous.ownerScope)
            scope = OwnerScope(kind: result.identityClass == .anonymous ? .anonymous : .identified)
            try await ownerStore.prepare(scope: scope)
        }
        // A resumed session may rotate the bearer while retaining the same
        // owner. Release its old stream before publishing the replacement so
        // foreground recovery cannot remain attached to stale authority.
        if runtimeSession?.credential.ownerScope == scope {
            cancelForegroundStream(for: scope)
        }
        let credential = StoredSessionCredential(
            installationId: result.installationId,
            generation: result.generation,
            proposedCredential: result.proposedCredential,
            identityClass: result.identityClass,
            ownerScope: scope,
            logoutPending: false
        )
        try await commitProtectedState(credential: credential, pendingTransition: nil)
        runtimeSession = RuntimeSession(sessionId: result.sessionId, chatToken: result.chatToken, credential: credential)
        configAuthority = UUID()
        state = result.identityClass == .anonymous ? .anonymousReady : .identifiedReady
        await refreshConfigurationAfterSessionSuccess()
        startDurableDispatchIfNeeded()
        startForegroundStreamIfAvailable()
        await reconcilePushAfterSessionSuccess()
    }

    private func pendingIdentify(for credential: StoredSessionCredential) async throws -> PendingSessionTransition {
        if let existing = try await credentialStore.loadState().pendingTransition {
            guard existing.isIdentify else { throw OnloError.invalidState }
            return existing
        }
        let pending = PendingSessionTransition.identify(
            transitionId: UUID().uuidString,
            installationId: credential.installationId,
            expectedGeneration: credential.generation,
            presentedCredential: credential.proposedCredential,
            proposedCredential: InstallationCredential.generate()
        )
        try await commitProtectedState(credential: credential, pendingTransition: pending)
        return pending
    }

    private func replayPendingIdentify(
        _ pending: PendingSessionTransition,
        previous: StoredSessionCredential,
        userJwt: String
    ) async throws -> SDKState {
        guard case let .identify(_, installationId, generation, presentedCredential, _) = pending,
              installationId == previous.installationId,
              generation == previous.generation,
              presentedCredential == previous.proposedCredential else {
            throw OnloError.invalidState
        }
        state = .identifying
        do {
            try await ensurePendingReplayAllowed(pending, userJwtProvided: true)
            let result = try await sendSession(try pending.sessionOperation(userJwt: userJwt), installationId: installationId)
            guard pending.accepts(result.result), result.result.identityClass == .identified else { throw OnloError.invalidResponse }
            cancelActiveSends(for: previous.ownerScope)
            await invalidateMessengerPresentations()
            try await ownerStore.beginLogout(for: previous.ownerScope)
            try await ownerStore.finishLogout(for: previous.ownerScope)
            let scope = OwnerScope(kind: .identified)
            try await ownerStore.prepare(scope: scope)
            let credential = StoredSessionCredential(installationId: result.result.installationId, generation: result.result.generation, proposedCredential: result.result.proposedCredential, identityClass: .identified, ownerScope: scope)
            try await commitProtectedState(credential: credential, pendingTransition: nil)
            runtimeSession = RuntimeSession(sessionId: result.result.sessionId, chatToken: result.result.chatToken, credential: credential)
            configAuthority = UUID()
            state = .identifiedReady
            await refreshConfigurationAfterSessionSuccess()
            startDurableDispatchIfNeeded()
            startForegroundStreamIfAvailable()
            await reconcilePushAfterSessionSuccess()
            await registerPendingAPNsAfterIdentify()
            return state
        } catch {
            try await resolveDefinitiveSessionFailure(error, credential: previous)
            state = .reauthRequired
            throw error
        }
    }

    private func continuePendingLogout(_ stored: StoredSessionCredential, pendingTransition: PendingSessionTransition?) async throws {
        if let pendingTransition, pendingTransition.matchesResume(stored) {
            let resumed = try await resumeForLogoutUnlink(stored)
            if let intent = try await pushIntentStore.load(), intent.requiresFreshBearer {
                try await pushIntentStore.save(copiedPushIntent(intent, retryDirective: nil, requiresFreshBearer: false))
            }
            let refreshed = StoredSessionCredential(installationId: resumed.installationId, generation: resumed.generation, proposedCredential: resumed.proposedCredential, identityClass: resumed.identityClass, ownerScope: stored.ownerScope, logoutPending: true)
            _ = try await logout(refreshed, chatToken: resumed.chatToken, sessionId: resumed.sessionId)
            return
        }
        if let pendingTransition, !pendingTransition.matchesLogout(stored) {
            throw OnloError.invalidState
        }
        cancelActiveSends(for: stored.ownerScope)
        await invalidateMessengerPresentations()
        try await ownerStore.beginLogout(for: stored.ownerScope)
        guard let pendingTransition else {
            guard let initialIntent = try await pushIntentStore.load(), initialIntent.ownerScope == stored.ownerScope else {
                _ = try await logout(stored, chatToken: nil, sessionId: nil)
                return
            }
            if initialIntent.action == .register || initialIntent.isRegistered {
                try await persistPushUnregister(for: stored.ownerScope)
            }
            guard let intent = try await pushIntentStore.load(), intent.ownerScope == stored.ownerScope else { return }
            // Never spend a resume before a persisted server backoff window or
            // on a prerequisite this build cannot satisfy.
            guard intent.automaticallyRetryable,
                  intent.eligibleAt.map({ now() >= $0 }) ?? true else { return }
            let resumed = try await resumeForLogoutUnlink(stored)
            if intent.requiresFreshBearer {
                // This durable marker is consumed by the single recovery
                // Resume above; the subsequent unregister cannot resume again.
                try await pushIntentStore.save(copiedPushIntent(intent, retryDirective: nil, requiresFreshBearer: false))
            }
            let refreshed = StoredSessionCredential(installationId: resumed.installationId, generation: resumed.generation, proposedCredential: resumed.proposedCredential, identityClass: resumed.identityClass, ownerScope: stored.ownerScope, logoutPending: true)
            _ = try await logout(refreshed, chatToken: resumed.chatToken, sessionId: resumed.sessionId)
            return
        }
        _ = try await logout(stored, chatToken: nil, sessionId: nil, pendingTransition: pendingTransition)
    }

    private func logout(_ credential: StoredSessionCredential, chatToken: String?, sessionId: String?, pendingTransition: PendingSessionTransition? = nil) async throws -> SDKState {
        if let pendingTransition, !pendingTransition.matchesLogout(credential) {
            throw OnloError.invalidState
        }
        // The actor cannot advance into a new account state until every
        // registered native presenter has redacted/dismissed on MainActor.
        await invalidateMessengerPresentations()
        state = .logoutPending
        cancelConfigRetry()
        pushRetryTask?.cancel(); pushRetryTask = nil
        // Once a boundary starts, no retained bearer authority may be reused.
        runtimeSession = nil
        configAuthority = UUID()
        cancelActiveSends(for: credential.ownerScope)
        try await ownerStore.beginLogout(for: credential.ownerScope)
        let pendingCredential = StoredSessionCredential(
            installationId: credential.installationId,
            generation: credential.generation,
            proposedCredential: credential.proposedCredential,
            identityClass: credential.identityClass,
            ownerScope: credential.ownerScope,
            logoutPending: true
        )
        // The account boundary must exist on disk before awaiting APNs unlink.
        // No process-death path can observe this scope as usable again.
        try await commitProtectedState(credential: pendingCredential, pendingTransition: pendingTransition)
        let pending: PendingSessionTransition
        if let pendingTransition {
            pending = pendingTransition
        } else {
            try await persistPushUnregister(for: credential.ownerScope)
            if let intent = try await pushIntentStore.load(), intent.ownerScope == credential.ownerScope {
                guard let chatToken, let sessionId else { return .logoutPending }
                let oldSession = RuntimeSession(sessionId: sessionId, chatToken: chatToken, credential: pendingCredential)
                let pushState = try await reconcileBlockedOwnerPushIntent(oldSession)
                guard pushState == .registered else { return .logoutPending }
            }
            pending = .logout(transitionId: UUID().uuidString, installationId: credential.installationId, expectedGeneration: credential.generation, presentedCredential: credential.proposedCredential, proposedCredential: InstallationCredential.generate())
            try await commitProtectedState(credential: pendingCredential, pendingTransition: pending)
        }

        let result: APIResponse<SessionResult>
        do {
            try await ensurePendingReplayAllowed(pending, userJwtProvided: false)
            result = try await sendSession(try pending.sessionOperation(), installationId: pending.installationId)
        } catch {
            try await resolveDefinitiveSessionFailure(error, credential: pendingCredential)
            throw error
        }

        guard pending.accepts(result.result), result.result.identityClass == .anonymous else { throw OnloError.invalidResponse }
        try await ownerStore.finishLogout(for: credential.ownerScope)
        let anonymousScope = OwnerScope(kind: .anonymous)
        try await ownerStore.prepare(scope: anonymousScope)
        let anonymousCredential = StoredSessionCredential(
            installationId: result.result.installationId,
            generation: result.result.generation,
            proposedCredential: result.result.proposedCredential,
            identityClass: .anonymous,
            ownerScope: anonymousScope,
            logoutPending: false
        )
        try await commitProtectedState(credential: anonymousCredential, pendingTransition: nil)
        runtimeSession = RuntimeSession(
            sessionId: result.result.sessionId,
            chatToken: result.result.chatToken,
            credential: anonymousCredential
        )
        configAuthority = UUID()
        state = .anonymousReady
        await refreshConfigurationAfterSessionSuccess()
        startDurableDispatchIfNeeded()
        startForegroundStreamIfAvailable()
        await reconcilePushAfterSessionSuccess()
        return state
    }

    /// Fetches configuration only with the in-memory bearer. The value is
    /// committed to one protected record after strict decoding succeeds, so a
    /// malformed response can never replace last-known-good state.
    private func refreshConfiguration(allowTokenRefresh: Bool = true) async throws {
        guard let session = runtimeSession, let requestFactory else { throw OnloError.requiresNetwork }
        let authority = configAuthority
        let persisted = try await configStore.loadConfigState()
        guard hasConfigurationAuthority(authority, session: session) else { throw OnloError.invalidState }
        if case let .afterBackoff(eligibleAt, _) = persisted.retry, now() < eligibleAt {
            throw OnloError.requiresNetwork
        }
        let request = try requestFactory.config(chatToken: session.chatToken, etag: persisted.etag)
        let startedAt = Date()
        do {
            let response = try await transport.execute(request)
            guard hasConfigurationAuthority(authority, session: session) else { throw OnloError.invalidState }
            if response.statusCode == 304 {
                // The contract requires an exactly empty 304 response body.
                guard response.body.isEmpty, persisted.config != nil, persisted.etag?.isEmpty == false else { throw OnloError.invalidResponse }
                let returnedETag = Self.header("etag", in: response.headers)
                guard returnedETag == nil || returnedETag == persisted.etag else { throw OnloError.invalidResponse }
                let etag = persisted.etag
                try await configStore.saveConfigState(ProtectedMobileConfigState(config: persisted.config, etag: etag, retry: nil))
                await record(operation: "config", code: "not_modified", requestId: nil, startedAt: startedAt)
                return
            }
            let envelope = try OnloResponseDecoder.envelope(MobileConfig.self, from: response)
            guard let etag = Self.header("etag", in: response.headers), !etag.isEmpty else { throw OnloError.invalidResponse }
            try await configStore.saveConfigState(ProtectedMobileConfigState(config: envelope.result, etag: etag, retry: nil))
            configRetryTask?.cancel(); configRetryTask = nil
            await record(operation: "config", code: "ok", requestId: envelope.requestId, startedAt: startedAt)
        } catch let error as OnloError {
            await record(operation: "config", code: error.safeCode, requestId: nil, startedAt: startedAt)
            if try await resolveConfigurationFailure(error, previous: persisted, allowTokenRefresh: allowTokenRefresh) { return }
            throw error
        } catch {
            let safe = OnloError.transport(code: "network_unavailable")
            await record(operation: "config", code: safe.safeCode, requestId: nil, startedAt: startedAt)
            // Offline is not a protocol failure: retain the protected LKG.
            throw safe
        }
    }

    private func resolveConfigurationFailure(_ error: OnloError, previous: ProtectedMobileConfigState, allowTokenRefresh: Bool) async throws -> Bool {
        guard case let .remote(remote) = error else { return false }
        guard remote.code == .configUnavailable else {
            if remote.code == .incompatibleClient || remote.retry.directive == .never || remote.retry.directive == .afterFullSync { return false }
            if remote.retry.directive == .afterTokenRefresh, allowTokenRefresh {
                // Config is bearer-authorised. Refresh the Onlo session once,
                // then make exactly one conditional config retry.
                guard let credential = runtimeSession?.credential else { throw OnloError.requiresNetwork }
                suppressAutomaticConfigRefresh = true
                defer { suppressAutomaticConfigRefresh = false }
                try await resume(credential)
                try await refreshConfiguration(allowTokenRefresh: false)
                return true
            }
            return false
        }
        guard remote.retry.directive == .afterBackoff else { return false }
        let priorAttempt: Int
        if case let .afterBackoff(_, attempt) = previous.retry { priorAttempt = attempt } else { priorAttempt = 0 }
        let attempt = min(priorAttempt + 1, 3)
        let delay: TimeInterval
        if let retryAfterMs = remote.retry.retryAfterMs {
            delay = TimeInterval(retryAfterMs) / 1_000
        } else {
            let base = min(1_000.0 * pow(2, Double(attempt - 1)), 60_000.0)
            delay = (base * (1 + min(max(backoffJitter(attempt), -0.2), 0.2))) / 1_000
        }
        let eligibleAt = now().addingTimeInterval(delay)
        try await configStore.saveConfigState(ProtectedMobileConfigState(config: previous.config, etag: previous.etag, retry: .afterBackoff(eligibleAt: eligibleAt, attempt: attempt)))
        guard attempt < 3 else { return false }
        cancelConfigRetry()
        let expectedSessionId = runtimeSession?.sessionId
        let expectedScope = runtimeSession?.credential.ownerScope
        configRetryTask = Task { [weak self] in
            let ns: UInt64
            if delay.isFinite, delay > 0, delay < Double(UInt64.max) / 1_000_000_000 {
                ns = UInt64(delay * 1_000_000_000)
            } else {
                ns = UInt64.max
            }
            try? await Task.sleep(nanoseconds: ns)
            guard !Task.isCancelled else { return }
            guard await self?.hasConfigurationRetryAuthority(sessionId: expectedSessionId, scope: expectedScope) == true else { return }
            _ = try? await self?.refreshConfiguration()
        }
        return false
    }

    private static func header(_ name: String, in headers: [String: String]) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    private func cancelConfigRetry() {
        configRetryTask?.cancel()
        configRetryTask = nil
    }

    private func refreshConfigurationAfterSessionSuccess() async {
        guard !suppressAutomaticConfigRefresh else { return }
        try? await refreshConfiguration()
    }

    private func hasConfigurationRetryAuthority(sessionId: String?, scope: OwnerScope?) -> Bool {
        guard let sessionId, let scope, let active = runtimeSession else { return false }
        return active.sessionId == sessionId && active.credential.ownerScope == scope && !active.credential.logoutPending
    }

    private func hasConfigurationAuthority(_ authority: UUID, session: RuntimeSession) -> Bool {
        guard configAuthority == authority, let active = runtimeSession else { return false }
        return active.sessionId == session.sessionId && active.credential.ownerScope == session.credential.ownerScope
    }

    private func sendSession(_ operation: SessionOperation, installationId: String? = nil) async throws -> APIResponse<SessionResult> {
        guard let configuration, let requestFactory else { throw OnloError.notInitialized }
        let storedInstallationId = installationId ?? runtimeSession?.credential.installationId
        guard let effectiveInstallationId = storedInstallationId else { throw OnloError.invalidState }

        let descriptor = SDKClientDescriptor(
            installationId: effectiveInstallationId,
            sdkFamily: configuration.sdkFamily,
            sdkVersion: configuration.sdkVersion,
            appVersion: configuration.appVersion,
            appBuild: configuration.appBuild,
            capabilities: configuration.capabilities
        )
        let request = try requestFactory.session(
            SessionRequest(
                sdkKey: configuration.sdkKey,
                appIdentifier: configuration.appIdentifier,
                client: descriptor,
                operation: operation
            )
        )
        let startedAt = Date()
        do {
            let response = try await transport.execute(request)
            let envelope = try OnloResponseDecoder.envelope(SessionResult.self, from: response)
            await record(operation: "session", code: "ok", requestId: envelope.requestId, startedAt: startedAt)
            return envelope
        } catch let error as OnloError {
            await record(operation: "session", code: error.safeCode, requestId: nil, startedAt: startedAt)
            throw error
        } catch {
            await record(operation: "session", code: "network_unavailable", requestId: nil, startedAt: startedAt)
            throw OnloError.transport(code: "network_unavailable")
        }
    }

    private func commitProtectedState(
        credential: StoredSessionCredential?,
        pendingTransition: PendingSessionTransition?,
        retryGate: SessionRetryGate? = nil
    ) async throws {
        try await credentialStore.saveState(
            ProtectedSessionState(credential: credential, pendingTransition: pendingTransition, retryGate: retryGate)
        )
    }

    /// A decoded `never` response is terminal. `after_full_sync` cannot apply to
    /// a session transition, so it is terminal for this operation too. The other
    /// directives retain the exact pending transition for their prerequisite.
    private func resolveDefinitiveSessionFailure(
        _ error: Error,
        credential: StoredSessionCredential?
    ) async throws {
        guard let onloError = error as? OnloError,
              case .remote(let remote) = onloError else { return }
        switch remote.retry.directive {
        case .never, .afterFullSync:
            try await commitProtectedState(credential: credential, pendingTransition: nil)
        case .afterTokenRefresh:
            try await retainRetryGate(.afterTokenRefresh, credential: credential)
        case .afterAttestation:
            try await retainRetryGate(.afterAttestation, credential: credential)
        case .afterBackoff:
            let state = try await credentialStore.loadState()
            let previousAttempt: Int
            if case let .afterBackoff(_, attempt) = state.retryGate { previousAttempt = attempt } else { previousAttempt = 0 }
            let attempt = previousAttempt + 1
            let delay: TimeInterval
            if let retryAfterMs = remote.retry.retryAfterMs {
                // Supplied server delay is authoritative. `Int` is already
                // finite; converting to TimeInterval cannot overflow here.
                delay = TimeInterval(max(0, retryAfterMs)) / 1_000
            } else {
                let exponent = min(attempt - 1, 6)
                let baseMs = min(1_000.0 * pow(2, Double(exponent)), 60_000.0)
                let jitter = min(max(backoffJitter(attempt), -0.2), 0.2)
                delay = (baseMs * (1 + jitter)) / 1_000
            }
            try await retainRetryGate(.afterBackoff(eligibleAt: now().addingTimeInterval(delay), fallbackAttempt: attempt), credential: credential)
        }
    }

    private func retainsSessionTransition(_ error: Error) -> Bool {
        guard let onloError = error as? OnloError, case .remote(let remote) = onloError else { return false }
        switch remote.retry.directive {
        case .afterTokenRefresh, .afterAttestation, .afterBackoff: return true
        case .never, .afterFullSync: return false
        }
    }

    private func retainRetryGate(_ gate: SessionRetryGate, credential: StoredSessionCredential?) async throws {
        let state = try await credentialStore.loadState()
        try await commitProtectedState(credential: credential ?? state.credential, pendingTransition: state.pendingTransition, retryGate: gate)
    }

    private func ensurePendingReplayAllowed(_ pending: PendingSessionTransition, userJwtProvided: Bool) async throws {
        let state = try await credentialStore.loadState()
        guard state.pendingTransition == pending else { throw OnloError.invalidState }
        switch state.retryGate {
        case nil: return
        case .afterBackoff(let eligibleAt, _):
            guard now() >= eligibleAt else { throw OnloError.requiresNetwork }
            try await commitProtectedState(credential: state.credential, pendingTransition: pending, retryGate: nil)
        case .afterTokenRefresh:
            guard pending.isIdentify, userJwtProvided else { throw OnloError.invalidState }
            try await commitProtectedState(credential: state.credential, pendingTransition: pending, retryGate: nil)
        case .afterAttestation:
            // No v1 iOS attestation implementation exists yet; never pretend a
            // proof was refreshed or replay a protected transition without one.
            throw OnloError.invalidState
        }
    }

    private func requireInitialized() throws {
        guard configuration != nil, requestFactory != nil else { throw OnloError.notInitialized }
    }

    private func isCompactJWT(_ value: String) -> Bool {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 3 && parts.allSatisfy { !$0.isEmpty && $0.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" } }
    }

    private func record(operation: String, code: String, requestId: String?, startedAt: Date) async {
        let duration = max(0, Int(Date().timeIntervalSince(startedAt) * 1_000))
        await logger.record(
            SDKLogEvent(
                operation: operation,
                code: code,
                requestId: requestId,
                sdkVersion: configuration?.sdkVersion ?? "unknown",
                durationMs: duration
            )
        )
    }
}
