import Foundation

public enum OnloMessengerColorMode: Sendable {
    case system
    case light
    case dark
}

/// Host-app presentation policy. Dashboard configuration remains the default;
/// overrides apply only to this presenter and never mutate server configuration.
public struct OnloMessengerOptions: Sendable {
    public var colorMode: OnloMessengerColorMode
    public var allowsImageAttachments: Bool

    public init(
        colorMode: OnloMessengerColorMode = .system,
        allowsImageAttachments: Bool = false
    ) {
        self.colorMode = colorMode
        self.allowsImageAttachments = allowsImageAttachments
    }
}

/// The SDK-owned messenger is available only where UIKit is available. It is
/// deliberately a host-presented controller: initialization never adds an
/// overlay, window, navigation item, or permission prompt.
#if canImport(UIKit)
import AVFoundation
import PhotosUI
import Speech
import UIKit
import UniformTypeIdentifiers

@MainActor
public final class OnloMessengerPresenter: NSObject, UIAdaptivePresentationControllerDelegate {
    private let sdk: OnloSDK
    private let options: OnloMessengerOptions
    private weak var navigationController: UINavigationController?
    private weak var messengerController: OnloMessengerViewController?
    private var invalidatorID: UUID?

    public init(sdk: OnloSDK, options: OnloMessengerOptions = .init()) {
        self.sdk = sdk
        self.options = options
        super.init()
    }

    deinit {
        if let invalidatorID {
            Task { [sdk] in await sdk.unregisterMessengerPresentationInvalidator(invalidatorID) }
        }
    }

    /// Presents the native messenger from a host-selected view controller.
    /// A supplied route is authorised by the native core before content is
    /// fetched or rendered. The host remains responsible for when to call it.
    /// Resolves only after the core has authorised a requested conversation and
    /// the host-selected controller has been attached. Framework adapters call
    /// this async seam rather than treating a loading screen as success.
    public func present(from host: UIViewController, conversationId: String? = nil) async throws {
        clearFinishedPresentation()
        guard navigationController == nil,
              host.presentedViewController == nil,
              host.viewIfLoaded?.window != nil,
              !host.isBeingDismissed else {
            throw OnloError.invalidState
        }
        let gate = PresentationGate()
        let id = await sdk.registerMessengerPresentationInvalidator { [weak self, weak gate] in
            gate?.invalidated = true
            self?.redactAndDismiss()
        }
        invalidatorID = id
        do {
            let intent = try await sdk.present(conversationId: conversationId)
            guard !gate.invalidated,
                  host.viewIfLoaded?.window != nil,
                  !host.isBeingDismissed else { throw OnloError.invalidState }
            let resources = await sdk.messengerPresentationResources()
            guard !gate.invalidated,
                  host.viewIfLoaded?.window != nil,
                  !host.isBeingDismissed else { throw OnloError.invalidState }
            let target: String?
            switch intent { case let .messenger(conversationId): target = conversationId }
            let controller = OnloMessengerViewController(
                sdk: sdk,
                conversationId: target,
                config: resources.config,
                initialHelpTopics: resources.helpTopics,
                faqContentIsCurrent: resources.faqContentIsCurrent,
                options: options
            )
            let navigation = UINavigationController(rootViewController: controller)
            navigation.modalPresentationStyle = .fullScreen
            navigation.presentationController?.delegate = self
            navigationController = navigation
            messengerController = controller
            host.present(navigation, animated: true) { [weak self, weak controller] in
                guard !gate.invalidated else { self?.redactAndDismiss(); return }
                controller?.loadInitialContent()
                self?.navigationController?.presentationController?.delegate = self
            }
        } catch {
            unregisterInvalidator()
            throw error
        }
    }

    public func dismiss(animated: Bool = true) {
        navigationController?.dismiss(animated: animated)
        navigationController = nil
        messengerController = nil
        unregisterInvalidator()
    }

    public func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        navigationController = nil
        messengerController = nil
        unregisterInvalidator()
    }

    private func clearFinishedPresentation() {
        guard let navigationController,
              navigationController.presentingViewController == nil,
              navigationController.viewIfLoaded?.window == nil else { return }
        self.navigationController = nil
        messengerController = nil
        unregisterInvalidator()
    }

    private func redactAndDismiss() {
        messengerController?.redactForAccountBoundary()
        navigationController?.dismiss(animated: false)
        navigationController = nil
        messengerController = nil
        unregisterInvalidator()
    }

    private func unregisterInvalidator() {
        guard let invalidatorID else { return }
        self.invalidatorID = nil
        Task { [sdk] in await sdk.unregisterMessengerPresentationInvalidator(invalidatorID) }
    }
}

