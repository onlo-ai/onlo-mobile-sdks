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

struct MessengerRealtimeUpdate: Sendable {
    let conversationId: String
    let transcript: ConversationTranscriptResult?
    let conversations: [ConversationSummary]
}

enum MessengerInboxResult: Sendable, Equatable {
    case ready([ConversationSummary])
    /// Last authorised encrypted inbox index rendered while refresh is unavailable.
    case stale([ConversationSummary])

    var conversations: [ConversationSummary] {
        switch self {
        case .ready(let conversations), .stale(let conversations): conversations
        }
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
        "deep_link_routing",
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
            sdkVersion: String = OnloSDKVersion.current,
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
    private let foregroundReconnectDelay: @Sendable (Int) -> TimeInterval
    private let acceptedReconciliationDelay: @Sendable () -> TimeInterval
    private let lifecycleBindingEnabled: Bool
    private var configuration: Configuration?
    private var requestFactory: OnloRequestFactory?
    private var runtimeSession: RuntimeSession?
    /// Verified only after the server accepts the corresponding identify
    /// transition. Kept in memory for the native greeting and cleared at every
    /// account boundary; it is never written to SDK storage.
    private var identifiedFirstName: String?
    private var stateObservers: [UUID: AsyncStream<SDKState>.Continuation] = [:]
    private var frameworkStateObservers: [UUID: AsyncStream<SDKFrameworkState>.Continuation] = [:]
    private var messengerUpdateObservers: [UUID: AsyncStream<MessengerRealtimeUpdate>.Continuation] = [:]
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
    private var acceptedReconciliationRetryTasks: [OwnerScope: Task<Void, Never>] = [:]
    private var foregroundStreamTask: Task<Void, Never>?
    private var foregroundStreamScope: OwnerScope?
    private var foregroundStreamID: UUID?
    private var foregroundReconnectTask: Task<Void, Never>?
    private var foregroundReconnectScope: OwnerScope?
    private var foregroundReconnectID: UUID?
    private var foregroundReconnectAttempt = 0
    private var configRetryTask: Task<Void, Never>?
    private var configRetryID: UUID?
    private var suppressAutomaticConfigRefresh = false
    private var configAuthority = UUID()
    private var configurationValidationAuthority: UUID?
    private struct MessengerInboxCache: Sendable {
        let authority: UUID
        let ownerScope: OwnerScope
        let conversations: [ConversationSummary]
    }
    private struct HelpCenterCache: Sendable {
        let authority: UUID
        let ownerScope: OwnerScope
        let topics: [HelpCenterTopic]
    }
    private var messengerInboxCache: MessengerInboxCache?
    private var conversationObservationGeneration: UInt64 = 0
    private var helpCenterCache: HelpCenterCache?
    /// A persisted transcript is reusable online only after the current
    /// in-memory bearer authority has authorised it. Owner-scoped storage
    /// protects account boundaries; this map prevents a prior session's cache
    /// from bypassing the first authorization fetch of a resumed session.
    private var transcriptValidationAuthorities: [String: UUID] = [:]
    private struct TranscriptOperationKey: Hashable {
        let ownerScope: OwnerScope
        let conversationId: String
    }
    private var activeTranscriptOperations: Set<TranscriptOperationKey> = []
    private var transcriptOperationWaiters: [TranscriptOperationKey: [CheckedContinuation<Void, Never>]] = [:]
    private var pushRetryTask: Task<Void, Never>?
    private var pushReconciliationID: UUID?
    private var pushReconciliationWakeRequested = false
    private var pushRegistrationRevision: UInt64 = 0
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

    private func persistenceAuthority(
        for session: RuntimeSession,
        bearerContext: UUID
    ) -> PersistenceAuthority {
        PersistenceAuthority(
            ownerScope: session.credential.ownerScope,
            sessionGeneration: session.credential.generation,
            sessionId: session.sessionId,
            bearerContext: bearerContext
        )
    }

    private func activatePersistenceAuthority(for session: RuntimeSession) async throws {
        guard let store = ownerStore as? any AuthorityFencedPersisting else {
            throw OnloError.persistenceUnavailable
        }
        let authority = persistenceAuthority(for: session, bearerContext: configAuthority)
        await store.activateAuthority(authority)
        if let pushStore = pushIntentStore as? any AuthorityFencedPushIntentStoring {
            await pushStore.activateAuthority(authority)
        }
        if let fencedConfigStore = configStore as? any AuthorityFencedConfigStoring {
            await fencedConfigStore.activateAuthority(authority)
        }
    }

    private func revokePersistenceAuthority(for scope: OwnerScope) async {
        guard let store = ownerStore as? any AuthorityFencedPersisting else { return }
        await store.revokeAuthority(for: scope)
        if let pushStore = pushIntentStore as? any AuthorityFencedPushIntentStoring {
            await pushStore.revokeAuthority(for: scope)
        }
        if let fencedConfigStore = configStore as? any AuthorityFencedConfigStoring {
            await fencedConfigStore.revokeAuthority(for: scope)
        }
    }

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
        self.foregroundReconnectDelay = { attempt in
            min(pow(2, Double(max(attempt - 1, 0))), 60)
        }
        self.acceptedReconciliationDelay = { 5 }
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
        foregroundReconnectDelay: @escaping @Sendable (Int) -> TimeInterval = {
            min(pow(2, Double(max($0 - 1, 0))), 60)
        },
        acceptedReconciliationDelay: @escaping @Sendable () -> TimeInterval = { 5 },
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
        self.foregroundReconnectDelay = foregroundReconnectDelay
        self.acceptedReconciliationDelay = acceptedReconciliationDelay
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
        if state == .reauthRequired {
            let protectedState = try await credentialStore.loadState()
            if let stored = protectedState.credential,
               !stored.logoutPending,
               !(protectedState.pendingTransition?.isIdentify ?? false) {
                try await replaceExpiredInstallation(with: stored, pendingTransition: protectedState.pendingTransition)
                return state
            }
        }
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
        let pendingFirstName = Self.firstNameClaim(from: userJwt)
        try requireInitialized()
        // Hosts may repeat their login integration after view/scene recovery.
        // The current identified owner remains authoritative until the host
        // explicitly calls logout for an account switch.
        if state == .identifiedReady,
           runtimeSession?.credential.identityClass == .identified {
            return state
        }
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
        if let scope = runtimeSession?.credential.ownerScope {
            await revokePersistenceAuthority(for: scope)
            cancelForegroundStream(for: scope)
        }
        let protectedState = try await credentialStore.loadState()
        if state == .reauthRequired,
           let stored = protectedState.credential,
           let pending = protectedState.pendingTransition,
           pending.isIdentify,
           stored.identityClass == .anonymous {
            let replayed = try await replayPendingIdentify(pending, previous: stored, userJwt: userJwt)
            if replayed == .identifiedReady { identifiedFirstName = pendingFirstName }
            return replayed
        }
        if state == .reauthRequired,
           let stored = protectedState.credential,
           !stored.logoutPending,
           !(protectedState.pendingTransition?.isIdentify ?? false) {
            try await replaceExpiredInstallation(
                with: stored,
                pendingTransition: protectedState.pendingTransition
            )
        }
        guard runtimeSession != nil else {
            throw state == .offlineReady ? OnloError.requiresNetwork : OnloError.invalidState
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
        } catch let error as OnloError {
            try await resolveDefinitiveSessionFailure(error, credential: anonymousSession.credential)
            if case let .remote(remote) = error, remote.code == .identityDisabled {
                state = .anonymousReady
                configAuthority = UUID()
                try await activatePersistenceAuthority(for: anonymousSession)
                await refreshConfigurationAfterSessionSuccess()
                startDurableDispatchIfNeeded()
                startForegroundStreamIfAvailable()
                return state
            }
            state = .anonymousReady
            try await activatePersistenceAuthority(for: anonymousSession)
            startDurableDispatchIfNeeded()
            startForegroundStreamIfAvailable()
            throw error
        } catch {
            state = .anonymousReady
            try await activatePersistenceAuthority(for: anonymousSession)
            startDurableDispatchIfNeeded()
            startForegroundStreamIfAvailable()
            throw error
        }

        guard pending.accepts(result.result), result.result.identityClass == .identified else {
            state = .anonymousReady
            try await activatePersistenceAuthority(for: anonymousSession)
            startDurableDispatchIfNeeded()
            startForegroundStreamIfAvailable()
            throw OnloError.invalidResponse
        }

        // The anonymous partition is no longer usable after the server accepts identity.
        cancelActiveSends(for: anonymousSession.credential.ownerScope)
        await revokePersistenceAuthority(for: anonymousSession.credential.ownerScope)
        await invalidateMessengerPresentations()
        try await ownerStore.beginLogout(for: anonymousSession.credential.ownerScope)
        try await ownerStore.finishLogout(for: anonymousSession.credential.ownerScope)
        try? await pushIntentStore.clear()
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
        identifiedFirstName = pendingFirstName
        configAuthority = UUID()
        try await activatePersistenceAuthority(for: runtimeSession!)
        state = .identifiedReady
        await refreshConfigurationAfterSessionSuccess()
        startDurableDispatchIfNeeded()
        startForegroundStreamIfAvailable()
        schedulePushReconciliationAfterSessionSuccess()
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

    /// Blocks the old owner locally before the server atomically ends the session
    /// and clears its push association. If network work fails, the old owner
    /// remains durably blocked in `logoutPending`.
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
        return try await logout(session.credential)
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

    func observeMessengerUpdates() -> AsyncStream<MessengerRealtimeUpdate> {
        let id = UUID()
        return AsyncStream { continuation in
            messengerUpdateObservers[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeMessengerUpdateObserver(id) }
            }
        }
    }

    private func removeMessengerUpdateObserver(_ id: UUID) {
        messengerUpdateObservers[id] = nil
    }

    private func publishMessengerUpdate(_ update: MessengerRealtimeUpdate) {
        for observer in messengerUpdateObservers.values { observer.yield(update) }
    }

    private func withSerializedTranscriptObservation<Value>(
        ownerScope: OwnerScope,
        conversationId: String,
        operation: () async throws -> Value
    ) async throws -> Value {
        let key = TranscriptOperationKey(ownerScope: ownerScope, conversationId: conversationId)
        if activeTranscriptOperations.contains(key) {
            await withCheckedContinuation { continuation in
                transcriptOperationWaiters[key, default: []].append(continuation)
            }
        } else {
            activeTranscriptOperations.insert(key)
        }
        defer { finishTranscriptObservation(key) }
        try Task.checkCancellation()
        return try await operation()
    }

    private func finishTranscriptObservation(_ key: TranscriptOperationKey) {
        guard var waiters = transcriptOperationWaiters[key], !waiters.isEmpty else {
            transcriptOperationWaiters[key] = nil
            activeTranscriptOperations.remove(key)
            return
        }
        let next = waiters.removeFirst()
        transcriptOperationWaiters[key] = waiters.isEmpty ? nil : waiters
        next.resume()
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
    /// v1 has no conversation target, so dispatchable rows remain globally
    /// ordered per owner. Terminal rows stay available for UI diagnostics but
    /// cannot permanently deadlock later customer messages.
    func nextDurableTextDispatch(
        dispatchID: UUID? = nil,
        expectedAuthority: UUID? = nil
    ) async throws -> OutboxEntry? {
        guard let session = runtimeSession, state == .anonymousReady || state == .identifiedReady else { throw OnloError.invalidState }
        let authority = configAuthority
        let scope = session.credential.ownerScope
        let sessionId = session.sessionId
        let persistence = persistenceAuthority(for: session, bearerContext: authority)
        func hasSelectionAuthority() -> Bool {
            !Task.isCancelled &&
                configAuthority == authority &&
                (dispatchID == nil || activeDispatchIDs[scope] == dispatchID) &&
                (expectedAuthority == nil || expectedAuthority == authority) &&
                (state == .anonymousReady || state == .identifiedReady) &&
                runtimeSession?.sessionId == sessionId &&
                runtimeSession?.chatToken == session.chatToken &&
                runtimeSession?.credential.generation == session.credential.generation &&
                runtimeSession?.credential.ownerScope == scope
        }

        while true {
            guard hasSelectionAuthority() else { throw OnloError.invalidState }
            guard let store = ownerStore as? any AuthorityFencedPersisting,
                  let entries = try await store.recoverEligibleEntries(
                      for: scope,
                      now: now(),
                      authority: persistence
                  ) else { throw OnloError.invalidState }
            guard hasSelectionAuthority() else { throw OnloError.invalidState }
            let all = try await ownerStore.outboxEntries(for: scope)
            guard hasSelectionAuthority() else { throw OnloError.invalidState }
            guard let head = all.first(where: {
                $0.state == .queued || $0.state == .sending || $0.state == .failedRetryable
            }) else { return nil }
            guard entries.contains(where: { $0.clientMessageId == head.clientMessageId }) else { return nil }
            var sending = head
            if sending.attachments.contains(where: { attachment in
                guard let expiresAt = attachment.receiptExpiresAt,
                      let expiry = serverDate(expiresAt) else { return true }
                return expiry <= now()
            }) {
                var refreshed: [OutboxAttachment] = []
                do {
                    for attachment in sending.attachments {
                        guard let expiresAt = attachment.receiptExpiresAt,
                              let expiry = serverDate(expiresAt) else {
                            throw OnloError.transport(code: "attachment_grant_invalid")
                        }
                        if expiry > now() {
                            refreshed.append(attachment)
                            continue
                        }
                        guard let stagedData = attachment.stagedData,
                              let mime = ImageMimeType(rawValue: attachment.attachment.type) else {
                            throw OnloError.transport(code: "attachment_staging_unavailable")
                        }
                        refreshed.append(try await uploadImage(
                            conversationId: attachment.uploadConversationId,
                            data: stagedData,
                            mimeType: mime,
                            filename: attachment.attachment.name,
                            previousGrant: attachment.attachment.grant
                        ))
                        guard hasSelectionAuthority() else { throw OnloError.invalidState }
                    }
                    sending = OutboxEntry(
                        clientMessageId: head.clientMessageId,
                        ownerScope: head.ownerScope,
                        conversationId: head.conversationId,
                        routingSessionId: head.routingSessionId,
                        message: head.message,
                        attachments: refreshed,
                        createdAt: head.createdAt,
                        orderingKey: head.orderingKey,
                        state: head.state,
                        attemptCount: head.attemptCount,
                        nextAttemptAt: head.nextAttemptAt,
                        lastErrorCode: head.lastErrorCode,
                        serverMessageId: head.serverMessageId,
                        aiRunId: head.aiRunId
                    )
                    guard try await store.update(
                        sending,
                        expectedState: head.state,
                        expectedAttemptCount: head.attemptCount,
                        authority: persistence
                    ) else { throw OnloError.invalidState }
                } catch let error as OnloError {
                    guard hasSelectionAuthority() else { throw OnloError.invalidState }
                    let retryable = error == .requiresNetwork || isRetryableChatFailure(error)
                    if retryable {
                        sending.state = .failedRetryable
                        sending.attemptCount += 1
                        let exponent = min(max(sending.attemptCount - 1, 0), 6)
                        let base = min(1_000.0 * pow(2, Double(exponent)), 60_000.0)
                        let jitter = min(max(backoffJitter(sending.attemptCount), -0.2), 0.2)
                        sending.nextAttemptAt = now().addingTimeInterval((base * (1 + jitter)) / 1_000)
                    } else {
                        sending.state = .failedTerminal
                        sending.nextAttemptAt = nil
                    }
                    sending.lastErrorCode = error.safeCode
                    guard try await store.update(
                        sending,
                        expectedState: head.state,
                        expectedAttemptCount: head.attemptCount,
                        authority: persistence
                    ) else { throw OnloError.invalidState }
                    guard hasSelectionAuthority() else { throw OnloError.invalidState }
                    finishObserver(for: sending, error: error)
                    if retryable, let dispatchID {
                        await scheduleRetryWake(
                            for: scope,
                            dispatchID: dispatchID,
                            authority: authority,
                            session: session
                        )
                        return nil
                    }
                } catch is CancellationError {
                    throw OnloError.invalidState
                } catch {
                    guard hasSelectionAuthority() else { throw OnloError.invalidState }
                    sending.state = .failedTerminal
                    sending.lastErrorCode = APIErrorCode.mediaUnavailable.rawValue
                    sending.nextAttemptAt = nil
                    guard try await store.update(
                        sending,
                        expectedState: head.state,
                        expectedAttemptCount: head.attemptCount,
                        authority: persistence
                    ) else { throw OnloError.invalidState }
                    guard hasSelectionAuthority() else { throw OnloError.invalidState }
                    finishObserver(for: sending, error: error)
                }
                continue
            }
            sending.state = .sending
            sending.attemptCount += 1
            sending.nextAttemptAt = nil
            guard try await store.update(
                      sending,
                      expectedState: head.state,
                      expectedAttemptCount: head.attemptCount,
                      authority: persistence
                  ) else { throw OnloError.invalidState }
            guard hasSelectionAuthority() else { throw OnloError.invalidState }
            return sending
        }
    }

    /// Persists bounded retry eligibility for a failed durable attempt. Only
    /// transport/chat-retryable failures may re-enter FIFO; protocol failures
    /// become terminal and therefore cannot accidentally be resent.
    func recordDurableDispatchFailure(
        _ entry: OutboxEntry,
        retryable: Bool,
        safeCode: String,
        authority: PersistenceAuthority? = nil
    ) async throws {
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
        let commitAuthority = authority ?? persistenceAuthority(
            for: session,
            bearerContext: configAuthority
        )
        guard let store = ownerStore as? any AuthorityFencedPersisting else {
            throw OnloError.persistenceUnavailable
        }
        _ = try await store.update(
            updated,
            expectedState: .sending,
            expectedAttemptCount: entry.attemptCount,
            authority: commitAuthority
        )
    }

    /// Token-free last-known-good configuration for native presentation and
    /// bridge adapters. It remains available while offline.
    public func currentConfiguration() async throws -> MobileConfig? {
        try await loadConfigurationStateRecoveringCorruptCache().config
    }

    /// Session establishment, foreground recovery, and config-change events
    /// validate configuration. Reopening Support within that active runtime
    /// uses the protected projection and session-scoped Help Center cache.
    func messengerPresentationResources() async -> (
        config: MobileConfig?,
        helpTopics: [HelpCenterTopic],
        faqContentIsCurrent: Bool,
        identifiedFirstName: String?
    ) {
        let ready = state == .anonymousReady || state == .identifiedReady
        var configIsCurrent = configurationValidationAuthority == configAuthority
        if ready, !configIsCurrent {
            do {
                try await refreshConfiguration()
                configIsCurrent = true
            } catch {
                configIsCurrent = false
            }
        }
        let config = try? await currentConfiguration()
        let helpTopics: [HelpCenterTopic]
        if ready {
            helpTopics = (try? await messengerHelpCenter()) ?? []
        } else {
            helpTopics = []
        }
        return (
            config: config,
            helpTopics: helpTopics,
            faqContentIsCurrent: ready && configIsCurrent,
            identifiedFirstName: state == .identifiedReady ? identifiedFirstName : nil
        )
    }

    /// Reuses the Widget upload route and retains staged bytes only inside the
    /// encrypted owner-scoped outbox so an expired pre-acceptance grant can be
    /// refreshed without changing the logical message ID.
    func uploadImage(
        conversationId: String?,
        data: Data,
        mimeType: ImageMimeType,
        filename: String,
        previousGrant: String? = nil
    ) async throws -> OutboxAttachment {
        guard conversationId?.isEmpty != true,
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
        let response = try await transport.execute(
            try requestFactory.widgetAttachmentUpload(
                conversationId: conversationId,
                previousGrant: previousGrant,
                fileData: data,
                filename: filename,
                mimeType: mimeType,
                chatToken: session.chatToken
            )
        )
        guard configAuthority == authority,
              runtimeSession?.sessionId == session.sessionId,
              runtimeSession?.credential.ownerScope == scope else {
            throw OnloError.invalidState
        }
        guard response.statusCode == 200 else {
            let widgetCode = (try? JSONDecoder().decode(WidgetErrorResponse.self, from: response.body))?.error
            let code: APIErrorCode = widgetCode == APIErrorCode.mediaUnavailable.rawValue
                ? .mediaUnavailable
                : .forbiddenPrincipal
            throw OnloError.remote(APIError(
                code: code,
                message: code == .mediaUnavailable ? "Image upload is disabled." : "Image upload is unauthorized.",
                retry: try APIRetry(directive: .never)
            ))
        }
        let completed = try JSONDecoder().decode(WidgetAttachmentUploadResponse.self, from: response.body)
        guard completed.success,
              completed.attachments.count == 1,
              let attachment = completed.attachments.first,
              attachment.type == mimeType.rawValue,
              attachment.name == filename,
              attachment.size == data.count,
              !attachment.id.isEmpty,
              !attachment.url.isEmpty,
              !attachment.grant.isEmpty,
              serverDate(attachment.grantExpiresAt).map({ $0 > now() }) == true else {
            throw OnloError.invalidResponse
        }
        return OutboxAttachment(
            attachment: ChatAttachment(
                id: attachment.id,
                url: attachment.url,
                type: attachment.type,
                name: attachment.name,
                size: attachment.size,
                grant: attachment.grant
            ),
            grantExpiresAt: attachment.grantExpiresAt,
            stagedData: data,
            uploadConversationId: conversationId
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
        try await messengerInboxResult().conversations
    }

    func messengerInboxResult() async throws -> MessengerInboxResult {
        try await messengerInboxResult(allowTokenRefresh: true)
    }

    private func messengerInboxResult(allowTokenRefresh: Bool) async throws -> MessengerInboxResult {
        let startedAt = Date()
        let attemptedSession = (state == .anonymousReady || state == .identifiedReady)
            ? runtimeSession
            : nil
        do {
            guard let session = attemptedSession else {
                throw state == .offlineReady ? OnloError.requiresNetwork : OnloError.invalidState
            }
            let inbox = try await authorisedInbox(for: session)
            await record(operation: "inbox", code: "ok", requestId: inbox.requestId, startedAt: startedAt)
            return .ready(inbox.conversations)
        } catch let error as OnloError {
            await record(operation: "inbox", code: error.safeCode, requestId: error.requestId, startedAt: startedAt)
            if allowTokenRefresh,
               isWidgetUnauthorized(error),
               let rejectedSession = attemptedSession,
               await refreshMessengerBearer(rejectedSession),
               state == .anonymousReady || state == .identifiedReady {
                return try await messengerInboxResult(allowTokenRefresh: false)
            }
            if let cached = try? await cachedMessengerInbox() {
                return .stale(cached)
            }
            throw error
        } catch {
            await record(operation: "inbox", code: "network_unavailable", requestId: nil, startedAt: startedAt)
            if let cached = try? await cachedMessengerInbox() {
                return .stale(cached)
            }
            throw OnloError.transport(code: "network_unavailable")
        }
    }

    private func isWidgetUnauthorized(_ error: OnloError) -> Bool {
        guard let code = error.transportCode else { return false }
        return code == "widget_http_401" || code.hasPrefix("widget_401_")
    }

    /// Performs one protected installation-credential rotation. It never asks
    /// the host for an Operator JWT and never recursively retries the inbox.
    private func refreshMessengerBearer(_ rejectedSession: RuntimeSession) async -> Bool {
        guard let active = runtimeSession,
              active.sessionId == rejectedSession.sessionId,
              active.chatToken == rejectedSession.chatToken,
              active.credential.ownerScope == rejectedSession.credential.ownerScope else {
            return runtimeSession?.credential.ownerScope == rejectedSession.credential.ownerScope &&
                (state == .anonymousReady || state == .identifiedReady)
        }
        do {
            try await resume(rejectedSession.credential)
        } catch {
            return false
        }
        guard let refreshed = runtimeSession else { return false }
        return refreshed.credential.ownerScope == rejectedSession.credential.ownerScope &&
            refreshed.chatToken != rejectedSession.chatToken &&
            (state == .anonymousReady || state == .identifiedReady)
    }

    private func cachedMessengerInbox() async throws -> [ConversationSummary]? {
        guard (state == .anonymousReady || state == .identifiedReady || state == .offlineReady),
              let session = runtimeSession,
              let store = ownerStore as? any AuthorityFencedPersisting else { return nil }
        let authority = configAuthority
        let persistence = persistenceAuthority(for: session, bearerContext: authority)
        let cached: ConversationListResult
        if let memory = messengerInboxCache,
           memory.authority == authority,
           memory.ownerScope == session.credential.ownerScope {
            cached = ConversationListResult(
                conversations: memory.conversations,
                totalUnreadCount: session.credential.identityClass == .identified ? (unreadCount ?? 0) : 0
            )
        } else if let persisted = try await store.conversationList(authority: persistence) {
            cached = persisted
        } else {
            return nil
        }
        guard configAuthority == authority,
              runtimeSession?.sessionId == session.sessionId,
              runtimeSession?.credential.ownerScope == session.credential.ownerScope,
              let conversations = validatedInboxConversations(
                cached,
                identityClass: session.credential.identityClass
              ) else { return nil }
        unreadCount = session.credential.identityClass == .identified ? cached.totalUnreadCount : nil
        messengerInboxCache = MessengerInboxCache(
            authority: authority,
            ownerScope: session.credential.ownerScope,
            conversations: conversations
        )
        return conversations
    }

    /// The list remains session-authorised. Customer unread state is exposed
    /// only for a verified identity; anonymous summaries are scrubbed.
    private func authorisedInbox(for session: RuntimeSession) async throws -> (conversations: [ConversationSummary], requestId: String?) {
        guard let requestFactory else { throw OnloError.invalidState }
        conversationObservationGeneration &+= 1
        let observationGeneration = conversationObservationGeneration
        let authority = configAuthority
        let response = try await transport.execute(try requestFactory.conversations(chatToken: session.chatToken, limit: 50))
        let inbox = try OnloResponseDecoder.widget(ConversationListResult.self, from: response)
        guard configAuthority == authority,
              runtimeSession?.sessionId == session.sessionId,
              runtimeSession?.credential.ownerScope == session.credential.ownerScope,
              let conversations = validatedInboxConversations(
                inbox,
                identityClass: session.credential.identityClass
              ) else {
            throw OnloError.invalidResponse
        }
        if observationGeneration != conversationObservationGeneration {
            guard let cached = messengerInboxCache,
                  cached.authority == authority,
                  cached.ownerScope == session.credential.ownerScope else {
                throw OnloError.invalidResponse
            }
            return (
                conversations: cached.conversations,
                requestId: Self.header("x-onlo-request-id", in: response.headers)
            )
        }
        let totalUnreadCount = session.credential.identityClass == .identified ? inbox.totalUnreadCount : 0
        let authoritative = ConversationListResult(
            conversations: conversations,
            totalUnreadCount: totalUnreadCount
        )
        if let store = ownerStore as? any AuthorityFencedPersisting {
            _ = try? await store.replaceConversationList(
                authoritative,
                authority: persistenceAuthority(for: session, bearerContext: authority)
            )
        }
        guard configAuthority == authority,
              runtimeSession?.sessionId == session.sessionId,
              runtimeSession?.credential.ownerScope == session.credential.ownerScope else {
            throw OnloError.invalidState
        }
        if observationGeneration != conversationObservationGeneration {
            guard let cached = messengerInboxCache,
                  cached.authority == authority,
                  cached.ownerScope == session.credential.ownerScope else {
                throw OnloError.invalidResponse
            }
            if let store = ownerStore as? any AuthorityFencedPersisting {
                _ = try? await store.replaceConversationList(
                    ConversationListResult(
                        conversations: cached.conversations,
                        totalUnreadCount: session.credential.identityClass == .identified
                            ? (unreadCount ?? 0)
                            : 0
                    ),
                    authority: persistenceAuthority(for: session, bearerContext: authority)
                )
            }
            return (
                conversations: cached.conversations,
                requestId: Self.header("x-onlo-request-id", in: response.headers)
            )
        }
        unreadCount = session.credential.identityClass == .identified ? totalUnreadCount : nil
        messengerInboxCache = MessengerInboxCache(
            authority: configAuthority,
            ownerScope: session.credential.ownerScope,
            conversations: conversations
        )
        return (
            conversations: conversations,
            requestId: Self.header("x-onlo-request-id", in: response.headers)
        )
    }

    private func validatedInboxConversations(
        _ inbox: ConversationListResult,
        identityClass: IdentityClass
    ) -> [ConversationSummary]? {
        var conversationIDs = Set<String>()
        guard inbox.totalUnreadCount >= 0,
              inbox.conversations.allSatisfy({ conversation in
                  !conversation.id.isEmpty &&
                      !conversation.sessionId.isEmpty &&
                      conversation.unreadCount >= 0 &&
                      conversation.unread == (conversation.unreadCount > 0) &&
                      conversation.messageCount >= 0 &&
                      conversationIDs.insert(conversation.id).inserted
              }) else { return nil }
        guard identityClass == .anonymous else { return inbox.conversations }
        return inbox.conversations.map {
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
        }
    }

    func messengerHelpCenter() async throws -> [HelpCenterTopic] {
        let startedAt = Date()
        do {
            guard state == .anonymousReady || state == .identifiedReady,
                  let session = runtimeSession,
                  let requestFactory else {
                throw state == .offlineReady ? OnloError.requiresNetwork : OnloError.invalidState
            }
            if let cached = helpCenterCache,
               cached.authority == configAuthority,
               cached.ownerScope == session.credential.ownerScope {
                await record(operation: "help_center", code: "cache_hit", requestId: nil, startedAt: startedAt)
                return cached.topics
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
            helpCenterCache = HelpCenterCache(
                authority: authority,
                ownerScope: session.credential.ownerScope,
                topics: catalog.topics
            )
            await record(
                operation: "help_center",
                code: "ok",
                requestId: Self.header("x-onlo-request-id", in: response.headers),
                startedAt: startedAt
            )
            return catalog.topics
        } catch let error as OnloError {
            await record(operation: "help_center", code: error.safeCode, requestId: error.requestId, startedAt: startedAt)
            throw error
        } catch {
            await record(operation: "help_center", code: "network_unavailable", requestId: nil, startedAt: startedAt)
            throw OnloError.transport(code: "network_unavailable")
        }
    }

    func messengerHelpCenterArticle(articleId: String) async throws -> HelpCenterArticle {
        let startedAt = Date()
        do {
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
            await record(
                operation: "help_center_article",
                code: "ok",
                requestId: Self.header("x-onlo-request-id", in: response.headers),
                startedAt: startedAt
            )
            return result.article
        } catch let error as OnloError {
            await record(operation: "help_center_article", code: error.safeCode, requestId: error.requestId, startedAt: startedAt)
            throw error
        } catch {
            await record(operation: "help_center_article", code: "network_unavailable", requestId: nil, startedAt: startedAt)
            throw OnloError.transport(code: "network_unavailable")
        }
    }

    /// Called by the native presenter only after it has committed an authorised
    /// transcript to visible UI.
    func acknowledgeRenderedConversation(
        conversationId: String,
        throughMessageId: String
    ) async throws {
        let startedAt = Date()
        do {
            guard state == .anonymousReady || state == .identifiedReady,
                  let session = runtimeSession,
                  let requestFactory else { return }
            conversationObservationGeneration &+= 1
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
                  result.unreadCount >= 0,
                  result.unread == (result.unreadCount > 0),
                  configAuthority == authority,
                  runtimeSession?.sessionId == session.sessionId else {
                throw OnloError.invalidResponse
            }
            // The acknowledgement result is a point-in-time snapshot. A newer
            // unread message may already exist, so converge the badge from the
            // authoritative inbox instead of requiring this response to be zero.
            _ = try await authorisedInbox(for: session)
            await record(
                operation: "read_acknowledgement",
                code: "ok",
                requestId: Self.header("x-onlo-request-id", in: response.headers),
                startedAt: startedAt
            )
        } catch let error as OnloError {
            await record(operation: "read_acknowledgement", code: error.safeCode, requestId: error.requestId, startedAt: startedAt)
            throw error
        } catch {
            await record(operation: "read_acknowledgement", code: "network_unavailable", requestId: nil, startedAt: startedAt)
            throw OnloError.transport(code: "network_unavailable")
        }
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
        let authority = configAuthority
        if transcriptValidationAuthorities[conversationId] == configAuthority,
           let cached = try await transcriptStore.transcript(
               conversationId: conversationId,
               for: session.credential.ownerScope
           ) {
            await record(
                operation: "transcript",
                code: "cache_hit",
                requestId: nil,
                startedAt: startedAt
            )
            return cached
        }
        return try await withSerializedTranscriptObservation(
            ownerScope: session.credential.ownerScope,
            conversationId: conversationId
        ) {
            let response = try await transport.execute(try requestFactory.transcript(conversationId: conversationId, query: .latest(limit: 100), chatToken: session.chatToken))
            let transcript = try OnloResponseDecoder.widget(ConversationTranscriptResult.self, from: response)
            guard isAuthorisedTranscript(transcript, conversationId: conversationId, session: session) else {
                throw OnloError.invalidResponse
            }
            guard let fencedStore = ownerStore as? any AuthorityFencedPersisting,
                  try await fencedStore.replaceTranscript(
                      transcript,
                      authority: persistenceAuthority(for: session, bearerContext: authority)
                  ) else { return nil }
            guard configAuthority == authority,
                  runtimeSession?.sessionId == session.sessionId,
                  runtimeSession?.credential.ownerScope == session.credential.ownerScope else {
                return nil
            }
            transcriptValidationAuthorities[conversationId] = configAuthority
            await record(
                operation: "transcript",
                code: "ok",
                requestId: Self.header("x-onlo-request-id", in: response.headers),
                startedAt: startedAt
            )
            return transcript
        }
        } catch let error as OnloError {
            await record(operation: "transcript", code: error.safeCode, requestId: error.requestId, startedAt: startedAt)
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
        schedulePushReconciliationAfterSessionSuccess()
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
        try await sendMessage(message: message, attachments: [], routingSessionId: nil)
    }

    /// Internal-only: native UI supplies only server-granted Widget attachment
    /// handles. Host apps cannot inject raw attachment URLs.
    func sendMessage(
        message: String,
        attachments: [OutboxAttachment],
        routingSessionId: String? = nil
    ) async throws -> AsyncThrowingStream<ChatEvent, Error> {
        try requireInitialized()
        guard !message.isEmpty || !attachments.isEmpty else {
            throw OnloError.invalidConfiguration
        }
        guard attachments.count <= OnloProtocol.maximumImagesPerMessage,
              attachments.allSatisfy({
                  !$0.attachment.url.isEmpty &&
                      !$0.attachment.type.isEmpty &&
                      !$0.attachment.name.isEmpty &&
                      $0.attachment.size > 0 &&
                      $0.attachment.size <= OnloProtocol.maximumImageBytes &&
                      $0.attachment.grant?.isEmpty == false &&
                      $0.stagedData?.isEmpty == false &&
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
        let entry = OutboxEntry(
            ownerScope: ownerScope,
            routingSessionId: routingSessionId,
            message: message,
            attachments: attachments,
            orderingKey: 0
        )
        var observer: AsyncThrowingStream<ChatEvent, Error>.Continuation?
        let stream = AsyncThrowingStream<ChatEvent, Error> { observer = $0 }
        guard let observer else { throw OnloError.invalidState }
        registerObserver(observer, for: entry)
        observer.onTermination = { [weak self] _ in
            Task { await self?.removeObserver(for: entry) }
        }
        let queuedAt = Date()
        do {
            _ = try await ownerStore.enqueueAssigningOrder(entry)
        } catch {
            finishObserver(for: entry, error: error)
            throw error
        }
        await record(operation: "chat", code: "queued", requestId: nil, startedAt: queuedAt)
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
        guard !token.isEmpty, token.count <= 512 else { return .requiresHostAction }
        let registration = PendingAPNsRegistration(
            token: token,
            notificationPreference: notificationPreference,
            locale: locale
        )
        pushRegistrationRevision &+= 1
        pendingAPNsRegistration = registration
        guard state == .anonymousReady || state == .identifiedReady,
              let session = runtimeSession else { return .pendingRetry }
        do {
            return try await persistAndReconcileAPNs(registration, session: session)
        } catch {
            return .requiresHostAction
        }
    }

    private func persistAndReconcileAPNs(
        _ registration: PendingAPNsRegistration,
        session: RuntimeSession
    ) async throws -> OnloPushRegistrationState {
        let authority = persistenceAuthority(for: session, bearerContext: configAuthority)
        let existing = try await pushIntentStore.load()
        // A pending intent belongs to the scope that created it. A newly
        // authenticated account must never overwrite it or inherit its token.
        if let existing, existing.ownerScope != session.credential.ownerScope {
            throw OnloError.invalidState
        }
        let value = registration.token.map { String(format: "%02x", $0) }.joined()
        if let existing,
           existing.ownerScope == session.credential.ownerScope,
           existing.action == .register,
           existing.token == value,
           existing.isRegistered {
            return .registered
        }
        let intent = ProtectedPushIntent(
            ownerScope: session.credential.ownerScope,
            action: .register,
            token: value,
            notificationPreference: registration.notificationPreference,
            locale: registration.locale
        )
        guard let pushStore = pushIntentStore as? any AuthorityFencedPushIntentStoring,
              try await pushStore.save(intent, authority: authority) else {
            throw OnloError.invalidState
        }
        return try await reconcilePushIntent()
    }

    private func registerPendingAPNsAfterSessionReady() async {
        guard let registration = pendingAPNsRegistration,
              state == .anonymousReady || state == .identifiedReady,
              let session = runtimeSession else { return }
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
        guard state == .anonymousReady || state == .identifiedReady,
              let session = runtimeSession,
              let requestFactory else { return .deferred }
        let authority = configAuthority
        let scope = session.credential.ownerScope
        do {
            let request = try requestFactory.transcript(
                conversationId: payload.conversationId,
                query: .latest(limit: 100),
                chatToken: session.chatToken
            )
            return try await withSerializedTranscriptObservation(
                ownerScope: scope,
                conversationId: payload.conversationId
            ) {
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
                guard let transcriptStore = ownerStore as? any AuthorityFencedPersisting else {
                    throw OnloError.persistenceUnavailable
                }
                guard try await transcriptStore.replaceTranscript(
                    transcript,
                    authority: persistenceAuthority(for: session, bearerContext: authority)
                ) else { return .deferred }
                guard configAuthority == authority,
                      runtimeSession?.sessionId == session.sessionId,
                      runtimeSession?.credential.ownerScope == scope else { return .deferred }
                transcriptValidationAuthorities[payload.conversationId] = authority
                return .handled(.messenger(conversationId: payload.conversationId))
            }
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
    private func reconcilePushIntent(
        expectedRegistrationRevision: UInt64? = nil
    ) async throws -> OnloPushRegistrationState {
        guard pushReconciliationID == nil else {
            pushReconciliationWakeRequested = true
            return .pendingRetry
        }
        guard let session = runtimeSession,
              state == .anonymousReady || state == .identifiedReady else {
            throw OnloError.requiresNetwork
        }
        let authority = configAuthority
        let persistence = persistenceAuthority(for: session, bearerContext: authority)
        guard let intent = try await pushIntentStore.load() else { return .registered }
        if let expectedRegistrationRevision,
           expectedRegistrationRevision != pushRegistrationRevision {
            return .pendingRetry
        }
        guard pushReconciliationID == nil else {
            pushReconciliationWakeRequested = true
            return .pendingRetry
        }
        let operationID = UUID()
        pushReconciliationID = operationID
        defer {
            if pushReconciliationID == operationID {
                pushReconciliationID = nil
                if pushReconciliationWakeRequested {
                    pushReconciliationWakeRequested = false
                    Task { [weak self] in
                        _ = try? await self?.reconcilePushIntent()
                    }
                }
            }
        }
        guard pushReconciliationID == operationID,
              configAuthority == authority,
              runtimeSession?.sessionId == session.sessionId,
              runtimeSession?.chatToken == session.chatToken,
              runtimeSession?.credential.generation == session.credential.generation,
              runtimeSession?.credential.ownerScope == session.credential.ownerScope else {
            pushReconciliationWakeRequested = true
            return .pendingRetry
        }
        guard intent.ownerScope == session.credential.ownerScope else {
            // Keep the previous account's protected work unavailable rather
            // than attempting to authorise it with the current account.
            return .requiresHostAction
        }
        if intent.isRegistered { return .registered }
        if !intent.automaticallyRetryable { return .requiresHostAction }
        if let eligibleAt = intent.eligibleAt, now() < eligibleAt { return .pendingRetry }
        if intent.requiresFreshBearer {
            // Push never refreshes or mutates the chat session. A later normal
            // session success consumes this gate and retries with its new bearer.
            return .pendingRetry
        }
        guard persistence == persistenceAuthority(for: session, bearerContext: authority) else {
            return .pendingRetry
        }
        return try await sendPushIntent(intent, session: session)
    }

    private func sendPushIntent(
        _ intent: ProtectedPushIntent,
        session: RuntimeSession
    ) async throws -> OnloPushRegistrationState {
        let bearerAuthority = configAuthority
        let persistence = persistenceAuthority(for: session, bearerContext: bearerAuthority)
        let authorised = configAuthority == bearerAuthority &&
            runtimeSession?.sessionId == session.sessionId &&
            runtimeSession?.chatToken == session.chatToken &&
            runtimeSession?.credential.generation == session.credential.generation &&
            runtimeSession?.credential.ownerScope == intent.ownerScope
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
            guard configAuthority == bearerAuthority,
                  runtimeSession?.sessionId == session.sessionId,
                  runtimeSession?.chatToken == session.chatToken,
                  runtimeSession?.credential.generation == session.credential.generation,
                  runtimeSession?.credential.ownerScope == intent.ownerScope else { return .pendingRetry }
            switch (intent.action, envelope.result) {
            case (.register, .active(let state, let provider, _, _, _)):
                guard provider == .apns, state == .active || state == .muted else { throw OnloError.invalidResponse }
                // Retain the active token only in protected storage to avoid
                // duplicate registration while this owner remains current.
                guard let pushStore = pushIntentStore as? any AuthorityFencedPushIntentStoring,
                      try await pushStore.save(ProtectedPushIntent(
                    ownerScope: intent.ownerScope,
                    action: .register,
                    token: intent.token,
                    notificationPreference: intent.notificationPreference,
                    locale: intent.locale,
                    attemptCount: 0,
                    eligibleAt: nil,
                    isRegistered: true,
                    automaticallyRetryable: false
                ), replacing: intent, authority: persistence) else { return .pendingRetry }
            case (.unregister, .inactive(let state)):
                guard state == .inactive else { throw OnloError.invalidResponse }
                guard let pushStore = pushIntentStore as? any AuthorityFencedPushIntentStoring,
                      try await pushStore.clear(replacing: intent, authority: persistence) else { return .pendingRetry }
            default:
                throw OnloError.invalidResponse
            }
            pushRetryTask?.cancel(); pushRetryTask = nil
            return .registered
        } catch let error as OnloError {
            if case let .remote(remote) = error {
                switch remote.retry.directive {
                case .afterTokenRefresh:
                    // Persist the prerequisite without touching session state.
                    // The next normal session success supplies the new bearer.
                    let gated = copiedPushIntent(intent, retryDirective: .afterTokenRefresh, requiresFreshBearer: true)
                    guard let pushStore = pushIntentStore as? any AuthorityFencedPushIntentStoring,
                          try await pushStore.save(gated, replacing: intent, authority: persistence) else { return .pendingRetry }
                    return .pendingRetry
                case .afterBackoff:
                    return try await deferPushIntent(intent, serverRetryAfterMs: remote.retry.retryAfterMs, directive: .afterBackoff, authority: persistence)
                case .never, .afterAttestation, .afterFullSync:
                    guard let pushStore = pushIntentStore as? any AuthorityFencedPushIntentStoring,
                          try await pushStore.save(
                              copiedPushIntent(intent, retryDirective: remote.retry.directive, requiresFreshBearer: false, automaticallyRetryable: false),
                              replacing: intent,
                              authority: persistence
                          ) else { return .pendingRetry }
                    return .requiresHostAction
                }
            }
            // A transport outcome is ambiguous. Both operations are
            // idempotent, so retain the exact protected intent with bounded
            // local backoff rather than treating it as server-directed retry.
            if error.transportCode != nil {
                return try await deferPushIntent(intent, serverRetryAfterMs: nil, directive: nil, authority: persistence)
            }
            throw error
        } catch {
            return try await deferPushIntent(intent, serverRetryAfterMs: nil, directive: nil, authority: persistence)
        }
    }

    private func copiedPushIntent(_ intent: ProtectedPushIntent, retryDirective: RetryDirective?, requiresFreshBearer: Bool, automaticallyRetryable: Bool? = nil, eligibleAt: Date? = nil, attemptCount: Int? = nil) -> ProtectedPushIntent {
        ProtectedPushIntent(ownerScope: intent.ownerScope, action: intent.action, token: intent.token, notificationPreference: intent.notificationPreference, locale: intent.locale, attemptCount: attemptCount ?? intent.attemptCount, eligibleAt: eligibleAt, retryDirective: retryDirective, requiresFreshBearer: requiresFreshBearer, isRegistered: false, automaticallyRetryable: automaticallyRetryable ?? intent.automaticallyRetryable)
    }

    private func deferPushIntent(
        _ intent: ProtectedPushIntent,
        serverRetryAfterMs: Int?,
        directive: RetryDirective?,
        authority: PersistenceAuthority
    ) async throws -> OnloPushRegistrationState {
        guard let pushStore = pushIntentStore as? any AuthorityFencedPushIntentStoring else {
            throw OnloError.persistenceUnavailable
        }
        guard intent.attemptCount < 3 else {
            guard try await pushStore.save(
                copiedPushIntent(intent, retryDirective: directive, requiresFreshBearer: false, automaticallyRetryable: false),
                replacing: intent,
                authority: authority
            ) else { return .pendingRetry }
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
        guard try await pushStore.save(deferred, replacing: intent, authority: authority) else { return .pendingRetry }
        schedulePushRetry(for: deferred, delay: delay, authority: authority)
        return .pendingRetry
    }

    private func schedulePushRetry(
        for intent: ProtectedPushIntent,
        delay: TimeInterval,
        authority: PersistenceAuthority
    ) {
        pushRetryTask?.cancel()
        pushRetryTask = Task { [weak self] in
            let maxSleep = Double(UInt64.max) / 1_000_000_000
            if delay > 0, delay.isFinite, delay <= maxSleep {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            } else {
                return // lifecycle recovery observes the persisted eligibility
            }
            guard !Task.isCancelled else { return }
            await self?.wakePushRetry(authority: authority)
        }
    }

    private func wakePushRetry(authority: PersistenceAuthority) async {
        pushRetryTask = nil
        guard let session = runtimeSession,
              persistenceAuthority(for: session, bearerContext: configAuthority) == authority,
              state == .anonymousReady || state == .identifiedReady else { return }
        _ = try? await reconcilePushIntent()
    }

    private func schedulePushReconciliationAfterSessionSuccess() {
        let expectedRegistrationRevision = pushRegistrationRevision
        Task { [weak self] in
            await self?.reconcilePushAfterSessionSuccess(
                expectedRegistrationRevision: expectedRegistrationRevision
            )
        }
    }

    private func reconcilePushAfterSessionSuccess(
        expectedRegistrationRevision: UInt64
    ) async {
        await consumePushFreshBearerGateAfterSessionSuccess()
        guard expectedRegistrationRevision == pushRegistrationRevision else { return }
        _ = try? await reconcilePushIntent(
            expectedRegistrationRevision: expectedRegistrationRevision
        )
        guard expectedRegistrationRevision == pushRegistrationRevision else { return }
        await registerPendingAPNsAfterSessionReady()
    }

    private func consumePushFreshBearerGateAfterSessionSuccess() async {
        guard let session = runtimeSession,
              state == .anonymousReady || state == .identifiedReady else { return }
        do {
            guard let intent = try await pushIntentStore.load(),
                  intent.ownerScope == session.credential.ownerScope,
                  intent.requiresFreshBearer,
                  let pushStore = pushIntentStore as? any AuthorityFencedPushIntentStoring else { return }
            let authority = persistenceAuthority(for: session, bearerContext: configAuthority)
            await pushStore.activateAuthority(authority)
            _ = try await pushStore.save(
                copiedPushIntent(intent, retryDirective: nil, requiresFreshBearer: false),
                replacing: intent,
                authority: authority
            )
        } catch {
            // Push persistence cannot affect the newly established chat session.
        }
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
        try await activatePersistenceAuthority(for: runtimeSession!)
        state = .anonymousReady
        await refreshConfigurationAfterSessionSuccess()
        startDurableDispatchIfNeeded()
        startForegroundStreamIfAvailable()
        schedulePushReconciliationAfterSessionSuccess()
    }

    /// A rejected resume proves the installation credential can no longer be
    /// rotated. Recovery is deliberately host-triggered through a login API:
    /// fence and purge the old owner before creating a replacement anonymous
    /// installation, which identified login can immediately exchange.
    private func replaceExpiredInstallation(
        with stored: StoredSessionCredential,
        pendingTransition: PendingSessionTransition?
    ) async throws {
        guard state == .reauthRequired,
              !stored.logoutPending,
              pendingTransition?.isIdentify != true,
              pendingTransition == nil || pendingTransition?.matchesResume(stored) == true else {
            throw OnloError.invalidState
        }

        await invalidateMessengerPresentations()
        identifiedFirstName = nil
        cancelConfigRetry()
        pushRetryTask?.cancel()
        pushRetryTask = nil
        pushReconciliationID = nil
        pushReconciliationWakeRequested = false
        runtimeSession = nil
        configAuthority = UUID()
        cancelActiveSends(for: stored.ownerScope)
        await revokePersistenceAuthority(for: stored.ownerScope)

        // Persist the account fence before removing credentials. A crash can
        // never make the old owner scope readable by a replacement session.
        try await ownerStore.beginLogout(for: stored.ownerScope)
        try await commitProtectedState(credential: nil, pendingTransition: nil)
        try? await pushIntentStore.clear()
        try await ownerStore.finishLogout(for: stored.ownerScope)

        messengerInboxCache = nil
        helpCenterCache = nil
        transcriptValidationAuthorities.removeAll()
        conversationObservationGeneration &+= 1
        state = .restoring
        try await bootstrapAnonymous()
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
        acceptedReconciliationRetryTasks.removeValue(forKey: scope)?.cancel()
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
    /// session-authority-bound: one unresolved transport turn owns the FIFO
    /// slot through stream completion. Acceptance makes the row durable but
    /// does not allow a later customer message to overlap the server's active
    /// response for this turn.
    private func startDurableDispatchIfNeeded() {
        guard let session = runtimeSession,
              state == .anonymousReady || state == .identifiedReady,
              activeDispatchIDs[session.credential.ownerScope] == nil,
              transport is any OnloChatSSETransport,
              requestFactory != nil else { return }
        let dispatchID = UUID()
        let scope = session.credential.ownerScope
        let authority = configAuthority
        acceptedReconciliationRetryTasks[scope]?.cancel()
        acceptedReconciliationRetryTasks[scope] = nil
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

    private func hasDispatchAuthority(
        dispatchID: UUID,
        scope: OwnerScope,
        authority: UUID,
        session: RuntimeSession
    ) -> Bool {
        activeDispatchIDs[scope] == dispatchID &&
            configAuthority == authority &&
            (state == .anonymousReady || state == .identifiedReady) &&
            runtimeSession?.credential.ownerScope == scope &&
            runtimeSession?.credential.generation == session.credential.generation &&
            runtimeSession?.sessionId == session.sessionId &&
            runtimeSession?.chatToken == session.chatToken
    }

    private func runDurableDispatch(dispatchID: UUID, scope: OwnerScope, authority: UUID) async {
        let dispatchStartedAt = Date()
        var shouldAdvanceQueue = false
        defer {
            releaseDurableDispatch(dispatchID, scope: scope)
            finishSend(dispatchID, scope: scope)
            if shouldAdvanceQueue {
                startDurableDispatchIfNeeded()
            }
        }
        do {
            guard let session = runtimeSession,
                  session.credential.ownerScope == scope,
                  hasDispatchAuthority(
                      dispatchID: dispatchID,
                      scope: scope,
                      authority: authority,
                      session: session
                  ),
                  let requestFactory,
                  let streamTransport = transport as? any OnloChatSSETransport else { return }
            let persistence = persistenceAuthority(for: session, bearerContext: authority)
            guard await reconcileAcceptedOutbox(session: session, authority: persistence) else {
                scheduleAcceptedReconciliationRetry(
                    scope: scope,
                    authority: authority,
                    sessionId: session.sessionId
                )
                return
            }
            guard hasDispatchAuthority(dispatchID: dispatchID, scope: scope, authority: authority, session: session),
                  let entry = try await nextDurableTextDispatch(
                      dispatchID: dispatchID,
                      expectedAuthority: authority
                  ),
                  hasDispatchAuthority(dispatchID: dispatchID, scope: scope, authority: authority, session: session) else { return }
            let request = try requestFactory.chat(
                ChatRequest(sessionId: entry.routingSessionId ?? session.sessionId, clientMessageId: entry.clientMessageId.uuidString, message: entry.message, attachments: entry.attachments.map(\.attachment)),
                chatToken: session.chatToken
            )
            let chatStartedAt = Date()
            var accepted = false
            var acceptedConversationId: String?
            var recordedFirstToken = false
            let chatCorrelator = streamTransport as? any OnloChatRequestCorrelating
            defer {
                chatCorrelator?.clearChatRequestId(
                    for: entry.clientMessageId.uuidString
                )
            }
            do {
                for try await event in streamTransport.chatEvents(for: request) {
                    guard !Task.isCancelled,
                          hasDispatchAuthority(
                              dispatchID: dispatchID,
                              scope: scope,
                              authority: authority,
                              session: session
                          ) else { return }
                    if case let .accepted(clientMessageId, messageId, conversationId, _, duplicate, _) = event {
                        guard !accepted else {
                            throw OnloError.transport(code: "duplicate_accepted_event")
                        }
                        await record(
                            operation: "chat",
                            code: "accepted_received",
                            requestId: chatCorrelator?.chatRequestId(
                                for: entry.clientMessageId.uuidString
                            ),
                            startedAt: chatStartedAt
                        )
                        try await markChatAccepted(
                            clientMessageId: clientMessageId,
                            messageId: messageId,
                            conversationId: conversationId,
                            entry: entry,
                            authority: persistence
                        )
                        guard hasDispatchAuthority(
                            dispatchID: dispatchID,
                            scope: scope,
                            authority: authority,
                            session: session
                        ) else { return }
                        accepted = true
                        acceptedConversationId = conversationId
                        await record(
                            operation: "chat",
                            code: "accepted",
                            requestId: chatCorrelator?.chatRequestId(
                                for: entry.clientMessageId.uuidString
                            ),
                            startedAt: chatStartedAt
                        )
                        yield(event, for: entry)
                        // Receipt durability is authoritative. A duplicate's
                        // transcript fetch is convergence work and must never
                        // reclassify or resend this accepted logical message.
                        if duplicate {
                            _ = try? await reconcileTranscript(
                                conversationId: conversationId,
                                session: session
                            )
                        }
                    } else {
                        switch event {
                        case .text:
                            guard accepted else {
                                throw OnloError.transport(code: "text_before_accepted")
                            }
                            if !recordedFirstToken {
                                recordedFirstToken = true
                                await record(
                                    operation: "chat",
                                    code: "first_token",
                                    requestId: chatCorrelator?.chatRequestId(
                                        for: entry.clientMessageId.uuidString
                                    ),
                                    startedAt: chatStartedAt
                                )
                            }
                        case let .done(conversationId, _, _, _, _):
                            guard acceptedConversationId == conversationId else {
                                throw OnloError.transport(code: "done_conversation_mismatch")
                            }
                            try await markChatReconciled(entry: entry, authority: persistence)
                            guard hasDispatchAuthority(
                                dispatchID: dispatchID,
                                scope: scope,
                                authority: authority,
                                session: session
                            ) else { return }
                        case .error:
                            break
                        case .accepted:
                            break
                        }
                        try await handleChatEvent(event, entry: entry, session: session)
                        guard hasDispatchAuthority(
                            dispatchID: dispatchID,
                            scope: scope,
                            authority: authority,
                            session: session
                        ) else { return }
                        yield(event, for: entry)
                        if case .done = event {
                            await record(
                                operation: "chat",
                                code: "complete",
                                requestId: chatCorrelator?.chatRequestId(
                                    for: entry.clientMessageId.uuidString
                                ),
                                startedAt: chatStartedAt
                            )
                        }
                    }
                }
                if !accepted {
                    let error = OnloError.transport(code: "network_unavailable")
                    try await recordDurableDispatchFailure(entry, retryable: true, safeCode: error.safeCode, authority: persistence)
                    finishObserver(for: entry, error: error)
                    await scheduleRetryWake(
                        for: scope,
                        dispatchID: dispatchID,
                        authority: authority,
                        session: session
                    )
                } else {
                    finishObserver(for: entry)
                    shouldAdvanceQueue = true
                }
            } catch let error as OnloError {
                guard !Task.isCancelled, configAuthority == authority,
                      hasDispatchAuthority(dispatchID: dispatchID, scope: scope, authority: authority, session: session) else { return }
                await record(
                    operation: "chat",
                    code: error.safeCode,
                    requestId: error.requestId ?? chatCorrelator?.chatRequestId(
                        for: entry.clientMessageId.uuidString
                    ),
                    startedAt: chatStartedAt
                )
                if !accepted {
                    let retryable = isRetryableChatFailure(error)
                    try? await recordDurableDispatchFailure(entry, retryable: retryable, safeCode: error.safeCode, authority: persistence)
                    finishObserver(for: entry, error: error)
                    if retryable {
                        await scheduleRetryWake(
                            for: scope,
                            dispatchID: dispatchID,
                            authority: authority,
                            session: session
                        )
                    } else {
                        shouldAdvanceQueue = true
                    }
                } else {
                    finishObserver(for: entry, error: error)
                    shouldAdvanceQueue = true
                }
            } catch {
                guard !Task.isCancelled, configAuthority == authority,
                      hasDispatchAuthority(dispatchID: dispatchID, scope: scope, authority: authority, session: session) else { return }
                let error = OnloError.transport(code: "network_unavailable")
                await record(
                    operation: "chat",
                    code: error.safeCode,
                    requestId: chatCorrelator?.chatRequestId(
                        for: entry.clientMessageId.uuidString
                    ),
                    startedAt: chatStartedAt
                )
                if accepted {
                    finishObserver(for: entry, error: error)
                    shouldAdvanceQueue = true
                } else {
                    try? await recordDurableDispatchFailure(entry, retryable: true, safeCode: error.safeCode, authority: persistence)
                    finishObserver(for: entry, error: error)
                    await scheduleRetryWake(
                        for: scope,
                        dispatchID: dispatchID,
                        authority: authority,
                        session: session
                    )
                }
            }
        } catch let error as OnloError {
            await record(
                operation: "chat",
                code: error.safeCode,
                requestId: error.requestId,
                startedAt: dispatchStartedAt
            )
        } catch {
            await record(
                operation: "chat",
                code: "network_unavailable",
                requestId: nil,
                startedAt: dispatchStartedAt
            )
        }
    }

    private func scheduleRetryWake(
        for scope: OwnerScope,
        dispatchID: UUID,
        authority: UUID,
        session: RuntimeSession
    ) async {
        retryWakeTasks.removeValue(forKey: scope)?.cancel()
        guard hasDispatchAuthority(
            dispatchID: dispatchID,
            scope: scope,
            authority: authority,
            session: session
        ) else { return }
        guard let entries = try? await ownerStore.outboxEntries(for: scope),
              hasDispatchAuthority(
                  dispatchID: dispatchID,
                  scope: scope,
                  authority: authority,
                  session: session
              ),
              let nextAttemptAt = entries.first(where: { $0.state == .failedRetryable })?.nextAttemptAt else { return }
        let delay = max(0, nextAttemptAt.timeIntervalSince(now()))
        retryWakeTasks[scope] = Task {
            if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            guard !Task.isCancelled else { return }
            self.wakeDurableDispatch(
                scope: scope,
                authority: authority,
                session: session
            )
        }
    }

    private func wakeDurableDispatch(
        scope: OwnerScope,
        authority: UUID,
        session: RuntimeSession
    ) {
        retryWakeTasks[scope] = nil
        guard configAuthority == authority,
              runtimeSession?.sessionId == session.sessionId,
              runtimeSession?.chatToken == session.chatToken,
              runtimeSession?.credential.generation == session.credential.generation,
              runtimeSession?.credential.ownerScope == scope else { return }
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
        defer {
            finishForegroundStream(
                streamID,
                authority: authority,
                scope: scope,
                sessionId: session.sessionId
            )
        }
        let startedAt = Date()
        var recordedReady = false
        do {
            for try await event in transport.streamEvents(for: request) {
                guard hasForegroundAuthority(
                    streamID: streamID,
                    authority: authority,
                    scope: scope,
                    session: session
                ) else { return }
                switch event {
                case .ready:
                    foregroundReconnectAttempt = 0
                    if !recordedReady {
                        recordedReady = true
                        await record(operation: "stream", code: "ok", requestId: nil, startedAt: startedAt)
                    }
                    continue
                case .configChanged:
                    helpCenterCache = nil
                    try? await refreshConfiguration()
                    guard hasForegroundAuthority(
                        streamID: streamID,
                        authority: authority,
                        scope: scope,
                        session: session
                    ) else { return }
                case let .inboxConversation(conversationId), let .inboxMessage(conversationId):
                    let transcript = try? await reconcileTranscript(
                        conversationId: conversationId,
                        session: session
                    )
                    startDurableDispatchIfNeeded()
                    guard hasForegroundAuthority(
                        streamID: streamID,
                        authority: authority,
                        scope: scope,
                        session: session
                    ) else { return }
                    guard let inbox = try? await authorisedInbox(for: session) else { continue }
                    guard hasForegroundAuthority(
                        streamID: streamID,
                        authority: authority,
                        scope: scope,
                        session: session
                    ) else { return }
                    publishMessengerUpdate(MessengerRealtimeUpdate(
                        conversationId: conversationId,
                        transcript: transcript,
                        conversations: inbox.conversations
                    ))
                }
            }
        } catch let error as OnloError {
            await record(operation: "stream", code: error.safeCode, requestId: error.requestId, startedAt: startedAt)
        } catch {
            await record(operation: "stream", code: "network_unavailable", requestId: nil, startedAt: startedAt)
        }
    }

    private func hasForegroundAuthority(
        streamID: UUID,
        authority: UUID,
        scope: OwnerScope,
        session: RuntimeSession
    ) -> Bool {
        !Task.isCancelled &&
            foregroundStreamID == streamID &&
            foregroundStreamScope == scope &&
            configAuthority == authority &&
            runtimeSession?.sessionId == session.sessionId &&
            runtimeSession?.chatToken == session.chatToken &&
            runtimeSession?.credential.generation == session.credential.generation &&
            runtimeSession?.credential.ownerScope == scope &&
            (state == .anonymousReady || state == .identifiedReady)
    }

    private func finishForegroundStream(
        _ streamID: UUID,
        authority: UUID,
        scope: OwnerScope,
        sessionId: String
    ) {
        guard foregroundStreamID == streamID else { return }
        foregroundStreamTask = nil
        foregroundStreamScope = nil
        foregroundStreamID = nil
        // An authority rotation (for example config's bounded token refresh)
        // deliberately replaces the bearer stream immediately.
        if configAuthority != authority,
           state == .anonymousReady || state == .identifiedReady {
            startForegroundStreamIfAvailable()
            return
        }
        guard configAuthority == authority,
              state == .anonymousReady || state == .identifiedReady,
              runtimeSession?.sessionId == sessionId,
              runtimeSession?.credential.ownerScope == scope else { return }
        scheduleForegroundReconnect(
            authority: authority,
            scope: scope,
            sessionId: sessionId
        )
    }

    private func scheduleForegroundReconnect(
        authority: UUID,
        scope: OwnerScope,
        sessionId: String
    ) {
        guard foregroundReconnectTask == nil else { return }
        foregroundReconnectAttempt = min(foregroundReconnectAttempt + 1, 7)
        let proposedDelay = foregroundReconnectDelay(foregroundReconnectAttempt)
        let delay = proposedDelay.isFinite ? min(max(0, proposedDelay), 60) : 60
        let reconnectID = UUID()
        foregroundReconnectID = reconnectID
        foregroundReconnectScope = scope
        foregroundReconnectTask = Task { [weak self] in
            if delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
            guard !Task.isCancelled else { return }
            await self?.resumeForegroundStream(
                reconnectID: reconnectID,
                authority: authority,
                scope: scope,
                sessionId: sessionId
            )
        }
    }

    private func resumeForegroundStream(
        reconnectID: UUID,
        authority: UUID,
        scope: OwnerScope,
        sessionId: String
    ) {
        guard foregroundReconnectID == reconnectID else { return }
        foregroundReconnectTask = nil
        foregroundReconnectScope = nil
        foregroundReconnectID = nil
        guard configAuthority == authority,
              state == .anonymousReady || state == .identifiedReady,
              runtimeSession?.sessionId == sessionId,
              runtimeSession?.credential.ownerScope == scope else { return }
        startForegroundStreamIfAvailable()
    }

    private func cancelForegroundStream(for scope: OwnerScope) {
        if foregroundReconnectScope == scope {
            foregroundReconnectTask?.cancel()
            foregroundReconnectTask = nil
            foregroundReconnectScope = nil
            foregroundReconnectID = nil
            foregroundReconnectAttempt = 0
        }
        guard foregroundStreamScope == scope else { return }
        foregroundStreamTask?.cancel()
        foregroundStreamTask = nil
        foregroundStreamScope = nil
        foregroundStreamID = nil
    }

    private func isRetryableChatFailure(_ error: OnloError) -> Bool {
        guard let code = error.transportCode else { return false }
        return code == "network_unavailable" || code == "chat_retryable"
    }

    private func markChatAccepted(
        clientMessageId: String,
        messageId: String,
        conversationId: String,
        entry: OutboxEntry,
        authority: PersistenceAuthority
    ) async throws {
        guard UUID(uuidString: clientMessageId) == entry.clientMessageId else {
            throw OnloError.transport(code: "accepted_client_message_mismatch")
        }
        let accepted = OutboxEntry(
                clientMessageId: entry.clientMessageId,
                ownerScope: entry.ownerScope,
                conversationId: conversationId,
                routingSessionId: entry.routingSessionId,
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
        guard let store = ownerStore as? any AuthorityFencedPersisting,
              try await store.update(
                  accepted,
                  expectedState: .sending,
                  expectedAttemptCount: entry.attemptCount,
                  authority: authority
              ) else { throw OnloError.invalidState }
    }

    private func markChatReconciled(
        entry: OutboxEntry,
        authority: PersistenceAuthority
    ) async throws {
        guard let accepted = try await ownerStore.outboxEntries(for: entry.ownerScope).first(where: {
            $0.clientMessageId == entry.clientMessageId && $0.state == .accepted
        }) else { return }
        let reconciled = OutboxEntry(
            clientMessageId: accepted.clientMessageId,
            ownerScope: accepted.ownerScope,
            conversationId: accepted.conversationId,
            routingSessionId: accepted.routingSessionId,
            message: accepted.message,
            attachments: [],
            createdAt: accepted.createdAt,
            orderingKey: accepted.orderingKey,
            state: .reconciled,
            attemptCount: accepted.attemptCount,
            nextAttemptAt: nil,
            lastErrorCode: nil,
            serverMessageId: accepted.serverMessageId,
            aiRunId: accepted.aiRunId
        )
        guard let store = ownerStore as? any AuthorityFencedPersisting,
              try await store.update(
                  reconciled,
                  expectedState: .accepted,
                  expectedAttemptCount: accepted.attemptCount,
                  authority: authority
              ) else { throw OnloError.invalidState }
        acceptedReconciliationRetryTasks.removeValue(forKey: entry.ownerScope)?.cancel()
    }

    private func reconcileAcceptedOutbox(
        session: RuntimeSession,
        authority: PersistenceAuthority
    ) async -> Bool {
        let entries: [OutboxEntry]
        do {
            entries = try await ownerStore.outboxEntries(for: session.credential.ownerScope)
                .filter { $0.state == .accepted }
        } catch {
            return false
        }
        for entry in entries {
            guard let conversationId = entry.conversationId,
                  let serverMessageId = entry.serverMessageId else { return false }
            do {
                let transcript = try await reconcileTranscript(
                    conversationId: conversationId,
                    session: session
                )
                guard let acceptedIndex = transcript.messages.firstIndex(where: {
                    $0.id == serverMessageId
                }), transcript.messages.dropFirst(acceptedIndex + 1).contains(where: {
                    $0.role != "user" && $0.role != "customer"
                }) else { return false }
                guard let store = ownerStore as? any AuthorityFencedPersisting,
                      try await store.reconcileAccepted(
                          entry,
                          transcript: transcript,
                          expectedServerMessageId: serverMessageId,
                          authority: authority
                      ) else { return false }
            } catch {
                return false
            }
        }
        acceptedReconciliationRetryTasks.removeValue(forKey: session.credential.ownerScope)?.cancel()
        return true
    }

    private func scheduleAcceptedReconciliationRetry(
        scope: OwnerScope,
        authority: UUID,
        sessionId: String
    ) {
        guard acceptedReconciliationRetryTasks[scope] == nil else { return }
        let delay = max(0, min(acceptedReconciliationDelay(), 30))
        acceptedReconciliationRetryTasks[scope] = Task { [weak self] in
            if delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
            guard let self, !Task.isCancelled else { return }
            await self.fireAcceptedReconciliationRetry(
                scope: scope,
                authority: authority,
                sessionId: sessionId
            )
        }
    }

    private func fireAcceptedReconciliationRetry(
        scope: OwnerScope,
        authority: UUID,
        sessionId: String
    ) {
        acceptedReconciliationRetryTasks[scope] = nil
        guard configAuthority == authority,
              runtimeSession?.sessionId == sessionId,
              runtimeSession?.credential.ownerScope == scope else { return }
        startDurableDispatchIfNeeded()
    }

    private func handleChatEvent(_ event: ChatEvent, entry: OutboxEntry, session: RuntimeSession) async throws {
        switch event {
        case .accepted:
            throw OnloError.invalidResponse
        case .text:
            return
        case .done(let conversationId, let duplicate, _, _, _):
            if duplicate == true {
                _ = try await reconcileTranscript(
                    conversationId: conversationId,
                    session: session
                )
            }
        case .error(let code, let retryable):
            guard retryable else {
                if [
                    "attachment_grant_expired",
                    "invalid_attachment_grant",
                    APIErrorCode.mediaUnavailable.rawValue,
                ].contains(code) {
                    throw OnloError.transport(code: code)
                }
                throw OnloError.invalidResponse
            }
            throw OnloError.transport(code: "chat_retryable")
        }
    }

    private func reconcileTranscript(
        conversationId: String,
        session: RuntimeSession
    ) async throws -> ConversationTranscriptResult {
        guard let requestFactory else { throw OnloError.notInitialized }
        return try await withSerializedTranscriptObservation(
            ownerScope: session.credential.ownerScope,
            conversationId: conversationId
        ) {
            let authority = configAuthority
            let request = try requestFactory.transcript(conversationId: conversationId, query: .latest(limit: 100), chatToken: session.chatToken)
            let response = try await transport.execute(request)
            let transcript = try OnloResponseDecoder.widget(ConversationTranscriptResult.self, from: response)
            guard configAuthority == authority,
                  isAuthorisedTranscript(transcript, conversationId: conversationId, session: session) else {
                throw OnloError.invalidResponse
            }
            guard let transcriptStore = ownerStore as? any AuthorityFencedPersisting else { throw OnloError.persistenceUnavailable }
            guard try await transcriptStore.replaceTranscript(
                transcript,
                authority: persistenceAuthority(for: session, bearerContext: authority)
            ) else { throw OnloError.invalidState }
            guard configAuthority == authority,
                  runtimeSession?.sessionId == session.sessionId,
                  runtimeSession?.credential.ownerScope == session.credential.ownerScope else {
                throw OnloError.invalidState
            }
            transcriptValidationAuthorities[conversationId] = authority
            return transcript
        }
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
            if error.transportCode != nil {
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

    /// Recovery-only resume for a legacy scope already marked `logoutPending`.
    /// Its result is kept in memory solely to create the logout transition; it
    /// never calls `applyResumedSession` or clears the boundary.
    private func resumeForPendingLogout(_ stored: StoredSessionCredential) async throws -> SessionResult {
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
        // Rotate the actor-visible bearer authority before the persistence
        // actor arbitrates the final old-vs-revocation ordering.
        configAuthority = UUID()
        let scope: OwnerScope
        if previous.identityClass == result.identityClass {
            scope = previous.ownerScope
        } else {
            // A server-side identity transition cannot expose the old partition locally.
            cancelActiveSends(for: previous.ownerScope)
            await revokePersistenceAuthority(for: previous.ownerScope)
            await invalidateMessengerPresentations()
            try await ownerStore.beginLogout(for: previous.ownerScope)
            try await ownerStore.finishLogout(for: previous.ownerScope)
            try? await pushIntentStore.clear()
            scope = OwnerScope(kind: result.identityClass == .anonymous ? .anonymous : .identified)
            try await ownerStore.prepare(scope: scope)
        }
        // A resumed session may rotate the bearer while retaining the same
        // owner. Release its old stream before publishing the replacement so
        // foreground recovery cannot remain attached to stale authority.
        if runtimeSession?.credential.ownerScope == scope {
            cancelActiveSends(for: scope)
            await revokePersistenceAuthority(for: scope)
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
        try await activatePersistenceAuthority(for: runtimeSession!)
        state = result.identityClass == .anonymous ? .anonymousReady : .identifiedReady
        await refreshConfigurationAfterSessionSuccess()
        startDurableDispatchIfNeeded()
        startForegroundStreamIfAvailable()
        schedulePushReconciliationAfterSessionSuccess()
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
            await revokePersistenceAuthority(for: previous.ownerScope)
            await invalidateMessengerPresentations()
            try await ownerStore.beginLogout(for: previous.ownerScope)
            try await ownerStore.finishLogout(for: previous.ownerScope)
            // The server identify transition already removed the anonymous
            // association. Its protected local intent must not block the new
            // identified owner after process-death recovery.
            try? await pushIntentStore.clear()
            let scope = OwnerScope(kind: .identified)
            try await ownerStore.prepare(scope: scope)
            let credential = StoredSessionCredential(installationId: result.result.installationId, generation: result.result.generation, proposedCredential: result.result.proposedCredential, identityClass: .identified, ownerScope: scope)
            try await commitProtectedState(credential: credential, pendingTransition: nil)
            runtimeSession = RuntimeSession(sessionId: result.result.sessionId, chatToken: result.result.chatToken, credential: credential)
            configAuthority = UUID()
            try await activatePersistenceAuthority(for: runtimeSession!)
            state = .identifiedReady
            await refreshConfigurationAfterSessionSuccess()
            startDurableDispatchIfNeeded()
            startForegroundStreamIfAvailable()
            schedulePushReconciliationAfterSessionSuccess()
            return state
        } catch let error as OnloError {
            try await resolveDefinitiveSessionFailure(error, credential: previous)
            if case let .remote(remote) = error, remote.code == .identityDisabled {
                guard let anonymousSession = runtimeSession,
                      anonymousSession.credential.identityClass == .anonymous,
                      anonymousSession.credential.ownerScope == previous.ownerScope,
                      !anonymousSession.sessionId.isEmpty,
                      !anonymousSession.chatToken.isEmpty else {
                    state = .reauthRequired
                    throw OnloError.invalidState
                }
                state = .anonymousReady
                configAuthority = UUID()
                try await activatePersistenceAuthority(for: anonymousSession)
                await refreshConfigurationAfterSessionSuccess()
                startDurableDispatchIfNeeded()
                startForegroundStreamIfAvailable()
                return state
            }
            state = .reauthRequired
            throw error
        } catch {
            state = .reauthRequired
            throw error
        }
    }

    private func continuePendingLogout(_ stored: StoredSessionCredential, pendingTransition: PendingSessionTransition?) async throws {
        if let pendingTransition, pendingTransition.matchesResume(stored) {
            let resumed = try await resumeForPendingLogout(stored)
            let refreshed = StoredSessionCredential(installationId: resumed.installationId, generation: resumed.generation, proposedCredential: resumed.proposedCredential, identityClass: resumed.identityClass, ownerScope: stored.ownerScope, logoutPending: true)
            try? await pushIntentStore.clear()
            _ = try await logout(refreshed)
            return
        }
        if let pendingTransition, !pendingTransition.matchesLogout(stored) {
            throw OnloError.invalidState
        }
        cancelActiveSends(for: stored.ownerScope)
        await invalidateMessengerPresentations()
        try await ownerStore.beginLogout(for: stored.ownerScope)
        try? await pushIntentStore.clear()
        _ = try await logout(stored, pendingTransition: pendingTransition)
    }

    private func logout(_ credential: StoredSessionCredential, pendingTransition: PendingSessionTransition? = nil) async throws -> SDKState {
        if let pendingTransition, !pendingTransition.matchesLogout(credential) {
            throw OnloError.invalidState
        }
        // The actor cannot advance into a new account state until every
        // registered native presenter has redacted/dismissed on MainActor.
        await invalidateMessengerPresentations()
        identifiedFirstName = nil
        state = .logoutPending
        cancelConfigRetry()
        pushRetryTask?.cancel(); pushRetryTask = nil
        // Once a boundary starts, no retained bearer authority may be reused.
        runtimeSession = nil
        configAuthority = UUID()
        cancelActiveSends(for: credential.ownerScope)
        await revokePersistenceAuthority(for: credential.ownerScope)
        try await ownerStore.beginLogout(for: credential.ownerScope)
        let pendingCredential = StoredSessionCredential(
            installationId: credential.installationId,
            generation: credential.generation,
            proposedCredential: credential.proposedCredential,
            identityClass: credential.identityClass,
            ownerScope: credential.ownerScope,
            logoutPending: true
        )
        // The account boundary must exist on disk before any network work.
        // No process-death path can observe this scope as usable again.
        try await commitProtectedState(credential: pendingCredential, pendingTransition: pendingTransition)
        // Push cleanup is local and best effort. The server Logout below
        // atomically clears the registration with the old customer binding.
        try? await pushIntentStore.clear()
        let pending: PendingSessionTransition
        if let pendingTransition {
            pending = pendingTransition
        } else {
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
        try await activatePersistenceAuthority(for: runtimeSession!)
        state = .anonymousReady
        await refreshConfigurationAfterSessionSuccess()
        startDurableDispatchIfNeeded()
        startForegroundStreamIfAvailable()
        schedulePushReconciliationAfterSessionSuccess()
        return state
    }

    private static func firstNameClaim(from jwt: String) -> String? {
        let segments = jwt.split(separator: ".", omittingEmptySubsequences: false)
        guard segments.count == 3 else { return nil }
        var payload = String(segments[1]).replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let name = object["name"] as? String else { return nil }
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, clean.count <= 200,
              clean.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else { return nil }
        return clean.split(whereSeparator: { $0.isWhitespace }).first.map(String.init)
    }

    /// Fetches configuration only with the in-memory bearer. The value is
    /// committed to one protected record after strict decoding succeeds, so a
    /// malformed response can never replace last-known-good state.
    private func refreshConfiguration(allowTokenRefresh: Bool = true) async throws {
        guard let session = runtimeSession, let requestFactory else { throw OnloError.requiresNetwork }
        let startedAt = Date()
        let authority = configAuthority
        let persistence = persistenceAuthority(for: session, bearerContext: authority)
        var persisted = ProtectedMobileConfigState(config: nil, etag: nil, retry: nil)
        do {
            persisted = try await loadConfigurationStateRecoveringCorruptCache(
                authority: persistence
            )
            guard hasConfigurationAuthority(authority, session: session) else { throw OnloError.invalidState }
            if case let .afterBackoff(eligibleAt, _) = persisted.retry, now() < eligibleAt {
                throw OnloError.requiresNetwork
            }
            let request = try requestFactory.config(chatToken: session.chatToken, etag: persisted.etag)
            let response = try await transport.execute(request)
            guard hasConfigurationAuthority(authority, session: session) else { throw OnloError.invalidState }
            if response.statusCode == 304 {
                // The contract requires an exactly empty 304 response body.
                guard response.body.isEmpty, persisted.config != nil, persisted.etag?.isEmpty == false else { throw OnloError.invalidResponse }
                let returnedETag = Self.header("etag", in: response.headers)
                guard returnedETag == nil || returnedETag == persisted.etag else { throw OnloError.invalidResponse }
                let etag = persisted.etag
                try await saveConfigurationState(
                    ProtectedMobileConfigState(config: persisted.config, etag: etag, retry: nil),
                    authority: persistence
                )
                configurationValidationAuthority = authority
                await record(operation: "config", code: "not_modified", requestId: nil, startedAt: startedAt)
                return
            }
            let envelope = try OnloResponseDecoder.envelope(MobileConfig.self, from: response)
            guard let etag = Self.header("etag", in: response.headers), !etag.isEmpty else { throw OnloError.invalidResponse }
            try await saveConfigurationState(
                ProtectedMobileConfigState(config: envelope.result, etag: etag, retry: nil),
                authority: persistence
            )
            configurationValidationAuthority = authority
            configRetryTask?.cancel(); configRetryTask = nil
            await record(operation: "config", code: "ok", requestId: envelope.requestId, startedAt: startedAt)
        } catch let error as OnloError {
            await record(operation: "config", code: error.safeCode, requestId: error.requestId, startedAt: startedAt)
            if try await resolveConfigurationFailure(
                error,
                previous: persisted,
                allowTokenRefresh: allowTokenRefresh,
                authority: persistence
            ) { return }
            throw error
        } catch {
            let safe = OnloError.transport(code: "network_unavailable")
            await record(operation: "config", code: safe.safeCode, requestId: nil, startedAt: startedAt)
            // Offline is not a protocol failure: retain the protected LKG.
            throw safe
        }
    }

    private func saveConfigurationState(
        _ state: ProtectedMobileConfigState,
        authority: PersistenceAuthority
    ) async throws {
        guard let store = configStore as? any AuthorityFencedConfigStoring,
              try await store.saveConfigState(state, authority: authority) else {
            throw OnloError.invalidState
        }
    }

    private func loadConfigurationStateRecoveringCorruptCache(
        authority: PersistenceAuthority? = nil
    ) async throws -> ProtectedMobileConfigState {
        do {
            return try await configStore.loadConfigState()
        } catch let error as OnloError {
            guard case let .credentialStore(code) = error,
                  code == "config_keychain_decode_failed" || code == "config_state_invariant_failed" else {
                throw error
            }
            let empty = ProtectedMobileConfigState(config: nil, etag: nil, retry: nil)
            if let authority {
                try await saveConfigurationState(empty, authority: authority)
            }
            configurationValidationAuthority = nil
            await logger.record(SDKLogEvent(
                operation: "config",
                code: "cache_reset",
                requestId: nil,
                sdkVersion: configuration?.sdkVersion ?? "unknown",
                durationMs: 0
            ))
            return empty
        }
    }

    private func resolveConfigurationFailure(
        _ error: OnloError,
        previous: ProtectedMobileConfigState,
        allowTokenRefresh: Bool,
        authority: PersistenceAuthority
    ) async throws -> Bool {
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
        try await saveConfigurationState(
            ProtectedMobileConfigState(
                config: previous.config,
                etag: previous.etag,
                retry: .afterBackoff(eligibleAt: eligibleAt, attempt: attempt)
            ),
            authority: authority
        )
        guard attempt < 3 else { return false }
        cancelConfigRetry()
        let expectedSessionId = runtimeSession?.sessionId
        let expectedScope = runtimeSession?.credential.ownerScope
        let expectedGeneration = runtimeSession?.credential.generation
        let expectedToken = runtimeSession?.chatToken
        let expectedAuthority = configAuthority
        let retryID = UUID()
        configRetryID = retryID
        configRetryTask = Task { [weak self] in
            let ns: UInt64
            if delay.isFinite, delay > 0, delay < Double(UInt64.max) / 1_000_000_000 {
                ns = UInt64(delay * 1_000_000_000)
            } else {
                ns = UInt64.max
            }
            try? await Task.sleep(nanoseconds: ns)
            guard !Task.isCancelled else { return }
            await self?.fireConfigurationRetry(
                retryID: retryID,
                authority: expectedAuthority,
                sessionId: expectedSessionId,
                token: expectedToken,
                generation: expectedGeneration,
                scope: expectedScope
            )
        }
        return false
    }

    private static func header(_ name: String, in headers: [String: String]) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    private func cancelConfigRetry() {
        configRetryID = nil
        configRetryTask?.cancel()
        configRetryTask = nil
    }

    private func refreshConfigurationAfterSessionSuccess() async {
        guard !suppressAutomaticConfigRefresh else { return }
        try? await refreshConfiguration()
    }

    private func fireConfigurationRetry(
        retryID: UUID,
        authority: UUID,
        sessionId: String?,
        token: String?,
        generation: Int?,
        scope: OwnerScope?
    ) async {
        guard configRetryID == retryID else { return }
        configRetryID = nil
        configRetryTask = nil
        guard let sessionId, let token, let generation, let scope, let active = runtimeSession,
              configAuthority == authority,
              active.sessionId == sessionId,
              active.chatToken == token,
              active.credential.generation == generation,
              active.credential.ownerScope == scope,
              !active.credential.logoutPending else { return }
        try? await refreshConfiguration()
    }

    private func hasConfigurationAuthority(_ authority: UUID, session: RuntimeSession) -> Bool {
        guard configAuthority == authority, let active = runtimeSession else { return false }
        return active.sessionId == session.sessionId &&
            active.chatToken == session.chatToken &&
            active.credential.generation == session.credential.generation &&
            active.credential.ownerScope == session.credential.ownerScope
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
            await record(operation: "session", code: error.safeCode, requestId: error.requestId, startedAt: startedAt)
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