@MainActor
private final class OnloMessengerViewController: UIViewController, UITableViewDataSource, UITableViewDelegate, UITextFieldDelegate, PHPickerViewControllerDelegate, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
    private enum Surface {
        case conversations
        case faq
        case helpCenter
    }

    private enum ScreenState {
        case loading
        case inbox([ConversationSummary])
        case transcript(ConversationTranscriptResult)
        case offline
        case failed
    }

    private let sdk: OnloSDK
    private let requestedConversationId: String?
    private let config: MobileConfig?
    private let faqContentIsCurrent: Bool
    private let options: OnloMessengerOptions
    private var screenState: ScreenState = .loading
    private var selectedConversationId: String?
    private var lastInbox: [ConversationSummary] = []
    /// Native-memory-only optimistic and streamed rows. They make a durable
    /// send visible immediately, while the authorised transcript remains the
    /// source of truth after acceptance/completion.
    private var pendingOutgoingMessage: PendingOutgoingMessage?
    private var streamedReplyText = ""
    private var loadTask: Task<Void, Never>?
    private var helpTask: Task<Void, Never>?
    private var sendTask: Task<Void, Never>?
    private var uploadTask: Task<Void, Never>?
    private var realtimeTask: Task<Void, Never>?
    private var uploadedAttachments: [OutboxAttachment] = []
    private var activeSurface: Surface = .conversations
    private var availableSurfaces: [Surface] = []
    private var helpTopics: [HelpCenterTopic]
    private var selectedFAQ: MobileConfig.FAQ?
    private var selectedHelpTopicID: String?
    private var selectedHelpArticle: HelpCenterArticle?
    private var helpIsLoading = false
    private var helpLoadFailed = false
    private let speechRecognizer = SFSpeechRecognizer(locale: Locale.current)
    private let audioEngine = AVAudioEngine()
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var hasAudioTap = false
    private var dictationPrefix = ""
    private var isDictating = false
    private let speechSynthesizer = AVSpeechSynthesizer()
    private var speaksReplies = false

    private let statusLabel = UILabel()
    private let surfaceControl = UISegmentedControl(items: nil)
    private let tableView = UITableView(frame: .zero, style: .plain)
    private let composerRow = UIStackView()
    private let composer = UITextField()
    private let sendButton = UIButton(type: .system)
    private let attachmentButton = UIButton(type: .system)
    private let microphoneButton = UIButton(type: .system)
    private let speakerButton = UIBarButtonItem()
    private lazy var closeButton = UIBarButtonItem(
        barButtonSystemItem: .close,
        target: self,
        action: #selector(close)
    )
    private lazy var conversationBackButton = UIBarButtonItem(
        title: "Back",
        style: .plain,
        target: self,
        action: #selector(showInbox)
    )

    private struct PendingOutgoingMessage {
        let text: String
        var clientMessageId: String?
        var serverMessageId: String?
    }

    private struct RenderedReadPosition: Equatable {
        let conversationId: String
        let messageId: String
    }
    private var lastReadAcknowledgement: RenderedReadPosition?

    private enum VisibleRow {
        case inbox(ConversationSummary)
        case transcript(TranscriptMessage)
        case pendingOutgoing(String)
        case streamedReply(String)
        case faqQuestion(MobileConfig.FAQ)
        case faqAnswer(MobileConfig.FAQ)
        case faqBack
        case helpTopic(HelpCenterTopic)
        case helpArticle(HelpCenterArticleSummary)
        case helpArticleBody(HelpCenterArticle)
        case helpBack(String)
    }

    init(
        sdk: OnloSDK,
        conversationId: String?,
        config: MobileConfig?,
        initialHelpTopics: [HelpCenterTopic],
        faqContentIsCurrent: Bool,
        options: OnloMessengerOptions
    ) {
        self.sdk = sdk
        self.requestedConversationId = conversationId
        self.config = config
        self.helpTopics = initialHelpTopics
        self.faqContentIsCurrent = faqContentIsCurrent
        self.options = options
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = config?.appearance.botName ?? "Support"
        configureHeader()
        navigationItem.leftBarButtonItem = closeButton
        configureVoiceControls()

        statusLabel.numberOfLines = 0
        statusLabel.textAlignment = .center
        statusLabel.font = .preferredFont(forTextStyle: .footnote)
        statusLabel.adjustsFontForContentSizeCategory = true
        statusLabel.accessibilityTraits = .staticText

        configureAvailableSurfaces()
        surfaceControl.addTarget(self, action: #selector(surfaceChanged), for: .valueChanged)
        surfaceControl.accessibilityLabel = "Support section"

        tableView.dataSource = self
        tableView.delegate = self
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "OnloMessengerCell")
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 64
        tableView.accessibilityLabel = "Onlo messenger content"

        composer.borderStyle = .roundedRect
        composer.placeholder = "Write a message"
        composer.delegate = self
        composer.accessibilityLabel = "Message"
        composer.returnKeyType = .send

        sendButton.setTitle("Send", for: .normal)
        sendButton.titleLabel?.font = .preferredFont(forTextStyle: .body)
        sendButton.addTarget(self, action: #selector(send), for: .touchUpInside)
        sendButton.accessibilityLabel = "Send message"
        attachmentButton.setImage(UIImage(systemName: "paperclip"), for: .normal)
        attachmentButton.addTarget(self, action: #selector(selectAttachment), for: .touchUpInside)
        attachmentButton.accessibilityLabel = "Add image"
        microphoneButton.setImage(UIImage(systemName: "mic"), for: .normal)
        microphoneButton.addTarget(self, action: #selector(toggleDictation), for: .touchUpInside)
        microphoneButton.accessibilityLabel = "Start voice input"

        [attachmentButton, microphoneButton, composer, sendButton].forEach {
            composerRow.addArrangedSubview($0)
        }
        composerRow.axis = .horizontal
        composerRow.spacing = 8
        composerRow.alignment = .center
        sendButton.setContentHuggingPriority(.required, for: .horizontal)

        let stack = UIStackView(arrangedSubviews: [surfaceControl, statusLabel, tableView, composerRow])
        stack.axis = .vertical
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        let keyboardBottomConstraint = stack.bottomAnchor.constraint(
            equalTo: view.keyboardLayoutGuide.topAnchor,
            constant: -10
        )
        // UIKit can temporarily report a zero-height presentation container
        // during keyboard/full-screen transitions. Keep the stable layout
        // pinned while allowing that transient system state to resolve without
        // breaking the composer constraints.
        keyboardBottomConstraint.priority = UILayoutPriority(999)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 10),
            keyboardBottomConstraint,
            composer.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
        ])
        applyAppearance()
        render()
    }

    deinit {
        loadTask?.cancel()
        helpTask?.cancel()
        sendTask?.cancel()
        uploadTask?.cancel()
        realtimeTask?.cancel()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        guard isBeingDismissed || navigationController?.isBeingDismissed == true else { return }
        stopDictation()
        speechSynthesizer.stopSpeaking(at: .immediate)
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        guard previousTraitCollection?.userInterfaceStyle != traitCollection.userInterfaceStyle else { return }
        applyAppearance()
        tableView.reloadData()
    }

    func redactForAccountBoundary() {
        loadTask?.cancel(); loadTask = nil
        helpTask?.cancel(); helpTask = nil
        sendTask?.cancel(); sendTask = nil
        uploadTask?.cancel(); uploadTask = nil
        realtimeTask?.cancel(); realtimeTask = nil
        uploadedAttachments.removeAll()
        stopDictation()
        speechSynthesizer.stopSpeaking(at: .immediate)
        selectedConversationId = nil
        pendingOutgoingMessage = nil
        streamedReplyText = ""
        helpTopics.removeAll()
        selectedFAQ = nil
        selectedHelpTopicID = nil
        selectedHelpArticle = nil
        lastInbox.removeAll()
        composer.text = nil
        composer.isEnabled = false
        sendButton.isEnabled = false
        screenState = .failed
        render()
    }

    func loadInitialContent() {
        startRealtimeUpdatesIfNeeded()
        loadTask?.cancel()
        screenState = .loading
        render()
        let intendedConversation = requestedConversationId
        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                if let intendedConversation {
                    let transcript = try await sdk.messengerTranscript(conversationId: intendedConversation)
                    guard !Task.isCancelled else { return }
                    screenState = transcript.map(ScreenState.transcript) ?? .offline
                    selectedConversationId = transcript == nil ? nil : intendedConversation
                    render()
                    if let transcript { await acknowledgeRendered(transcript) }
                } else {
                    let inbox = try await sdk.messengerInbox()
                    guard !Task.isCancelled else { return }
                    lastInbox = inbox
                    screenState = .inbox(inbox)
                    render()
                }
            } catch let error as OnloError {
                guard !Task.isCancelled else { return }
                screenState = error == .requiresNetwork ? .offline : .failed
            } catch {
                guard !Task.isCancelled else { return }
                screenState = .failed
            }
            render()
        }
    }

    private func startRealtimeUpdatesIfNeeded() {
        guard realtimeTask == nil else { return }
        realtimeTask = Task { [weak self] in
            guard let self else { return }
            let updates = await sdk.observeMessengerUpdates()
            for await update in updates {
                guard !Task.isCancelled else { return }
                lastInbox = update.conversations
                if selectedConversationId == update.conversationId,
                   let transcript = update.transcript {
                    applyTranscript(transcript, completed: false)
                    render()
                    await acknowledgeRendered(transcript)
                } else if selectedConversationId == nil {
                    screenState = .inbox(update.conversations)
                    render()
                }
            }
        }
    }

    @objc private func showInbox() {
        loadTask?.cancel()
        selectedConversationId = nil
        pendingOutgoingMessage = nil
        streamedReplyText = ""
        screenState = lastInbox.isEmpty ? .loading : .inbox(lastInbox)
        render()
        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let inbox = try await sdk.messengerInbox()
                guard !Task.isCancelled, selectedConversationId == nil else { return }
                lastInbox = inbox
                screenState = .inbox(inbox)
            } catch let error as OnloError {
                guard !Task.isCancelled, selectedConversationId == nil else { return }
                screenState = error == .requiresNetwork && !lastInbox.isEmpty
                    ? .inbox(lastInbox)
                    : (error == .requiresNetwork ? .offline : .failed)
            } catch {
                guard !Task.isCancelled, selectedConversationId == nil else { return }
                screenState = lastInbox.isEmpty ? .failed : .inbox(lastInbox)
            }
            render()
        }
    }

    private func showConversation(_ conversationId: String) {
        selectedConversationId = conversationId
        screenState = .loading
        render()
        loadTask?.cancel()
        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let transcript = try await sdk.messengerTranscript(conversationId: conversationId)
                guard !Task.isCancelled else { return }
                screenState = transcript.map(ScreenState.transcript) ?? .offline
                render()
                if let transcript { await acknowledgeRendered(transcript) }
            } catch let error as OnloError {
                guard !Task.isCancelled else { return }
                screenState = error == .requiresNetwork ? .offline : .failed
            } catch {
                guard !Task.isCancelled else { return }
                screenState = .failed
            }
            render()
        }
    }

    @objc private func close() {
        stopDictation()
        speechSynthesizer.stopSpeaking(at: .immediate)
        dismiss(animated: true)
    }

    @objc private func send() {
        let message = composer.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let attachments = uploadedAttachments
        guard (!message.isEmpty || !attachments.isEmpty),
              sendTask == nil,
              uploadTask == nil else { return }
        stopDictation()
        speechSynthesizer.stopSpeaking(at: .immediate)
        composer.text = ""
        uploadedAttachments.removeAll()
        composer.isEnabled = false
        sendButton.isEnabled = false
        let optimisticText = message.isEmpty
            ? "\(attachments.count) image\(attachments.count == 1 ? "" : "s")"
            : message
        pendingOutgoingMessage = PendingOutgoingMessage(
            text: optimisticText,
            clientMessageId: nil,
            serverMessageId: nil
        )
        streamedReplyText = ""
        render()
        sendTask = Task { [weak self] in
            guard let self else { return }
            do {
                let stream = try await sdk.sendMessage(message: message, attachments: attachments)
                // A durable enqueue completes before the server accepts the
                // turn. Do not lock the composer while an offline item waits
                // for lifecycle recovery; its stable clientMessageId remains
                // owned by the encrypted native outbox.
                sendTask = nil
                composer.isEnabled = true
                sendButton.isEnabled = true
                render()
                for try await event in stream {
                    guard !Task.isCancelled else { return }
                    switch event {
                    case let .accepted(clientMessageId, messageId, conversationId, _, _, _):
                        pendingOutgoingMessage?.clientMessageId = clientMessageId
                        pendingOutgoingMessage?.serverMessageId = messageId
                        selectedConversationId = conversationId
                        screenState = .loading
                        render()
                        await refreshTranscript(conversationId: conversationId, completed: false)
                    case let .text(content):
                        streamedReplyText.append(content)
                        render()
                    case let .done(conversationId, _, _, _, _):
                        let replyToSpeak = streamedReplyText
                        selectedConversationId = conversationId
                        await refreshTranscript(conversationId: conversationId, completed: true)
                        speakReply(replyToSpeak)
                    case .error:
                        break
                    }
                }
            } catch {
                uploadedAttachments = attachments
                sendTask = nil
                composer.isEnabled = true
                sendButton.isEnabled = true
                statusLabel.text = "Message could not be saved. Try again."
                statusLabel.accessibilityLabel = "Message could not be saved. Try again."
            }
            render()
        }
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool { send(); return false }

    @objc private func surfaceChanged() {
        guard availableSurfaces.indices.contains(surfaceControl.selectedSegmentIndex) else { return }
        let surface = availableSurfaces[surfaceControl.selectedSegmentIndex]
        activeSurface = surface
        if surface != .faq { selectedFAQ = nil }
        stopDictation()
        render()
    }

    private func configureAvailableSurfaces() {
        availableSurfaces = [.conversations]
        if faqContentIsCurrent, !configuredFAQs.isEmpty {
            availableSurfaces.append(.faq)
        }
        if !helpTopics.isEmpty { availableSurfaces.append(.helpCenter) }
        surfaceControl.removeAllSegments()
        for (index, surface) in availableSurfaces.enumerated() {
            let title: String
            switch surface {
            case .conversations: title = "Chats"
            case .faq: title = "FAQ"
            case .helpCenter: title = "Help"
            }
            surfaceControl.insertSegment(withTitle: title, at: index, animated: false)
        }
        surfaceControl.selectedSegmentIndex = 0
        surfaceControl.isHidden = availableSurfaces.count == 1
    }

    private func loadHelpArticle(_ articleId: String) {
        helpTask?.cancel()
        helpIsLoading = true
        helpLoadFailed = false
        render()
        helpTask = Task { [weak self] in
            guard let self else { return }
            do {
                let article = try await sdk.messengerHelpCenterArticle(articleId: articleId)
                guard !Task.isCancelled else { return }
                selectedHelpArticle = article
                helpLoadFailed = false
            } catch {
                guard !Task.isCancelled else { return }
                helpLoadFailed = true
            }
            helpIsLoading = false
            render()
        }
    }

    @objc private func toggleDictation() {
        if isDictating {
            stopDictation()
            return
        }
        Task { [weak self] in
            guard let self else { return }
            let permissionsGranted = await requestVoicePermissions()
            guard permissionsGranted else {
                showVoiceError("Enable microphone and speech recognition access in Settings to use voice input.")
                return
            }
            startDictation()
        }
    }

    private func requestVoicePermissions() async -> Bool {
        let speechStatus: SFSpeechRecognizerAuthorizationStatus
        switch SFSpeechRecognizer.authorizationStatus() {
        case .notDetermined:
            speechStatus = await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
            }
        case let current:
            speechStatus = current
        }
        guard speechStatus == .authorized else { return false }

        let audioSession = AVAudioSession.sharedInstance()
        switch audioSession.recordPermission {
        case .granted:
            return true
        case .undetermined:
            return await withCheckedContinuation { continuation in
                audioSession.requestRecordPermission { continuation.resume(returning: $0) }
            }
        case .denied:
            return false
        @unknown default:
            return false
        }
    }

    private func startDictation() {
        guard voiceIsAvailable,
              speechRecognizer?.isAvailable == true,
              !isDictating else {
            showVoiceError("Voice input is temporarily unavailable.")
            return
        }
        stopDictation()

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        recognitionRequest = request
        dictationPrefix = composer.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        let inputNode = audioEngine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)
        guard recordingFormat.sampleRate > 0 else {
            showVoiceError("Voice input is temporarily unavailable.")
            return
        }
        inputNode.installTap(onBus: 0, bufferSize: 1_024, format: recordingFormat) { buffer, _ in
            request.append(buffer)
        }
        hasAudioTap = true

        recognitionTask = speechRecognizer?.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor [weak self] in
                guard let self, isDictating else { return }
                if let result {
                    let transcript = result.bestTranscription.formattedString
                    composer.text = [dictationPrefix, transcript]
                        .filter { !$0.isEmpty }
                        .joined(separator: " ")
                    renderComposerAvailability()
                    if result.isFinal { stopDictation() }
                } else if error != nil {
                    stopDictation()
                    showVoiceError("Voice input stopped. You can continue typing.")
                }
            }
        }

        do {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.playAndRecord, mode: .measurement, options: [.duckOthers, .defaultToSpeaker])
            try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
            audioEngine.prepare()
            try audioEngine.start()
            isDictating = true
            updateVoiceControls()
            renderComposerAvailability()
        } catch {
            stopDictation()
            showVoiceError("Voice input is temporarily unavailable.")
        }
    }

    private func stopDictation() {
        if audioEngine.isRunning { audioEngine.stop() }
        if hasAudioTap {
            audioEngine.inputNode.removeTap(onBus: 0)
            hasAudioTap = false
        }
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionRequest = nil
        recognitionTask = nil
        isDictating = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        updateVoiceControls()
        renderComposerAvailability()
    }

    @objc private func toggleSpokenReplies() {
        guard voiceIsAvailable else { return }
        speaksReplies.toggle()
        if !speaksReplies {
            speechSynthesizer.stopSpeaking(at: .immediate)
        }
        updateVoiceControls()
    }

    private func speakReply(_ reply: String) {
        let text = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard voiceIsAvailable, speaksReplies, !text.isEmpty else { return }
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: Locale.preferredLanguages.first)
        speechSynthesizer.stopSpeaking(at: .immediate)
        speechSynthesizer.speak(utterance)
    }

    private func configureVoiceControls() {
        speakerButton.target = self
        speakerButton.action = #selector(toggleSpokenReplies)
        navigationItem.rightBarButtonItem = voiceIsAvailable ? speakerButton : nil
        updateVoiceControls()
    }

    private func updateVoiceControls() {
        microphoneButton.isHidden = !voiceIsAvailable
        microphoneButton.setImage(UIImage(systemName: isDictating ? "mic.fill" : "mic"), for: .normal)
        microphoneButton.accessibilityLabel = isDictating ? "Stop voice input" : "Start voice input"
        speakerButton.image = UIImage(systemName: speaksReplies ? "speaker.wave.2.fill" : "speaker.wave.2")
        speakerButton.accessibilityLabel = speaksReplies ? "Disable spoken replies" : "Enable spoken replies"
        speakerButton.accessibilityValue = speaksReplies ? "On" : "Off"
    }

    private var voiceIsAvailable: Bool {
        config?.features.voice == true
    }

    private func showVoiceError(_ message: String) {
        statusLabel.text = message
        statusLabel.accessibilityLabel = message
    }

    @objc private func selectAttachment() {
        guard attachmentsAreAvailable, selectedConversationId != nil, uploadTask == nil else { return }
        let sheet = UIAlertController(title: "Add image", message: nil, preferredStyle: .actionSheet)
        sheet.addAction(UIAlertAction(title: "Photo Library", style: .default) { [weak self] _ in
            self?.presentPhotoPicker()
        })
        if UIImagePickerController.isSourceTypeAvailable(.camera) {
            sheet.addAction(UIAlertAction(title: "Camera", style: .default) { [weak self] _ in
                self?.requestCameraAndPresent()
            })
        }
        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        sheet.popoverPresentationController?.sourceView = attachmentButton
        sheet.popoverPresentationController?.sourceRect = attachmentButton.bounds
        present(sheet, animated: true)
    }

    private func presentPhotoPicker() {
        var pickerConfig = PHPickerConfiguration(photoLibrary: .shared())
        pickerConfig.filter = .images
        pickerConfig.selectionLimit = max(1, maximumImagesPerMessage - uploadedAttachments.count)
        pickerConfig.preferredAssetRepresentationMode = .current
        let picker = PHPickerViewController(configuration: pickerConfig)
        picker.delegate = self
        present(picker, animated: true)
    }

    private func requestCameraAndPresent() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            presentCamera()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                Task { @MainActor in
                    guard granted else {
                        self?.showMediaError("Camera access was not granted.")
                        return
                    }
                    self?.presentCamera()
                }
            }
        case .denied, .restricted:
            showMediaError("Enable camera access in Settings to take a photo.")
        @unknown default:
            showMediaError("Camera is unavailable.")
        }
    }

    private func presentCamera() {
        guard UIImagePickerController.isSourceTypeAvailable(.camera) else {
            showMediaError("Camera is unavailable.")
            return
        }
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.mediaTypes = [UTType.image.identifier]
        picker.delegate = self
        present(picker, animated: true)
    }

    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: true)
        guard !results.isEmpty else { return }
        let remaining = maximumImagesPerMessage - uploadedAttachments.count
        let providers = results.prefix(remaining).map(\.itemProvider)
        uploadTask = Task { [weak self] in
            guard let self else { return }
            statusLabel.text = "Preparing images"
            renderComposerAvailability()
            do {
                var images: [PreparedImage] = []
                for provider in providers {
                    let data = try await loadImageData(from: provider)
                    images.append(try prepareImage(data))
                }
                try await upload(images)
            } catch {
                showMediaError("Image could not be added.")
            }
            uploadTask = nil
            render()
        }
    }

    func imagePickerController(
        _ picker: UIImagePickerController,
        didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
    ) {
        picker.dismiss(animated: true)
        guard let image = info[.originalImage] as? UIImage else {
            showMediaError("Image could not be added.")
            return
        }
        uploadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let prepared = try prepareImage(image)
                try await upload([prepared])
            } catch {
                showMediaError("Image could not be added.")
            }
            uploadTask = nil
            render()
        }
    }

    func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
        picker.dismiss(animated: true)
    }

    private func loadImageData(from provider: NSItemProvider) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, error in
                if let data, data.count <= OnloProtocol.maximumSourceImageBytes {
                    continuation.resume(returning: data)
                } else {
                    continuation.resume(throwing: error ?? OnloError.invalidConfiguration)
                }
            }
        }
    }

    private func prepareImage(_ data: Data) throws -> PreparedImage {
        guard data.count <= OnloProtocol.maximumSourceImageBytes else {
            throw OnloError.invalidConfiguration
        }
        guard let image = UIImage(data: data) else { throw OnloError.invalidConfiguration }
        return try prepareImage(image)
    }

    private func prepareImage(_ image: UIImage) throws -> PreparedImage {
        // Drawing into a fresh bitmap applies orientation, strips metadata,
        // preserves aspect ratio, and bounds decoded dimensions. It never
        // crops customer content.
        var candidate = resizedImageWithinSafetyLimits(image)
        for _ in 0..<6 {
            for quality in [0.9, 0.82, 0.74] {
                if let data = candidate.jpegData(compressionQuality: quality),
                   data.count <= maximumImageBytes {
                    return PreparedImage(
                        data: data,
                        mimeType: .jpeg,
                        filename: "onlo-image-\(UUID().uuidString.lowercased()).jpg"
                    )
                }
            }
            candidate = renderedImage(candidate, scale: 0.82)
        }
        throw OnloError.invalidConfiguration
    }

    private func resizedImageWithinSafetyLimits(_ image: UIImage) -> UIImage {
        let width = image.cgImage.map { CGFloat($0.width) } ?? image.size.width * image.scale
        let height = image.cgImage.map { CGFloat($0.height) } ?? image.size.height * image.scale
        guard width > 0, height > 0 else { return image }
        let dimensionScale = min(
            1,
            CGFloat(OnloProtocol.maximumImageDimension) / width,
            CGFloat(OnloProtocol.maximumImageDimension) / height
        )
        let pixelScale = sqrt(CGFloat(OnloProtocol.maximumImagePixels) / (width * height))
        return renderedImage(image, scale: min(dimensionScale, pixelScale))
    }

    private func renderedImage(_ image: UIImage, scale: CGFloat) -> UIImage {
        let width = image.cgImage.map { CGFloat($0.width) } ?? image.size.width * image.scale
        let height = image.cgImage.map { CGFloat($0.height) } ?? image.size.height * image.scale
        let target = CGSize(
            width: max(1, (width * min(1, scale)).rounded()),
            height: max(1, (height * min(1, scale)).rounded())
        )
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: target, format: format).image { context in
            UIColor.white.setFill()
            context.cgContext.fill(CGRect(origin: .zero, size: target))
            image.draw(in: CGRect(origin: .zero, size: target))
        }
    }

    private func upload(_ images: [PreparedImage]) async throws {
        guard let conversationId = selectedConversationId else { throw OnloError.invalidState }
        for (index, image) in images.enumerated() {
            guard !Task.isCancelled else { return }
            statusLabel.text = "Uploading image \(index + 1) of \(images.count)"
            let attachment = try await sdk.uploadImage(
                conversationId: conversationId,
                data: image.data,
                mimeType: image.mimeType,
                filename: image.filename
            )
            guard selectedConversationId == conversationId else { throw OnloError.invalidState }
            uploadedAttachments.append(attachment)
        }
    }

    private func showMediaError(_ message: String) {
        statusLabel.text = message
        statusLabel.accessibilityLabel = message
    }

    private func render() {
        composerRow.isHidden = activeSurface != .conversations
        navigationItem.leftBarButtonItems = activeSurface == .conversations && selectedConversationId != nil
            ? [closeButton, conversationBackButton]
            : [closeButton]
        navigationItem.rightBarButtonItem = activeSurface == .conversations && voiceIsAvailable
            ? speakerButton
            : nil
        if activeSurface == .faq {
            let faqs = configuredFAQs
            statusLabel.text = selectedFAQ?.question ?? (faqs.isEmpty ? "No FAQs are available yet." : "")
            statusLabel.accessibilityLabel = selectedFAQ == nil
                ? (faqs.isEmpty ? statusLabel.text : "Frequently asked questions")
                : "Frequently asked question"
            tableView.reloadData()
            return
        }
        if activeSurface == .helpCenter {
            if helpIsLoading {
                statusLabel.text = selectedHelpArticle == nil ? "Loading Help Center" : "Loading article"
            } else if helpLoadFailed {
                statusLabel.text = "Help Center is temporarily unavailable."
            } else if helpTopics.isEmpty {
                statusLabel.text = "No Help Center articles are available yet."
            } else {
                statusLabel.text = ""
            }
            statusLabel.accessibilityLabel = statusLabel.text
            tableView.reloadData()
            return
        }
        switch screenState {
        case .loading:
            statusLabel.text = pendingOutgoingMessage == nil ? "Loading support" : "Message queued"
            statusLabel.accessibilityLabel = statusLabel.text
            composer.isHidden = false; sendButton.isHidden = false
        case .inbox(let conversations):
            if pendingOutgoingMessage != nil || !streamedReplyText.isEmpty {
                statusLabel.text = "Message queued"
            } else {
                statusLabel.text = conversations.isEmpty
                    ? (config?.appearance.greeting.nilIfEmpty ?? "No conversations yet")
                    : "Conversations"
            }
            statusLabel.accessibilityLabel = statusLabel.text
            composer.isHidden = false; sendButton.isHidden = false
        case .transcript:
            statusLabel.text = ""
            statusLabel.accessibilityLabel = "Conversation"
            composer.isHidden = false; sendButton.isHidden = false
        case .offline:
            statusLabel.text = "Offline. Messages are saved and will retry when connected."
            statusLabel.accessibilityLabel = statusLabel.text
            composer.isHidden = false; sendButton.isHidden = false
        case .failed:
            statusLabel.text = "Support is temporarily unavailable. Try again later."
            statusLabel.accessibilityLabel = statusLabel.text
            composer.isHidden = true; sendButton.isHidden = true
        }
        renderComposerAvailability()
        tableView.reloadData()
    }

    private var attachmentsAreAvailable: Bool {
        false
    }

    private var maximumImagesPerMessage: Int {
        config?.mediaPolicy.effectiveMaximumImagesPerMessage ?? 0
    }

    private var maximumImageBytes: Int {
        config?.mediaPolicy.effectiveMaximumImageBytes ?? 0
    }

    private func renderComposerAvailability() {
        guard activeSurface == .conversations else { return }
        attachmentButton.isHidden = !attachmentsAreAvailable || selectedConversationId == nil
        attachmentButton.isEnabled = uploadTask == nil &&
            !isDictating &&
            uploadedAttachments.count < maximumImagesPerMessage
        microphoneButton.isEnabled = voiceIsAvailable &&
            (isDictating || (sendTask == nil && uploadTask == nil))
        let suffix = uploadedAttachments.isEmpty ? "" : " · \(uploadedAttachments.count) image\(uploadedAttachments.count == 1 ? "" : "s")"
        attachmentButton.accessibilityValue = uploadedAttachments.isEmpty
            ? nil
            : "\(uploadedAttachments.count) selected"
        if case .failed = screenState { return }
        if uploadTask != nil || isDictating {
            composer.isEnabled = false
            sendButton.isEnabled = false
        } else if sendTask == nil {
            composer.isEnabled = true
            sendButton.isEnabled = !(composer.text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) ||
                !uploadedAttachments.isEmpty
        }
        composer.placeholder = "Write a message\(suffix)"
    }

    private func applyAppearance() {
        let useDark: Bool
        switch options.colorMode {
        case .light: useDark = false
        case .dark: useDark = config?.appearance.dark.enabled == true
        case .system:
            useDark = traitCollection.userInterfaceStyle == .dark &&
                config?.appearance.dark.enabled == true
        }
        let palette = MessengerPalette(config: config, useDark: useDark, color: color)
        overrideUserInterfaceStyle = useDark ? .dark : .light
        view.backgroundColor = palette.background
        tableView.backgroundColor = palette.background
        statusLabel.textColor = palette.incomingText
        sendButton.tintColor = palette.accent
        attachmentButton.tintColor = palette.accent
        microphoneButton.tintColor = palette.accent
        speakerButton.tintColor = palette.accent
        surfaceControl.selectedSegmentTintColor = palette.accent
        navigationController?.navigationBar.tintColor = palette.accent
    }

    private func configureHeader() {
        guard let appearance = config?.appearance else {
            navigationItem.prompt = nil
            return
        }
        let avatar: UIView
        if appearance.headerAvatar.mode == .image,
           let data = appearance.headerAvatar.data,
           let image = image(fromDataURL: data) {
            let imageView = UIImageView(image: image)
            imageView.contentMode = .scaleAspectFill
            imageView.isAccessibilityElement = true
            imageView.accessibilityLabel = "\(appearance.botName) avatar"
            avatar = imageView
        } else {
            let initials = UILabel()
            initials.text = appearance.headerAvatar.text
            initials.textAlignment = .center
            initials.font = .preferredFont(forTextStyle: .caption1)
            initials.adjustsFontForContentSizeCategory = true
            initials.backgroundColor = color(appearance.accent) ?? .systemBlue
            initials.textColor = .white
            initials.accessibilityLabel = "\(appearance.botName) avatar"
            avatar = initials
        }
        avatar.layer.cornerRadius = 16
        avatar.clipsToBounds = true
        avatar.widthAnchor.constraint(equalToConstant: 32).isActive = true
        avatar.heightAnchor.constraint(equalToConstant: 32).isActive = true

        let name = UILabel()
        name.text = appearance.botName
        name.font = .preferredFont(forTextStyle: .headline)
        let subtitle = UILabel()
        subtitle.text = appearance.botSubtitle
        subtitle.font = .preferredFont(forTextStyle: .caption1)
        subtitle.textColor = .secondaryLabel
        let labels = UIStackView(arrangedSubviews: [name, subtitle])
        labels.axis = .vertical
        labels.alignment = .leading
        labels.spacing = 0
        let header = UIStackView(arrangedSubviews: [avatar, labels])
        header.axis = .horizontal
        header.alignment = .center
        header.spacing = 8
        navigationItem.titleView = header
    }

    private func image(fromDataURL value: String) -> UIImage? {
        guard value.hasPrefix("data:image/"),
              let comma = value.firstIndex(of: ","),
              value[..<comma].hasSuffix(";base64"),
              let data = Data(base64Encoded: String(value[value.index(after: comma)...]))
        else { return nil }
        return UIImage(data: data)
    }

    private func color(_ hex: String?) -> UIColor? {
        guard let hex else { return nil }
        let value = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        let raw = value.hasPrefix("#") ? String(value.dropFirst()) : value
        guard raw.count == 6, let number = UInt32(raw, radix: 16) else { return nil }
        return UIColor(
            red: CGFloat((number >> 16) & 0xff) / 255,
            green: CGFloat((number >> 8) & 0xff) / 255,
            blue: CGFloat(number & 0xff) / 255,
            alpha: 1
        )
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        visibleRows.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "OnloMessengerCell", for: indexPath)
        cell.textLabel?.numberOfLines = 0
        cell.textLabel?.font = .preferredFont(forTextStyle: .body)
        cell.textLabel?.attributedText = nil
        cell.backgroundColor = activePalette.background
        cell.textLabel?.textColor = activePalette.incomingText
        cell.accessoryView = nil
        cell.selectionStyle = .default
        switch visibleRows[indexPath.row] {
        case let .inbox(item):
            cell.textLabel?.text = item.title
            cell.accessibilityLabel = item.unreadCount > 0
                ? "\(item.title), \(item.unreadCount) unread"
                : item.title
            cell.accessoryView = item.unreadCount > 0 ? badgeLabel(item.unreadCount) : nil
            cell.accessoryType = .disclosureIndicator
        case let .transcript(message):
            cell.textLabel?.text = message.text
            cell.accessibilityLabel = "\(message.role): \(message.text)"
            cell.accessoryType = .none
            let palette = activePalette
            let outgoing = message.role.lowercased() == "user"
            cell.backgroundColor = outgoing ? palette.outgoing : palette.incoming
            cell.textLabel?.textColor = outgoing ? palette.outgoingText : palette.incomingText
        case let .pendingOutgoing(text):
            cell.textLabel?.text = text
            cell.accessibilityLabel = "You: \(text), queued"
            cell.accessoryType = .none
            cell.backgroundColor = activePalette.outgoing
            cell.textLabel?.textColor = activePalette.outgoingText
        case let .streamedReply(text):
            cell.textLabel?.text = text
            cell.accessibilityLabel = "Support: \(text), replying"
            cell.accessoryType = .none
            cell.backgroundColor = activePalette.incoming
            cell.textLabel?.textColor = activePalette.incomingText
        case let .faqQuestion(faq):
            cell.textLabel?.text = faq.question
            cell.accessibilityLabel = faq.question
            cell.accessoryType = .disclosureIndicator
            cell.accessoryView = nil
        case let .faqAnswer(faq):
            cell.textLabel?.text = faq.answer
            cell.accessibilityLabel = faq.answer
            cell.accessoryType = .none
            cell.accessoryView = nil
            cell.selectionStyle = .none
        case .faqBack:
            cell.textLabel?.text = "‹ All questions"
            cell.accessibilityLabel = "Back to all questions"
            cell.accessoryType = .none
            cell.accessoryView = nil
        case let .helpTopic(topic):
            cell.textLabel?.text = "\(topic.name) (\(topic.count))"
            cell.accessibilityLabel = "\(topic.name), \(topic.count) articles"
            cell.accessoryType = .disclosureIndicator
            cell.accessoryView = nil
        case let .helpArticle(article):
            cell.textLabel?.text = article.title
            cell.accessibilityLabel = article.title
            cell.accessoryType = .disclosureIndicator
            cell.accessoryView = nil
        case let .helpArticleBody(article):
            let rendered = renderedHelpArticle(article)
            cell.textLabel?.attributedText = rendered
            cell.accessibilityLabel = rendered.string
            cell.accessoryType = .none
            cell.accessoryView = nil
            cell.selectionStyle = .none
        case let .helpBack(label):
            cell.textLabel?.text = "‹ \(label)"
            cell.accessibilityLabel = "Back to \(label)"
            cell.accessoryType = .none
            cell.accessoryView = nil
        }
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        switch visibleRows[indexPath.row] {
        case let .inbox(item):
            showConversation(item.id)
        case let .helpTopic(topic):
            selectedHelpTopicID = topic.id
            selectedHelpArticle = nil
            render()
        case let .helpArticle(article):
            loadHelpArticle(article.id)
        case let .faqQuestion(faq):
            selectedFAQ = faq
            render()
        case .faqBack:
            selectedFAQ = nil
            render()
        case .helpBack:
            if selectedHelpArticle != nil {
                selectedHelpArticle = nil
            } else {
                selectedHelpTopicID = nil
            }
            helpLoadFailed = false
            render()
        case .transcript, .pendingOutgoing, .streamedReply, .faqAnswer, .helpArticleBody:
            break
        }
        tableView.deselectRow(at: indexPath, animated: true)
    }

    private var visibleRows: [VisibleRow] {
        if activeSurface == .faq {
            if let selectedFAQ {
                return [.faqBack, .faqAnswer(selectedFAQ)]
            }
            return configuredFAQs.map(VisibleRow.faqQuestion)
        }
        if activeSurface == .helpCenter {
            if let article = selectedHelpArticle {
                return [.helpBack(selectedHelpTopic?.name ?? "articles"), .helpArticleBody(article)]
            }
            if let topic = selectedHelpTopic {
                return [.helpBack("topics")] + topic.articles.map(VisibleRow.helpArticle)
            }
            return helpTopics.map(VisibleRow.helpTopic)
        }
        switch screenState {
        case let .inbox(items):
            if selectedConversationId == nil, pendingOutgoingMessage != nil || !streamedReplyText.isEmpty {
                return transientRows
            }
            return items.map(VisibleRow.inbox)
        case let .transcript(transcript):
            return transcript.messages.map(VisibleRow.transcript) + transientRows
        case .loading, .offline, .failed:
            return transientRows
        }
    }

    private var transientRows: [VisibleRow] {
        var rows: [VisibleRow] = []
        if let pendingOutgoingMessage { rows.append(.pendingOutgoing(pendingOutgoingMessage.text)) }
        if !streamedReplyText.isEmpty { rows.append(.streamedReply(streamedReplyText)) }
        return rows
    }

    private var configuredFAQs: [MobileConfig.FAQ] {
        guard config?.features.faqButton.enabled == true else { return [] }
        return (config?.content.faqs ?? []).filter {
            !$0.question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                !($0.answer ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private var selectedHelpTopic: HelpCenterTopic? {
        guard let selectedHelpTopicID else { return nil }
        return helpTopics.first { $0.id == selectedHelpTopicID }
    }

    private func renderedHelpArticle(_ article: HelpCenterArticle) -> NSAttributedString {
        let title = NSMutableAttributedString(
            string: "\(article.title)\n\n",
            attributes: [.font: UIFont.preferredFont(forTextStyle: .headline)]
        )
        let body: NSAttributedString
        if article.body.range(
            of: #"<\/?(p|div|h[1-6]|ul|ol|li|strong|em|a|code|pre|br|span)\b"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil,
           let data = article.body.data(using: .utf8),
           let rendered = try? NSAttributedString(
               data: data,
               options: [
                   .documentType: NSAttributedString.DocumentType.html,
                   .characterEncoding: String.Encoding.utf8.rawValue,
               ],
               documentAttributes: nil
           ) {
            body = rendered
        } else {
            body = NSAttributedString(
                string: article.body,
                attributes: [.font: UIFont.preferredFont(forTextStyle: .body)]
            )
        }
        title.append(body)
        return title
    }

    private func refreshTranscript(conversationId: String, completed: Bool) async {
        do {
            guard let transcript = try await sdk.messengerTranscript(conversationId: conversationId) else {
                render()
                return
            }
            applyTranscript(transcript, completed: completed)
        } catch {
            // Keep the already-rendered native-memory rows. The durable outbox
            // and authorised transcript reconciliation remain owned by the SDK.
        }
        render()
        if case let .transcript(transcript) = screenState {
            await acknowledgeRendered(transcript)
        }
    }

    private func applyTranscript(
        _ transcript: ConversationTranscriptResult,
        completed: Bool
    ) {
        screenState = .transcript(transcript)
        if let serverMessageId = pendingOutgoingMessage?.serverMessageId,
           transcript.messages.contains(where: { $0.id == serverMessageId }) {
            pendingOutgoingMessage = nil
        }
        if completed { streamedReplyText = "" }
    }

    private func acknowledgeRendered(_ transcript: ConversationTranscriptResult) async {
        guard let latest = transcript.messages.max(by: { $0.timestamp < $1.timestamp }) else { return }
        let position = RenderedReadPosition(
            conversationId: transcript.conversation.id,
            messageId: latest.id
        )
        guard position != lastReadAcknowledgement else { return }
        lastReadAcknowledgement = position
        do {
            try await sdk.acknowledgeRenderedConversation(
                conversationId: position.conversationId,
                throughMessageId: position.messageId
            )
        } catch {
            if lastReadAcknowledgement == position {
                lastReadAcknowledgement = nil
            }
        }
    }

    private func badgeLabel(_ count: Int) -> UILabel {
        let badge = UILabel()
        badge.text = String(count)
        badge.textAlignment = .center
        badge.font = .preferredFont(forTextStyle: .caption1)
        badge.textColor = .white
        badge.backgroundColor = activePalette.accent
        badge.layer.cornerRadius = 10
        badge.clipsToBounds = true
        badge.frame.size = CGSize(width: 28, height: 20)
        badge.accessibilityElementsHidden = true
        return badge
    }

    private var activePalette: MessengerPalette {
        let useDark = overrideUserInterfaceStyle == .dark
        return MessengerPalette(config: config, useDark: useDark, color: color)
    }
}

private struct PreparedImage {
    let data: Data
    let mimeType: ImageMimeType
    let filename: String
}

private struct MessengerPalette {
    let accent: UIColor
    let background: UIColor
    let outgoing: UIColor
    let outgoingText: UIColor
    let incoming: UIColor
    let incomingText: UIColor

    init(config: MobileConfig?, useDark: Bool, color: (String?) -> UIColor?) {
        let appearance = config?.appearance
        accent = color(appearance?.accent) ?? .systemBlue
        if useDark, let dark = appearance?.dark, dark.enabled {
            background = color(dark.background) ?? .systemBackground
            outgoing = color(dark.outgoing) ?? .systemBlue
            outgoingText = color(dark.outgoingText) ?? .white
            incoming = color(dark.incoming) ?? .secondarySystemBackground
            incomingText = color(dark.incomingText) ?? .label
        } else {
            background = color(appearance?.light.background) ?? .systemBackground
            outgoing = color(appearance?.light.outgoing) ?? .systemBlue
            outgoingText = color(appearance?.light.outgoingText) ?? .white
            incoming = color(appearance?.light.incoming) ?? .secondarySystemBackground
            incomingText = color(appearance?.light.incomingText) ?? .label
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

@MainActor
private final class PresentationGate {
    var invalidated = false
}
#endif
