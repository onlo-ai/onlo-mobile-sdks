import Foundation

public enum OnloMessengerColorMode: Sendable {
    case system
    case light
    case dark
}

public enum OnloMessengerPresentationMode: Sendable, Equatable {
    /// An inset messenger surface contained within the host application's safe area.
    case contained

    /// A host-presented full-screen controller that still respects safe areas.
    case fullScreen
}

/// Host-app presentation policy. Dashboard configuration remains the default;
/// overrides apply only to this presenter and never mutate server configuration.
public struct OnloMessengerOptions: Sendable {
    public var colorMode: OnloMessengerColorMode
    public var allowsImageAttachments: Bool
    public var presentationMode: OnloMessengerPresentationMode

    public init(
        colorMode: OnloMessengerColorMode = .system,
        allowsImageAttachments: Bool = true,
        presentationMode: OnloMessengerPresentationMode = .contained
    ) {
        self.colorMode = colorMode
        self.allowsImageAttachments = allowsImageAttachments
        self.presentationMode = presentationMode
    }
}

enum MessengerBackAction: Equatable {
    case dismiss
    case returnHome
}

func messengerBackAction(isHome: Bool) -> MessengerBackAction {
    isHome ? .dismiss : .returnHome
}

struct MessengerComposerInsertion: Equatable {
    let text: String
    let cursorOffset: Int
}

func messengerCodeInsertion(selectedText: String) -> MessengerComposerInsertion {
    if selectedText.isEmpty {
        return MessengerComposerInsertion(text: "```\n\n```", cursorOffset: 4)
    }
    let text = "```\n\(selectedText)\n```"
    return MessengerComposerInsertion(text: text, cursorOffset: text.utf16.count)
}

func messengerMarkdownLink(label: String, url: String) -> String {
    let trimmedURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
    let trimmedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
    return "[\(trimmedLabel.isEmpty ? trimmedURL : trimmedLabel)](\(trimmedURL))"
}

enum MessengerMessageAlignment: Equatable {
    case leading
    case trailing
}

func messengerMessageAlignment(role: String) -> MessengerMessageAlignment {
    role.caseInsensitiveCompare("user") == .orderedSame ? .trailing : .leading
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
                identifiedFirstName: resources.identifiedFirstName,
                options: options
            )
            let navigation = UINavigationController(rootViewController: controller)
            // The host owns the screen; `contained` controls the Messenger
            // surface inside it. A custom modal added a second inset frame and
            // dimmed the host, making the SDK look like a floating sheet.
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
private final class OnloMessengerViewController: UIViewController, UITableViewDataSource, UITableViewDelegate, UITextViewDelegate, PHPickerViewControllerDelegate, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
    private enum Surface {
        case home
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
    private let identifiedFirstName: String?
    private let options: OnloMessengerOptions
    private var screenState: ScreenState = .loading
    private var selectedConversationId: String?
    private var selectedSessionId: String?
    private var lastInbox: [ConversationSummary] = []
    /// Native-memory-only optimistic and streamed rows. They make a durable
    /// send visible immediately, while the authorised transcript remains the
    /// source of truth after acceptance/completion.
    private var pendingOutgoingMessage: PendingOutgoingMessage?
    private var streamedReplyText = ""
    private var isAwaitingReply = false
    private var loadTask: Task<Void, Never>?
    private var helpTask: Task<Void, Never>?
    private var sendTask: Task<Void, Never>?
    private var uploadTask: Task<Void, Never>?
    private var realtimeTask: Task<Void, Never>?
    private var uploadedAttachments: [OutboxAttachment] = []
    private var activeSurface: Surface = .home
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
    private let tableView = UITableView(frame: .zero, style: .plain)
    private let messengerSurface = UIStackView()
    private let composerArea = UIView()
    private let composerTopDivider = UIView()
    private let composerRow = UIStackView()
    private let composer = UITextView()
    private let composerPlaceholder = UILabel()
    private let sendButton = UIButton(type: .system)
    private let attachmentButton = UIButton(type: .system)
    private let codeButton = UIButton(type: .system)
    private let linkButton = UIButton(type: .system)
    private let microphoneButton = UIButton(type: .system)
    private let speakerButton = UIButton(type: .system)
    private let footerArea = UIView()
    private let footerBrand = UIStackView()
    private let footerPrefixLabel = UILabel()
    private let footerMark = OnloMarkView()
    private let footerNameLabel = UILabel()
    private let footerDivider = UIView()
    private let headerArea = UIStackView()
    private let headerDivider = UIView()
    private let headerBackButton = UIButton(type: .system)
    private let headerAvatarHost = UIView()
    private let headerNameLabel = UILabel()
    private let headerSubtitleLabel = UILabel()
    private let headerStatusDot = UIView()
    private let closeButton = UIButton(type: .system)
    private let refreshButton = UIButton(type: .system)
    private var composerHeightConstraint: NSLayoutConstraint?
    private var isPlatformConnected = false

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
        case homeGreeting
        case homeFAQ(MobileConfig.FAQ)
        case helpShortcut
        case transcript(TranscriptMessage)
        case pendingOutgoing(String)
        case typingIndicator
        case streamedReply(String)
        case faqQuestion(MobileConfig.FAQ)
        case faqAnswer(MobileConfig.FAQ)
        case faqBack
        case helpTopic(HelpCenterTopic)
        case helpArticle(HelpCenterArticleSummary)
        case helpArticleBody(HelpCenterArticle)
        case helpBack(String)
    }

    private struct TableSection {
        let title: String?
        let actionTitle: String?
        let action: Selector?
        let rows: [VisibleRow]
    }

    init(
        sdk: OnloSDK,
        conversationId: String?,
        config: MobileConfig?,
        initialHelpTopics: [HelpCenterTopic],
        faqContentIsCurrent: Bool,
        identifiedFirstName: String?,
        options: OnloMessengerOptions
    ) {
        self.sdk = sdk
        self.requestedConversationId = conversationId
        self.config = config
        self.helpTopics = initialHelpTopics
        self.faqContentIsCurrent = faqContentIsCurrent
        self.identifiedFirstName = identifiedFirstName
        self.options = options
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = config?.appearance.botName ?? "Support"
        configureHeaderArea()
        configureHeader()
        configureVoiceControls()

        statusLabel.numberOfLines = 0
        statusLabel.textAlignment = .center
        statusLabel.font = .preferredFont(forTextStyle: .footnote)
        statusLabel.adjustsFontForContentSizeCategory = true
        statusLabel.accessibilityTraits = .staticText

        tableView.dataSource = self
        tableView.delegate = self
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "OnloMessengerCell")
        tableView.register(MessengerGreetingCell.self, forCellReuseIdentifier: "OnloMessengerGreetingCell")
        tableView.register(MessengerHomeRowCell.self, forCellReuseIdentifier: "OnloMessengerHomeRowCell")
        tableView.register(MessengerBubbleCell.self, forCellReuseIdentifier: "OnloMessengerBubbleCell")
        tableView.register(MessengerTypingCell.self, forCellReuseIdentifier: "OnloMessengerTypingCell")
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 40
        tableView.estimatedSectionHeaderHeight = 0
        tableView.estimatedSectionFooterHeight = 0
        tableView.sectionHeaderTopPadding = 0
        // This table already sits below the SDK header. Automatic adjustment
        // applied the screen safe-area a second time and produced the large
        // blank strip visible above the greeting.
        tableView.contentInsetAdjustmentBehavior = .never
        tableView.contentInset = .zero
        tableView.scrollIndicatorInsets = .zero
        tableView.separatorStyle = .none
        tableView.accessibilityLabel = "Onlo messenger content"

        composer.backgroundColor = .clear
        composer.font = UIFontMetrics(forTextStyle: .subheadline).scaledFont(
            for: .systemFont(ofSize: 13.5, weight: .regular)
        )
        composer.adjustsFontForContentSizeCategory = true
        composer.textContainerInset = UIEdgeInsets(top: 4, left: 0, bottom: 4, right: 0)
        composer.textContainer.lineFragmentPadding = 0
        composer.isScrollEnabled = false
        composer.delegate = self
        composer.accessibilityLabel = "Message"
        composer.returnKeyType = .send
        composerPlaceholder.text = "Write a message"
        composerPlaceholder.font = UIFontMetrics(forTextStyle: .subheadline).scaledFont(
            for: .systemFont(ofSize: 13.5, weight: .regular)
        )
        composerPlaceholder.adjustsFontForContentSizeCategory = true
        composerPlaceholder.isUserInteractionEnabled = false
        composer.addSubview(composerPlaceholder)
        composerPlaceholder.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            composerPlaceholder.leadingAnchor.constraint(equalTo: composer.leadingAnchor),
            composerPlaceholder.topAnchor.constraint(equalTo: composer.topAnchor, constant: 4),
        ])
        let composerHeight = composer.heightAnchor.constraint(equalToConstant: 28)
        composerHeight.priority = .defaultHigh
        composerHeight.isActive = true
        composerHeightConstraint = composerHeight

        sendButton.setImage(UIImage(systemName: "paperplane"), for: .normal)
        sendButton.backgroundColor = UIColor(red: 27 / 255, green: 25 / 255, blue: 23 / 255, alpha: 1)
        sendButton.tintColor = .white
        sendButton.layer.cornerRadius = 6
        sendButton.addTarget(self, action: #selector(send), for: .touchUpInside)
        sendButton.accessibilityLabel = "Send message"
        attachmentButton.setImage(UIImage(systemName: "paperclip"), for: .normal)
        attachmentButton.addTarget(self, action: #selector(selectAttachment), for: .touchUpInside)
        attachmentButton.accessibilityLabel = "Add image"
        codeButton.setImage(UIImage(systemName: "chevron.left.forwardslash.chevron.right"), for: .normal)
        codeButton.addTarget(self, action: #selector(insertCode), for: .touchUpInside)
        codeButton.accessibilityLabel = "Insert code"
        linkButton.setImage(UIImage(systemName: "link"), for: .normal)
        linkButton.addTarget(self, action: #selector(insertLink), for: .touchUpInside)
        linkButton.accessibilityLabel = "Insert link"
        microphoneButton.setImage(UIImage(systemName: "mic"), for: .normal)
        microphoneButton.addTarget(self, action: #selector(toggleDictation), for: .touchUpInside)
        microphoneButton.accessibilityLabel = "Start voice input"

        [composer, microphoneButton, attachmentButton, codeButton, linkButton, sendButton].forEach {
            composerRow.addArrangedSubview($0)
        }
        composerRow.axis = .horizontal
        composerRow.spacing = 8
        composerRow.alignment = .bottom
        composerRow.isLayoutMarginsRelativeArrangement = true
        composerRow.layoutMargins = UIEdgeInsets(top: 8, left: 12, bottom: 8, right: 8)
        composerRow.layer.borderWidth = 1
        composerRow.layer.cornerRadius = 8
        sendButton.setContentHuggingPriority(.required, for: .horizontal)
        [attachmentButton, codeButton, linkButton, microphoneButton, sendButton].forEach {
            $0.widthAnchor.constraint(equalToConstant: 28).isActive = true
            $0.heightAnchor.constraint(equalToConstant: 28).isActive = true
        }

        composerArea.addSubview(composerTopDivider)
        composerArea.addSubview(composerRow)
        composerTopDivider.translatesAutoresizingMaskIntoConstraints = false
        composerRow.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            composerTopDivider.leadingAnchor.constraint(equalTo: composerArea.leadingAnchor),
            composerTopDivider.trailingAnchor.constraint(equalTo: composerArea.trailingAnchor),
            composerTopDivider.topAnchor.constraint(equalTo: composerArea.topAnchor),
            composerTopDivider.heightAnchor.constraint(equalToConstant: 1 / UIScreen.main.scale),
            composerRow.leadingAnchor.constraint(equalTo: composerArea.leadingAnchor, constant: 14),
            composerRow.trailingAnchor.constraint(equalTo: composerArea.trailingAnchor, constant: -14),
            composerRow.topAnchor.constraint(equalTo: composerArea.topAnchor, constant: 12),
            composerRow.bottomAnchor.constraint(equalTo: composerArea.bottomAnchor, constant: -12),
        ])

        footerPrefixLabel.text = "Powered by"
        footerPrefixLabel.font = UIFontMetrics(forTextStyle: .caption2).scaledFont(
            for: .systemFont(ofSize: 10.5, weight: .regular)
        )
        footerPrefixLabel.adjustsFontForContentSizeCategory = true
        footerNameLabel.text = "Onlo"
        footerNameLabel.font = UIFontMetrics(forTextStyle: .caption2).scaledFont(
            for: .systemFont(ofSize: 10.5, weight: .semibold)
        )
        footerNameLabel.adjustsFontForContentSizeCategory = true

        footerBrand.axis = .horizontal
        footerBrand.alignment = .center
        footerBrand.spacing = 2
        footerBrand.setCustomSpacing(5, after: footerPrefixLabel)
        [footerPrefixLabel, footerMark, footerNameLabel].forEach(footerBrand.addArrangedSubview)
        footerMark.widthAnchor.constraint(equalToConstant: 11).isActive = true
        footerMark.heightAnchor.constraint(equalToConstant: 11).isActive = true
        footerBrand.translatesAutoresizingMaskIntoConstraints = false
        footerArea.addSubview(footerBrand)
        footerArea.isAccessibilityElement = true
        footerArea.accessibilityLabel = "Powered by Onlo"
        footerPrefixLabel.accessibilityElementsHidden = true
        footerMark.accessibilityElementsHidden = true
        footerNameLabel.accessibilityElementsHidden = true
        NSLayoutConstraint.activate([
            footerBrand.centerXAnchor.constraint(equalTo: footerArea.centerXAnchor),
            footerBrand.topAnchor.constraint(equalTo: footerArea.topAnchor, constant: 8),
            footerBrand.bottomAnchor.constraint(equalTo: footerArea.bottomAnchor, constant: -8),
            footerArea.heightAnchor.constraint(greaterThanOrEqualToConstant: 30),
        ])
        footerDivider.heightAnchor.constraint(equalToConstant: 1 / UIScreen.main.scale).isActive = true

        [
            headerArea,
            headerDivider,
            statusLabel,
            tableView,
            composerArea,
            footerDivider,
            footerArea,
        ].forEach(messengerSurface.addArrangedSubview)
        messengerSurface.axis = .vertical
        messengerSurface.spacing = 0
        messengerSurface.translatesAutoresizingMaskIntoConstraints = false
        messengerSurface.clipsToBounds = options.presentationMode == .contained
        tableView.setContentHuggingPriority(.defaultLow, for: .vertical)
        tableView.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        composerArea.setContentHuggingPriority(.required, for: .vertical)
        composerArea.setContentCompressionResistancePriority(.required, for: .vertical)
        footerArea.setContentHuggingPriority(.required, for: .vertical)
        footerArea.setContentCompressionResistancePriority(.required, for: .vertical)
        view.addSubview(messengerSurface)
        let surfaceInset: CGFloat = options.presentationMode == .contained ? 14 : 0
        let keyboardBottomConstraint = messengerSurface.bottomAnchor.constraint(
            equalTo: view.keyboardLayoutGuide.topAnchor,
            constant: -surfaceInset
        )
        // UIKit can temporarily report a zero-height presentation container
        // during keyboard/full-screen transitions. Keep the stable layout
        // pinned while allowing that transient system state to resolve without
        // breaking the composer constraints.
        keyboardBottomConstraint.priority = UILayoutPriority(999)
        if options.presentationMode == .contained {
            let fillAvailableWidth = messengerSurface.widthAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.widthAnchor,
                constant: -(surfaceInset * 2)
            )
            // Phones fill the host width. On wider hosts the required 520pt
            // cap wins and centerX keeps the contained surface centred.
            fillAvailableWidth.priority = UILayoutPriority(999)
            NSLayoutConstraint.activate([
                messengerSurface.leadingAnchor.constraint(
                    greaterThanOrEqualTo: view.safeAreaLayoutGuide.leadingAnchor,
                    constant: surfaceInset
                ),
                messengerSurface.trailingAnchor.constraint(
                    lessThanOrEqualTo: view.safeAreaLayoutGuide.trailingAnchor,
                    constant: -surfaceInset
                ),
                messengerSurface.centerXAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerXAnchor),
                messengerSurface.widthAnchor.constraint(lessThanOrEqualToConstant: 520),
                fillAvailableWidth,
                messengerSurface.topAnchor.constraint(
                    equalTo: view.safeAreaLayoutGuide.topAnchor,
                    constant: surfaceInset
                ),
                keyboardBottomConstraint,
            ])
        } else {
            NSLayoutConstraint.activate([
                messengerSurface.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                messengerSurface.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                messengerSurface.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
                keyboardBottomConstraint,
            ])
        }
        applyAppearance()
        render()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setNavigationBarHidden(true, animated: false)
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
        selectedSessionId = nil
        pendingOutgoingMessage = nil
        streamedReplyText = ""
        isAwaitingReply = false
        helpTopics.removeAll()
        selectedFAQ = nil
        selectedHelpTopicID = nil
        selectedHelpArticle = nil
        lastInbox.removeAll()
        composer.text = ""
        composer.isEditable = false
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
                    setPlatformConnected(true)
                    screenState = transcript.map(ScreenState.transcript) ?? .offline
                    selectedConversationId = transcript == nil ? nil : intendedConversation
                    selectedSessionId = transcript?.conversation.sessionId
                    render()
                    if let transcript { await acknowledgeRendered(transcript) }
                } else {
                    let result = try await sdk.messengerInboxResult()
                    guard !Task.isCancelled else { return }
                    let inbox = result.conversations
                    if case .stale = result { setPlatformConnected(false) }
                    else { setPlatformConnected(true) }
                    lastInbox = inbox
                    screenState = .inbox(inbox)
                    render()
                }
            } catch let error as OnloError {
                guard !Task.isCancelled else { return }
                setPlatformConnected(!(error == .requiresNetwork || error.transportCode != nil))
                screenState = error == .requiresNetwork ? .offline : .failed
            } catch {
                guard !Task.isCancelled else { return }
                setPlatformConnected(false)
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
                setPlatformConnected(true)
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
        activeSurface = .home
        selectedConversationId = nil
        selectedSessionId = nil
        pendingOutgoingMessage = nil
        streamedReplyText = ""
        isAwaitingReply = false
        screenState = lastInbox.isEmpty ? .loading : .inbox(lastInbox)
        render()
        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await sdk.messengerInboxResult()
                guard !Task.isCancelled, selectedConversationId == nil else { return }
                let inbox = result.conversations
                if case .stale = result { setPlatformConnected(false) }
                else { setPlatformConnected(true) }
                lastInbox = inbox
                screenState = .inbox(inbox)
            } catch let error as OnloError {
                guard !Task.isCancelled, selectedConversationId == nil else { return }
                setPlatformConnected(!(error == .requiresNetwork || error.transportCode != nil))
                screenState = error == .requiresNetwork && !lastInbox.isEmpty
                    ? .inbox(lastInbox)
                    : (error == .requiresNetwork ? .offline : .failed)
            } catch {
                guard !Task.isCancelled, selectedConversationId == nil else { return }
                setPlatformConnected(false)
                screenState = lastInbox.isEmpty ? .failed : .inbox(lastInbox)
            }
            render()
        }
    }

    private func showConversation(_ conversationId: String) {
        activeSurface = .conversations
        selectedConversationId = conversationId
        selectedSessionId = nil
        screenState = .loading
        render()
        loadTask?.cancel()
        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let transcript = try await sdk.messengerTranscript(conversationId: conversationId)
                guard !Task.isCancelled else { return }
                setPlatformConnected(true)
                screenState = transcript.map(ScreenState.transcript) ?? .offline
                selectedSessionId = transcript?.conversation.sessionId
                render()
                if let transcript { await acknowledgeRendered(transcript) }
            } catch let error as OnloError {
                guard !Task.isCancelled else { return }
                setPlatformConnected(!(error == .requiresNetwork || error.transportCode != nil))
                screenState = error == .requiresNetwork ? .offline : .failed
            } catch {
                guard !Task.isCancelled else { return }
                setPlatformConnected(false)
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
        if activeSurface != .conversations {
            selectedConversationId = nil
            selectedSessionId = nil
        }
        activeSurface = .conversations
        composer.text = ""
        updateComposerHeight()
        uploadedAttachments.removeAll()
        composer.isEditable = false
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
        isAwaitingReply = false
        render()
        sendTask = Task { [weak self] in
            guard let self else { return }
            do {
                let stream = try await sdk.sendMessage(
                    message: message,
                    attachments: attachments,
                    routingSessionId: selectedSessionId
                )
                // A durable enqueue completes before the server accepts the
                // turn. Do not lock the composer while an offline item waits
                // for lifecycle recovery; its stable clientMessageId remains
                // owned by the encrypted native outbox.
                sendTask = nil
                composer.isEditable = true
                sendButton.isEnabled = true
                render()
                for try await event in stream {
                    guard !Task.isCancelled else { return }
                    switch event {
                    case let .accepted(clientMessageId, messageId, conversationId, _, duplicate, _):
                        pendingOutgoingMessage?.clientMessageId = clientMessageId
                        pendingOutgoingMessage?.serverMessageId = messageId
                        selectedConversationId = conversationId
                        if duplicate {
                            isAwaitingReply = false
                            await refreshTranscript(conversationId: conversationId, completed: true)
                        } else {
                            isAwaitingReply = true
                            render()
                        }
                    case let .text(content):
                        isAwaitingReply = false
                        streamedReplyText.append(content)
                        render()
                    case let .done(conversationId, _, _, _, _):
                        isAwaitingReply = false
                        let replyToSpeak = streamedReplyText
                        selectedConversationId = conversationId
                        await refreshTranscript(conversationId: conversationId, completed: true)
                        speakReply(replyToSpeak)
                    case .error:
                        isAwaitingReply = false
                        render()
                    }
                }
                isAwaitingReply = false
            } catch let error as OnloError {
                isAwaitingReply = false
                uploadedAttachments = attachments
                sendTask = nil
                composer.isEditable = true
                sendButton.isEnabled = true
                let message = switch error.safeCode {
                case "attachment_grant_expired": "Image authorization expired. Add the image again."
                case "media_unavailable": "Image upload is disabled."
                case "invalid_attachment_grant", "forbidden_principal": "Image is no longer authorized."
                default: "Message could not be saved. Try again."
                }
                statusLabel.text = message
                statusLabel.accessibilityLabel = message
            } catch {
                isAwaitingReply = false
                uploadedAttachments = attachments
                sendTask = nil
                composer.isEditable = true
                sendButton.isEnabled = true
                statusLabel.text = "Message could not be saved. Try again."
                statusLabel.accessibilityLabel = "Message could not be saved. Try again."
            }
            render()
        }
    }

    func textViewDidChange(_ textView: UITextView) {
        updateComposerHeight()
        renderComposerAvailability()
    }

    func textViewDidBeginEditing(_ textView: UITextView) {
        composerRow.layer.borderColor = activePalette.incomingText.withAlphaComponent(0.55).cgColor
    }

    func textViewDidEndEditing(_ textView: UITextView) {
        composerRow.layer.borderColor = activePalette.incomingText.withAlphaComponent(0.12).cgColor
    }

    func textView(
        _ textView: UITextView,
        shouldChangeTextIn range: NSRange,
        replacementText text: String
    ) -> Bool {
        guard text == "\n" else { return true }
        send()
        return false
    }

    @objc private func insertCode() {
        let insertion = messengerCodeInsertion(selectedText: selectedComposerText)
        replaceSelectedComposerText(with: insertion.text, cursorOffset: insertion.cursorOffset)
    }

    @objc private func insertLink() {
        let alert = UIAlertController(title: "Insert link", message: nil, preferredStyle: .alert)
        alert.addTextField { field in
            field.placeholder = "Link text"
            field.text = self.selectedComposerText
        }
        alert.addTextField { field in
            field.placeholder = "https://…"
            field.keyboardType = .URL
            field.autocapitalizationType = .none
            field.autocorrectionType = .no
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Insert", style: .default) { [weak self, weak alert] _ in
            guard let self,
                  let value = alert?.textFields?[1].text?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty else { return }
            let label = alert?.textFields?[0].text?.trimmingCharacters(in: .whitespacesAndNewlines)
            replaceSelectedComposerText(with: messengerMarkdownLink(label: label ?? "", url: value))
        })
        present(alert, animated: true)
    }

    private var selectedComposerText: String {
        guard let range = Range(composer.selectedRange, in: composer.text) else { return "" }
        return String(composer.text[range])
    }

    private func replaceSelectedComposerText(with value: String, cursorOffset: Int? = nil) {
        let range = composer.selectedRange
        guard let textRange = Range(range, in: composer.text) else { return }
        composer.text.replaceSubrange(textRange, with: value)
        composer.selectedRange = NSRange(
            location: range.location + (cursorOffset ?? value.utf16.count),
            length: 0
        )
        updateComposerHeight()
        renderComposerAvailability()
        composer.becomeFirstResponder()
    }

    private func updateComposerHeight() {
        let fitting = composer.sizeThatFits(CGSize(width: composer.bounds.width, height: .greatestFiniteMagnitude)).height
        let height = min(100, max(28, fitting))
        composerHeightConstraint?.constant = height
        composer.isScrollEnabled = fitting > 100
        composerPlaceholder.isHidden = !composer.text.isEmpty
    }

    @objc private func navigateBack() {
        if activeSurface == .faq, selectedFAQ != nil { showInbox(); return }
        if activeSurface == .helpCenter, selectedHelpArticle != nil {
            selectedHelpArticle = nil
            helpLoadFailed = false
            render()
            return
        }
        if activeSurface == .helpCenter, selectedHelpTopicID != nil {
            selectedHelpTopicID = nil
            render()
            return
        }
        showInbox()
    }

    @objc private func refreshCurrentSurface() {
        if activeSurface == .conversations, let selectedConversationId {
            showConversation(selectedConversationId)
        } else if activeSurface == .helpCenter {
            selectedHelpArticle = nil
            selectedHelpTopicID = nil
            helpIsLoading = false
            helpLoadFailed = false
            render()
        } else {
            let destination = activeSurface
            showInbox()
            if destination == .conversations { activeSurface = .conversations; render() }
        }
    }

    private func showAllConversations() {
        activeSurface = .conversations
        selectedConversationId = nil
        screenState = lastInbox.isEmpty ? .loading : .inbox(lastInbox)
        render()
    }

    private func showHelpCenter() {
        activeSurface = .helpCenter
        selectedHelpTopicID = nil
        selectedHelpArticle = nil
        render()
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
                setPlatformConnected(true)
                selectedHelpArticle = article
                helpLoadFailed = false
            } catch let error as OnloError {
                guard !Task.isCancelled else { return }
                setPlatformConnected(!(error == .requiresNetwork || error.transportCode != nil))
                helpLoadFailed = true
            } catch {
                guard !Task.isCancelled else { return }
                setPlatformConnected(false)
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
                    updateComposerHeight()
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
        updateVoiceControls()
    }

    private func updateVoiceControls() {
        microphoneButton.isHidden = !voiceIsAvailable
        microphoneButton.setImage(UIImage(systemName: isDictating ? "mic.fill" : "mic"), for: .normal)
        microphoneButton.accessibilityLabel = isDictating ? "Stop voice input" : "Start voice input"
        speakerButton.setImage(
            UIImage(systemName: speaksReplies ? "speaker.wave.2.fill" : "speaker.wave.2"),
            for: .normal
        )
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
        guard attachmentsAreAvailable, uploadTask == nil else { return }
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
                showMediaError(error)
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
                showMediaError(error)
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
        let conversationId = selectedConversationId
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

    private func showMediaError(_ error: Error) {
        guard let error = error as? OnloError else {
            showMediaError("Image could not be added.")
            return
        }
        switch error.safeCode {
        case "media_unavailable":
            showMediaError("Image upload is disabled.")
        case "attachment_grant_expired":
            showMediaError("Image authorization expired. Add the image again.")
        case "invalid_attachment_grant", "forbidden_principal":
            showMediaError("Image is no longer authorized.")
        default:
            showMediaError("Image could not be added.")
        }
    }

    private func render() {
        composerArea.isHidden = false
        updateHeaderChrome()
        tableView.backgroundView = nil
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
            statusLabel.text = pendingOutgoingMessage == nil ? "" : "Message queued"
            statusLabel.accessibilityLabel = statusLabel.text
            if pendingOutgoingMessage == nil {
                tableView.backgroundView = MessengerLoadingView(palette: activePalette)
            }
            composer.isHidden = false; sendButton.isHidden = false
        case .inbox(let conversations):
            if pendingOutgoingMessage != nil || !streamedReplyText.isEmpty {
                statusLabel.text = "Message queued"
            } else if !isPlatformConnected {
                statusLabel.text = "Offline. Showing saved conversations."
            } else {
                statusLabel.text = activeSurface == .home ? "" : (conversations.isEmpty ? "No conversations yet" : "")
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
            composerArea.isHidden = true
        }
        renderComposerAvailability()
        tableView.reloadData()
    }

    private func updateHeaderChrome() {
        headerBackButton.isHidden = activeSurface == .home
        speakerButton.isHidden = !(
            activeSurface == .conversations &&
                selectedConversationId != nil &&
                voiceIsAvailable
        )
    }

    private var attachmentsAreAvailable: Bool {
        options.allowsImageAttachments &&
            config?.features.fileUpload == true &&
            config?.mediaPolicy.enabled == true &&
            config?.compatibility.capabilities.contains(.mediaPicker) == true &&
            config?.compatibility.capabilities.contains(.attachmentUpload) == true
    }

    private var maximumImagesPerMessage: Int {
        config?.mediaPolicy.effectiveMaximumImagesPerMessage ?? 0
    }

    private var maximumImageBytes: Int {
        config?.mediaPolicy.effectiveMaximumImageBytes ?? 0
    }

    private func renderComposerAvailability() {
        attachmentButton.isHidden = !attachmentsAreAvailable
        codeButton.isHidden = config?.features.insertCode != true
        linkButton.isHidden = config?.features.insertLink != true
        attachmentButton.isEnabled = uploadTask == nil &&
            !isDictating &&
            uploadedAttachments.count < maximumImagesPerMessage
        codeButton.isEnabled = sendTask == nil && uploadTask == nil && !isDictating
        linkButton.isEnabled = codeButton.isEnabled
        microphoneButton.isEnabled = voiceIsAvailable &&
            (isDictating || (sendTask == nil && uploadTask == nil))
        let suffix = uploadedAttachments.isEmpty ? "" : " · \(uploadedAttachments.count) image\(uploadedAttachments.count == 1 ? "" : "s")"
        attachmentButton.accessibilityValue = uploadedAttachments.isEmpty
            ? nil
            : "\(uploadedAttachments.count) selected"
        if case .failed = screenState { return }
        if uploadTask != nil || isDictating {
            composer.isEditable = false
            sendButton.isEnabled = false
        } else if sendTask == nil {
            composer.isEditable = true
            sendButton.isEnabled = !composer.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                !uploadedAttachments.isEmpty
        }
        let placeholder = "Write a message\(suffix)"
        composerPlaceholder.text = placeholder
        composerPlaceholder.isHidden = !composer.text.isEmpty
        sendButton.backgroundColor = sendButton.isEnabled
            ? activePalette.accent
            : activePalette.incomingText.withAlphaComponent(0.1)
        sendButton.tintColor = sendButton.isEnabled
            ? .white
            : activePalette.incomingText.withAlphaComponent(0.35)
        updateComposerHeight()
    }

    private func applyAppearance() {
        let useDark: Bool
        let interfaceStyle: UIUserInterfaceStyle
        switch options.colorMode {
        case .light:
            useDark = false
            interfaceStyle = .light
        case .dark:
            useDark = config?.appearance.dark.enabled == true
            interfaceStyle = useDark ? .dark : .light
        case .system:
            useDark = traitCollection.userInterfaceStyle == .dark &&
                config?.appearance.dark.enabled == true
            interfaceStyle = .unspecified
        }
        let palette = MessengerPalette(config: config, useDark: useDark, color: color)
        if overrideUserInterfaceStyle != interfaceStyle {
            overrideUserInterfaceStyle = interfaceStyle
        }
        if navigationController?.overrideUserInterfaceStyle != interfaceStyle {
            navigationController?.overrideUserInterfaceStyle = interfaceStyle
        }
        view.backgroundColor = palette.background
        messengerSurface.backgroundColor = palette.background
        messengerSurface.layer.cornerRadius = options.presentationMode == .contained ? 16 : 0
        messengerSurface.layer.cornerCurve = .continuous
        messengerSurface.layer.borderWidth = options.presentationMode == .contained
            ? 1 / UIScreen.main.scale
            : 0
        messengerSurface.layer.borderColor = palette.incomingText
            .withAlphaComponent(0.24)
            .cgColor
        tableView.backgroundColor = palette.background
        statusLabel.textColor = palette.incomingText
        footerArea.backgroundColor = palette.background
        footerPrefixLabel.textColor = palette.incomingText.withAlphaComponent(0.55)
        footerNameLabel.textColor = palette.incomingText.withAlphaComponent(0.82)
        footerMark.markColor = palette.incomingText.withAlphaComponent(0.82)
        footerDivider.backgroundColor = palette.incomingText.withAlphaComponent(0.1)
        headerArea.backgroundColor = palette.background
        headerDivider.backgroundColor = palette.incomingText.withAlphaComponent(0.1)
        composerTopDivider.backgroundColor = palette.incomingText.withAlphaComponent(0.1)
        composerArea.backgroundColor = palette.background
        headerNameLabel.textColor = palette.incomingText
        headerSubtitleLabel.textColor = palette.incomingText.withAlphaComponent(0.7)
        composer.textColor = palette.incomingText
        composerPlaceholder.textColor = palette.incomingText.withAlphaComponent(0.6)
        attachmentButton.tintColor = palette.incomingText.withAlphaComponent(0.6)
        codeButton.tintColor = palette.incomingText.withAlphaComponent(0.6)
        linkButton.tintColor = palette.incomingText.withAlphaComponent(0.6)
        microphoneButton.tintColor = palette.incomingText.withAlphaComponent(0.6)
        composerRow.layer.borderColor = palette.incomingText.withAlphaComponent(0.12).cgColor
        [headerBackButton, speakerButton, refreshButton, closeButton].forEach {
            $0.tintColor = palette.incomingText
        }
    }

    private func configureHeaderArea() {
        headerArea.axis = .horizontal
        headerArea.alignment = .center
        headerArea.spacing = 8
        headerArea.isLayoutMarginsRelativeArrangement = true
        headerArea.layoutMargins = UIEdgeInsets(top: 10, left: 14, bottom: 10, right: 10)
        headerArea.heightAnchor.constraint(greaterThanOrEqualToConstant: 56).isActive = true

        configureChromeButton(
            headerBackButton,
            image: "chevron.left",
            accessibilityLabel: "Back"
        )
        headerBackButton.addTarget(self, action: #selector(navigateBack), for: .touchUpInside)
        headerBackButton.isHidden = true

        headerAvatarHost.widthAnchor.constraint(equalToConstant: 24).isActive = true
        headerAvatarHost.heightAnchor.constraint(equalToConstant: 24).isActive = true

        headerNameLabel.font = UIFontMetrics(forTextStyle: .subheadline).scaledFont(
            for: .systemFont(ofSize: 13, weight: .semibold)
        )
        headerNameLabel.adjustsFontForContentSizeCategory = true
        headerNameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        headerSubtitleLabel.font = .preferredFont(forTextStyle: .caption2)
        headerSubtitleLabel.adjustsFontForContentSizeCategory = true
        headerSubtitleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        headerStatusDot.layer.cornerRadius = 3
        headerStatusDot.isAccessibilityElement = true
        headerStatusDot.widthAnchor.constraint(equalToConstant: 6).isActive = true
        headerStatusDot.heightAnchor.constraint(equalToConstant: 6).isActive = true

        let statusRow = UIStackView(arrangedSubviews: [headerStatusDot, headerSubtitleLabel])
        statusRow.axis = .horizontal
        statusRow.alignment = .center
        statusRow.spacing = 5
        let labels = UIStackView(arrangedSubviews: [headerNameLabel, statusRow])
        labels.axis = .vertical
        labels.alignment = .leading
        labels.spacing = 0

        configureChromeButton(
            speakerButton,
            image: "speaker.wave.2",
            accessibilityLabel: "Enable spoken replies"
        )
        speakerButton.addTarget(self, action: #selector(toggleSpokenReplies), for: .touchUpInside)
        speakerButton.isHidden = true
        configureChromeButton(
            refreshButton,
            image: "arrow.clockwise",
            accessibilityLabel: "Refresh support"
        )
        refreshButton.addTarget(self, action: #selector(refreshCurrentSurface), for: .touchUpInside)
        configureChromeButton(closeButton, image: "xmark", accessibilityLabel: "Close support messenger")
        closeButton.addTarget(self, action: #selector(close), for: .touchUpInside)

        [headerBackButton, speakerButton, refreshButton, closeButton].forEach {
            $0.widthAnchor.constraint(equalToConstant: 36).isActive = true
            $0.heightAnchor.constraint(equalToConstant: 36).isActive = true
        }
        headerArea.addArrangedSubview(headerBackButton)
        headerArea.addArrangedSubview(headerAvatarHost)
        headerArea.addArrangedSubview(labels)
        headerArea.addArrangedSubview(speakerButton)
        headerArea.addArrangedSubview(refreshButton)
        headerArea.addArrangedSubview(closeButton)

        headerDivider.heightAnchor.constraint(equalToConstant: 1 / UIScreen.main.scale).isActive = true
    }

    private func configureChromeButton(
        _ button: UIButton,
        image: String,
        accessibilityLabel: String
    ) {
        button.setImage(UIImage(systemName: image), for: .normal)
        button.setPreferredSymbolConfiguration(
            UIImage.SymbolConfiguration(pointSize: 14, weight: .regular),
            forImageIn: .normal
        )
        button.accessibilityLabel = accessibilityLabel
        button.tintColor = .label
        button.backgroundColor = .clear
        button.configuration = .plain()
        button.configuration?.contentInsets = .zero
    }

    private func configureHeader() {
        guard let appearance = config?.appearance else {
            headerNameLabel.text = "Support"
            headerSubtitleLabel.text = "Typically replies in seconds"
            updateConnectionDot()
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
        avatar.layer.cornerRadius = 5
        avatar.clipsToBounds = true
        avatar.translatesAutoresizingMaskIntoConstraints = false
        headerAvatarHost.subviews.forEach { $0.removeFromSuperview() }
        headerAvatarHost.addSubview(avatar)
        NSLayoutConstraint.activate([
            avatar.leadingAnchor.constraint(equalTo: headerAvatarHost.leadingAnchor),
            avatar.trailingAnchor.constraint(equalTo: headerAvatarHost.trailingAnchor),
            avatar.topAnchor.constraint(equalTo: headerAvatarHost.topAnchor),
            avatar.bottomAnchor.constraint(equalTo: headerAvatarHost.bottomAnchor),
        ])

        headerNameLabel.text = appearance.botName
        let subtitle = appearance.botSubtitle.nilIfEmpty ?? "Typically replies in seconds"
        headerSubtitleLabel.text = subtitle
        updateConnectionDot()
    }

    private func updateConnectionDot() {
        headerStatusDot.backgroundColor = isPlatformConnected ? .systemGreen : .systemGray
        headerStatusDot.accessibilityLabel = isPlatformConnected
            ? "Connected to Onlo"
            : "Disconnected from Onlo"
    }

    private func setPlatformConnected(_ connected: Bool) {
        guard isPlatformConnected != connected else { return }
        isPlatformConnected = connected
        updateConnectionDot()
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

    func numberOfSections(in tableView: UITableView) -> Int {
        tableSections.count
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        tableSections[section].rows.count
    }

    func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
        let model = tableSections[section]
        guard let title = model.title else { return nil }
        let container = UIView()
        container.backgroundColor = activePalette.background
        let divider = UIView()
        divider.backgroundColor = activePalette.incomingText.withAlphaComponent(0.1)
        divider.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(divider)
        let label = UILabel()
        label.text = title.uppercased()
        label.font = UIFontMetrics(forTextStyle: .caption2).scaledFont(
            for: .systemFont(ofSize: 10, weight: .semibold)
        )
        label.adjustsFontForContentSizeCategory = true
        label.textColor = activePalette.incomingText.withAlphaComponent(0.55)
        label.accessibilityTraits = .header
        label.setContentHuggingPriority(.required, for: .horizontal)
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        let spacer = UIView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let stack = UIStackView(arrangedSubviews: [label, spacer])
        stack.axis = .horizontal
        stack.alignment = .center
        stack.layoutMargins = UIEdgeInsets(top: 10, left: 16, bottom: 4, right: 12)
        stack.isLayoutMarginsRelativeArrangement = true
        if let actionTitle = model.actionTitle, let action = model.action {
            let button = UIButton(type: .system)
            var configuration = UIButton.Configuration.plain()
            configuration.title = actionTitle
            configuration.baseForegroundColor = activePalette.incomingText.withAlphaComponent(0.65)
            configuration.contentInsets = NSDirectionalEdgeInsets(
                top: 2,
                leading: 4,
                bottom: 2,
                trailing: 4
            )
            configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
                var attributes = attributes
                attributes.font = UIFontMetrics(forTextStyle: .caption1).scaledFont(
                    for: .systemFont(ofSize: 11, weight: .regular)
                )
                return attributes
            }
            button.configuration = configuration
            button.setContentHuggingPriority(.required, for: .horizontal)
            button.setContentCompressionResistancePriority(.required, for: .horizontal)
            button.addTarget(self, action: action, for: .touchUpInside)
            stack.addArrangedSubview(button)
        }
        stack.backgroundColor = activePalette.background
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            divider.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            divider.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            divider.topAnchor.constraint(equalTo: container.topAnchor),
            divider.heightAnchor.constraint(equalToConstant: 1 / UIScreen.main.scale),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.topAnchor.constraint(equalTo: divider.bottomAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        return container
    }

    func tableView(_ tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat {
        tableSections[section].title == nil ? .leastNormalMagnitude : 31
    }

    func tableView(_ tableView: UITableView, heightForFooterInSection section: Int) -> CGFloat {
        .leastNormalMagnitude
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let row = tableSections[indexPath.section].rows[indexPath.row]
        switch row {
        case let .transcript(message):
            let alignment = messengerMessageAlignment(role: message.role)
            return bubbleCell(
                tableView,
                text: message.text,
                alignment: alignment,
                metadata: transcriptMetadata(message, alignment: alignment),
                accessibilityLabel: "\(message.role): \(message.text)"
            )
        case let .pendingOutgoing(text):
            return bubbleCell(
                tableView,
                text: text,
                alignment: .trailing,
                metadata: nil,
                accessibilityLabel: "You: \(text), queued"
            )
        case .typingIndicator:
            let cell = tableView.dequeueReusableCell(
                withIdentifier: "OnloMessengerTypingCell",
                for: indexPath
            ) as! MessengerTypingCell
            cell.configure(color: activePalette.incomingText.withAlphaComponent(0.55))
            return cell
        case let .streamedReply(text):
            return bubbleCell(
                tableView,
                text: text,
                alignment: .leading,
                metadata: nil,
                accessibilityLabel: "Support: \(text), replying"
            )
        case .homeGreeting:
            let cell = tableView.dequeueReusableCell(
                withIdentifier: "OnloMessengerGreetingCell",
                for: indexPath
            ) as! MessengerGreetingCell
            cell.configure(
                title: homeGreetingTitle,
                subtitle: homeGreetingSubtitle,
                palette: activePalette
            )
            return cell
        case let .inbox(item) where activeSurface == .home:
            let cell = tableView.dequeueReusableCell(
                withIdentifier: "OnloMessengerHomeRowCell",
                for: indexPath
            ) as! MessengerHomeRowCell
            cell.configureConversation(item, palette: activePalette, relativeTime: relativeTime(item.updatedAt))
            return cell
        case let .homeFAQ(faq):
            let cell = tableView.dequeueReusableCell(
                withIdentifier: "OnloMessengerHomeRowCell",
                for: indexPath
            ) as! MessengerHomeRowCell
            cell.configureQuestion(faq.question, palette: activePalette)
            return cell
        default:
            break
        }
        let cell = tableView.dequeueReusableCell(withIdentifier: "OnloMessengerCell", for: indexPath)
        cell.textLabel?.numberOfLines = 0
        cell.textLabel?.font = .preferredFont(forTextStyle: .body)
        cell.textLabel?.attributedText = nil
        cell.backgroundColor = activePalette.background
        cell.textLabel?.textColor = activePalette.incomingText
        cell.accessoryView = nil
        cell.selectionStyle = .default
        switch row {
        case .homeGreeting:
            preconditionFailure("Greeting rows return before standard cell configuration")
        case let .inbox(item):
            cell.textLabel?.text = item.title
            cell.textLabel?.font = item.unreadCount > 0
                ? .preferredFont(forTextStyle: .headline)
                : .preferredFont(forTextStyle: .subheadline)
            cell.accessibilityLabel = item.unreadCount > 0
                ? "\(item.title), \(item.unreadCount) unread"
                : item.title
            let time = UILabel()
            time.text = relativeTime(item.updatedAt)
            time.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            time.textColor = activePalette.incomingText.withAlphaComponent(0.5)
            cell.accessoryView = time
            cell.accessoryType = .none
        case let .homeFAQ(faq):
            cell.textLabel?.text = faq.question
            cell.textLabel?.font = .preferredFont(forTextStyle: .subheadline)
            cell.accessibilityLabel = faq.question
            cell.accessoryType = .disclosureIndicator
        case .helpShortcut:
            cell.textLabel?.text = "Browse the help center"
            cell.textLabel?.font = .preferredFont(forTextStyle: .subheadline)
            cell.accessibilityLabel = "Browse the help center"
            cell.accessoryType = .disclosureIndicator
        case .transcript, .pendingOutgoing, .typingIndicator, .streamedReply:
            preconditionFailure("Bubble rows return before standard cell configuration")
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

    private func bubbleCell(
        _ tableView: UITableView,
        text: String,
        alignment: MessengerMessageAlignment,
        metadata: String?,
        accessibilityLabel: String
    ) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(
            withIdentifier: "OnloMessengerBubbleCell"
        ) as! MessengerBubbleCell
        cell.configure(
            text: text,
            alignment: alignment,
            metadata: metadata,
            palette: activePalette,
            accessibilityLabel: accessibilityLabel
        )
        return cell
    }

    private func transcriptMetadata(
        _ message: TranscriptMessage,
        alignment: MessengerMessageAlignment
    ) -> String? {
        let outgoing = alignment == .trailing
        let author = outgoing
            ? "You"
            : message.senderName?.nilIfBlank ?? config?.appearance.botName.nilIfBlank ?? "Support"
        let time = config?.features.showTimestamps == false ? nil : formattedMessageTime(message.timestamp)
        let team = outgoing ? nil : message.senderTeam?.nilIfBlank
        let values = outgoing ? [time, author] : [author, team, time]
        let metadata = values.compactMap { $0 }.joined(separator: "  ")
        return metadata.nilIfEmpty
    }

    private func formattedMessageTime(_ timestamp: Int64) -> String? {
        guard timestamp > 0 else { return nil }
        let seconds = timestamp > 10_000_000_000 ? Double(timestamp) / 1_000 : Double(timestamp)
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter.string(from: Date(timeIntervalSince1970: seconds))
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        switch tableSections[indexPath.section].rows[indexPath.row] {
        case .homeGreeting:
            break
        case let .inbox(item):
            showConversation(item.id)
        case let .homeFAQ(faq):
            openFAQ(faq)
        case .helpShortcut:
            showHelpCenter()
        case let .helpTopic(topic):
            selectedHelpTopicID = topic.id
            selectedHelpArticle = nil
            render()
        case let .helpArticle(article):
            loadHelpArticle(article.id)
        case let .faqQuestion(faq):
            openFAQ(faq)
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
        case .transcript, .pendingOutgoing, .typingIndicator, .streamedReply, .faqAnswer, .helpArticleBody:
            break
        }
        tableView.deselectRow(at: indexPath, animated: true)
    }

    private var tableSections: [TableSection] {
        if activeSurface == .home {
            var sections = [TableSection(title: nil, actionTitle: nil, action: nil, rows: [.homeGreeting])]
            if !lastInbox.isEmpty {
                sections.append(TableSection(
                    title: "Recent conversations",
                    actionTitle: "See all →",
                    action: #selector(showAllConversationsAction),
                    rows: lastInbox.prefix(3).map(VisibleRow.inbox)
                ))
            }
            let quick = configuredQuickQuestions
            if !quick.isEmpty {
                sections.append(TableSection(
                    title: "Quick questions",
                    actionTitle: "Browse all →",
                    action: #selector(showHelpCenterAction),
                    rows: quick.prefix(3).map(VisibleRow.homeFAQ)
                ))
            } else if !helpTopics.isEmpty {
                sections.append(TableSection(title: nil, actionTitle: nil, action: nil, rows: [.helpShortcut]))
            }
            return sections
        }
        return [TableSection(title: nil, actionTitle: nil, action: nil, rows: visibleRows)]
    }

    private var visibleRows: [VisibleRow] {
        if activeSurface == .faq {
            if let selectedFAQ {
                return [.faqAnswer(selectedFAQ)]
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
            if activeSurface == .conversations,
               pendingOutgoingMessage != nil || isAwaitingReply || !streamedReplyText.isEmpty {
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
        if isAwaitingReply && streamedReplyText.isEmpty { rows.append(.typingIndicator) }
        if !streamedReplyText.isEmpty { rows.append(.streamedReply(streamedReplyText)) }
        return rows
    }

    private var configuredFAQs: [MobileConfig.FAQ] {
        configuredQuickQuestions
    }

    private var configuredQuickQuestions: [MobileConfig.FAQ] {
        guard faqContentIsCurrent, config?.features.faqButton.enabled == true else { return [] }
        return (config?.content.faqs ?? []).filter {
            !$0.question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    @objc private func showAllConversationsAction() { showAllConversations() }
    @objc private func showHelpCenterAction() { showHelpCenter() }

    private func openFAQ(_ faq: MobileConfig.FAQ) {
        if !(faq.answer ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            activeSurface = .faq
            selectedFAQ = faq
            render()
            return
        }
        activeSurface = .home
        selectedConversationId = nil
        selectedSessionId = nil
        composer.text = faq.question
        updateComposerHeight()
        send()
    }

    private var homeGreetingTitle: String {
        identifiedFirstName.map { "Hi \($0) 👋" } ?? "Hi there 👋"
    }

    private var homeGreetingSubtitle: String {
        if identifiedFirstName != nil, !lastInbox.isEmpty {
            return "Pick up where you left off, or ask something new."
        }
        let greeting = config?.appearance.greeting.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let cleaned = greeting.replacingOccurrences(
            of: #"^\s*Hi[^\n]*?👋\s*[-—:.,]*\s*"#,
            with: "",
            options: [.regularExpression, .caseInsensitive]
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.nilIfEmpty ?? "How can we help?"
    }

    private func relativeTime(_ value: String) -> String {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let whole = ISO8601DateFormatter()
        whole.formatOptions = [.withInternetDateTime]
        guard let date = fractional.date(from: value) ?? whole.date(from: value) else { return "" }
        let minutes = max(0, Int(Date().timeIntervalSince(date) / 60))
        if minutes < 1 { return "now" }
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h" }
        let days = hours / 24
        if days < 7 { return "\(days)d" }
        return "\(days / 7)w"
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
        if completed {
            streamedReplyText = ""
            isAwaitingReply = false
        }
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

@MainActor
private final class OnloMarkView: UIView {
    var markColor: UIColor = UIColor(red: 27 / 255, green: 25 / 255, blue: 23 / 255, alpha: 1) {
        didSet { setNeedsDisplay() }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
    }

    required init?(coder: NSCoder) { nil }

    override func draw(_ rect: CGRect) {
        let size = min(rect.width, rect.height)
        guard size > 0 else { return }
        let lineWidth = size * 0.16
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = (size - lineWidth) / 2
        let radians: (CGFloat) -> CGFloat = { $0 * .pi / 180 }

        markColor.setStroke()
        for start in [CGFloat(136), CGFloat(316)] {
            let path = UIBezierPath(
                arcCenter: center,
                radius: radius,
                startAngle: radians(start),
                endAngle: radians(start + 151),
                clockwise: true
            )
            path.lineWidth = lineWidth
            path.lineCapStyle = .round
            path.stroke()
        }
    }
}

@MainActor
private final class MessengerGreetingCell: UITableViewCell {
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none

        titleLabel.font = UIFontMetrics(forTextStyle: .title2).scaledFont(
            for: .systemFont(ofSize: 22, weight: .semibold)
        )
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.numberOfLines = 0
        titleLabel.accessibilityTraits = .header
        subtitleLabel.font = UIFontMetrics(forTextStyle: .subheadline).scaledFont(
            for: .systemFont(ofSize: 13, weight: .regular)
        )
        subtitleLabel.adjustsFontForContentSizeCategory = true
        subtitleLabel.adjustsFontSizeToFitWidth = true
        subtitleLabel.minimumScaleFactor = 0.9
        subtitleLabel.numberOfLines = 1

        let stack = UIStackView(arrangedSubviews: [titleLabel, subtitleLabel])
        stack.axis = .vertical
        stack.alignment = .fill
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -18),
        ])
    }

    required init?(coder: NSCoder) { nil }

    func configure(title: String, subtitle: String, palette: MessengerPalette) {
        backgroundColor = palette.background
        contentView.backgroundColor = palette.background
        titleLabel.text = title
        titleLabel.textColor = palette.incomingText
        subtitleLabel.text = subtitle
        subtitleLabel.textColor = palette.incomingText.withAlphaComponent(0.65)
        accessibilityLabel = "\(title). \(subtitle)"
    }
}

@MainActor
private final class MessengerHomeRowCell: UITableViewCell {
    private let unreadDot = UILabel()
    private let titleLabel = UILabel()
    private let trailingLabel = UILabel()
    private var dotWidthConstraint: NSLayoutConstraint!

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .default
        backgroundColor = .clear
        contentView.backgroundColor = .clear

        unreadDot.text = "●"
        unreadDot.textAlignment = .left
        unreadDot.font = .systemFont(ofSize: 8)
        unreadDot.setContentCompressionResistancePriority(.required, for: .horizontal)
        titleLabel.font = UIFontMetrics(forTextStyle: .subheadline).scaledFont(
            for: .systemFont(ofSize: 12.5, weight: .regular)
        )
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.numberOfLines = 1
        titleLabel.lineBreakMode = .byTruncatingTail
        trailingLabel.font = UIFontMetrics(forTextStyle: .caption2).scaledFont(
            for: .systemFont(ofSize: 10.5, weight: .regular)
        )
        trailingLabel.adjustsFontForContentSizeCategory = true
        trailingLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        let row = UIStackView(arrangedSubviews: [unreadDot, titleLabel, trailingLabel])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 0
        row.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(row)
        dotWidthConstraint = unreadDot.widthAnchor.constraint(equalToConstant: 14)
        NSLayoutConstraint.activate([
            dotWidthConstraint,
            row.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 24),
            row.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -24),
            row.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 9),
            row.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -9),
        ])
    }

    required init?(coder: NSCoder) { nil }

    func configureConversation(
        _ conversation: ConversationSummary,
        palette: MessengerPalette,
        relativeTime: String
    ) {
        backgroundColor = palette.background
        contentView.backgroundColor = palette.background
        dotWidthConstraint.constant = 14
        unreadDot.text = conversation.unreadCount > 0 ? "●" : ""
        unreadDot.textColor = palette.accent
        titleLabel.text = conversation.title
        titleLabel.font = UIFontMetrics(forTextStyle: .subheadline).scaledFont(
            for: .systemFont(
                ofSize: 12.5,
                weight: conversation.unreadCount > 0 ? .semibold : .regular
            )
        )
        titleLabel.textColor = palette.incomingText
        trailingLabel.text = relativeTime
        trailingLabel.textColor = palette.incomingText.withAlphaComponent(0.5)
        accessibilityLabel = conversation.unreadCount > 0
            ? "\(conversation.title), \(conversation.unreadCount) unread, \(relativeTime)"
            : "\(conversation.title), \(relativeTime)"
    }

    func configureQuestion(_ question: String, palette: MessengerPalette) {
        backgroundColor = palette.background
        contentView.backgroundColor = palette.background
        dotWidthConstraint.constant = 0
        unreadDot.text = ""
        titleLabel.text = question
        titleLabel.font = UIFontMetrics(forTextStyle: .subheadline).scaledFont(
            for: .systemFont(ofSize: 12.5, weight: .regular)
        )
        titleLabel.textColor = palette.incomingText
        trailingLabel.text = "→"
        trailingLabel.textColor = palette.incomingText.withAlphaComponent(0.55)
        accessibilityLabel = question
    }
}

@MainActor
private final class MessengerBubbleCell: UITableViewCell {
    private let bubbleView = UIView()
    private let messageLabel = UILabel()
    private let metadataLabel = UILabel()
    private let messageStack = UIStackView()
    private var leadingConstraint: NSLayoutConstraint!
    private var trailingConstraint: NSLayoutConstraint!

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none
        backgroundColor = .clear
        contentView.backgroundColor = .clear

        bubbleView.translatesAutoresizingMaskIntoConstraints = false
        bubbleView.layer.cornerRadius = 14
        bubbleView.clipsToBounds = true
        messageLabel.translatesAutoresizingMaskIntoConstraints = false
        messageLabel.numberOfLines = 0
        messageLabel.font = .preferredFont(forTextStyle: .subheadline)
        messageLabel.adjustsFontForContentSizeCategory = true
        metadataLabel.font = .preferredFont(forTextStyle: .caption2)
        metadataLabel.adjustsFontForContentSizeCategory = true
        metadataLabel.numberOfLines = 1
        bubbleView.addSubview(messageLabel)

        messageStack.axis = .vertical
        messageStack.spacing = 4
        messageStack.translatesAutoresizingMaskIntoConstraints = false
        messageStack.addArrangedSubview(metadataLabel)
        messageStack.addArrangedSubview(bubbleView)
        contentView.addSubview(messageStack)

        leadingConstraint = messageStack.leadingAnchor.constraint(
            equalTo: contentView.layoutMarginsGuide.leadingAnchor
        )
        trailingConstraint = messageStack.trailingAnchor.constraint(
            equalTo: contentView.layoutMarginsGuide.trailingAnchor
        )
        NSLayoutConstraint.activate([
            messageStack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 6),
            messageStack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -6),
            messageStack.widthAnchor.constraint(lessThanOrEqualTo: contentView.widthAnchor, multiplier: 0.78),
            messageStack.leadingAnchor.constraint(greaterThanOrEqualTo: contentView.layoutMarginsGuide.leadingAnchor),
            messageStack.trailingAnchor.constraint(lessThanOrEqualTo: contentView.layoutMarginsGuide.trailingAnchor),
            messageLabel.leadingAnchor.constraint(equalTo: bubbleView.leadingAnchor, constant: 12),
            messageLabel.trailingAnchor.constraint(equalTo: bubbleView.trailingAnchor, constant: -12),
            messageLabel.topAnchor.constraint(equalTo: bubbleView.topAnchor, constant: 8),
            messageLabel.bottomAnchor.constraint(equalTo: bubbleView.bottomAnchor, constant: -8),
        ])
    }

    required init?(coder: NSCoder) { nil }

    func configure(
        text: String,
        alignment: MessengerMessageAlignment,
        metadata: String?,
        palette: MessengerPalette,
        accessibilityLabel: String
    ) {
        let outgoing = alignment == .trailing
        NSLayoutConstraint.deactivate([leadingConstraint, trailingConstraint])
        (outgoing ? trailingConstraint : leadingConstraint).isActive = true
        messageStack.alignment = outgoing ? .trailing : .leading
        bubbleView.backgroundColor = outgoing ? palette.outgoing : palette.incoming
        messageLabel.text = text
        messageLabel.textColor = outgoing ? palette.outgoingText : palette.incomingText
        metadataLabel.text = metadata
        metadataLabel.isHidden = metadata == nil
        metadataLabel.textAlignment = outgoing ? .right : .left
        metadataLabel.textColor = palette.incomingText.withAlphaComponent(0.5)
        bubbleView.layer.maskedCorners = outgoing
            ? [.layerMinXMinYCorner, .layerMaxXMinYCorner, .layerMinXMaxYCorner]
            : [.layerMinXMinYCorner, .layerMaxXMinYCorner, .layerMaxXMaxYCorner]
        isAccessibilityElement = true
        self.accessibilityLabel = accessibilityLabel
    }
}

@MainActor
private final class MessengerTypingCell: UITableViewCell {
    private let dots = [UIView(), UIView(), UIView()]

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none
        backgroundColor = .clear
        contentView.backgroundColor = .clear
        isAccessibilityElement = true
        accessibilityLabel = "Support is typing"
        accessibilityTraits = .updatesFrequently

        let stack = UIStackView(arrangedSubviews: dots)
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = 3
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)
        dots.forEach { dot in
            dot.layer.cornerRadius = 3
            dot.widthAnchor.constraint(equalToConstant: 6).isActive = true
            dot.heightAnchor.constraint(equalToConstant: 6).isActive = true
        }
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -8),
        ])
    }

    required init?(coder: NSCoder) { nil }

    func configure(color: UIColor) {
        dots.forEach { $0.backgroundColor = color }
        startAnimatingIfVisible()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil {
            dots.forEach { $0.layer.removeAnimation(forKey: "onlo.typing") }
        } else {
            startAnimatingIfVisible()
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        dots.forEach { $0.layer.removeAnimation(forKey: "onlo.typing") }
    }

    private func startAnimatingIfVisible() {
        guard window != nil else { return }
        for (index, dot) in dots.enumerated() {
            guard dot.layer.animation(forKey: "onlo.typing") == nil else { continue }
            let scale = CAKeyframeAnimation(keyPath: "transform.scale")
            scale.values = [0.8, 1, 0.8, 0.8]
            scale.keyTimes = [0, 0.4, 0.8, 1]
            let opacity = CAKeyframeAnimation(keyPath: "opacity")
            opacity.values = [0.5, 1, 0.5, 0.5]
            opacity.keyTimes = scale.keyTimes
            let animation = CAAnimationGroup()
            animation.animations = [scale, opacity]
            animation.duration = 1.4
            animation.beginTime = CACurrentMediaTime() + (Double(index) * 0.16)
            animation.repeatCount = .infinity
            animation.isRemovedOnCompletion = false
            dot.layer.add(animation, forKey: "onlo.typing")
        }
    }
}

@MainActor
private final class MessengerLoadingView: UIView {
    private let skeletons: [UIView]

    init(palette: MessengerPalette) {
        let widths: [CGFloat] = [0.72, 0.48, 0.64, 0.42]
        skeletons = widths.map { _ in UIView() }
        super.init(frame: .zero)
        backgroundColor = palette.background
        isAccessibilityElement = true
        accessibilityLabel = "Loading messenger content"

        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        for (index, skeleton) in skeletons.enumerated() {
            skeleton.backgroundColor = palette.incomingText.withAlphaComponent(0.11)
            skeleton.layer.cornerRadius = 6
            skeleton.translatesAutoresizingMaskIntoConstraints = false
            let row = UIView()
            row.addSubview(skeleton)
            NSLayoutConstraint.activate([
                row.heightAnchor.constraint(equalToConstant: 12),
                skeleton.leadingAnchor.constraint(equalTo: row.leadingAnchor),
                skeleton.topAnchor.constraint(equalTo: row.topAnchor),
                skeleton.bottomAnchor.constraint(equalTo: row.bottomAnchor),
                skeleton.widthAnchor.constraint(equalTo: row.widthAnchor, multiplier: widths[index]),
            ])
            stack.addArrangedSubview(row)
        }
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 28),
        ])
    }

    required init?(coder: NSCoder) { nil }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil else {
            skeletons.forEach { $0.layer.removeAllAnimations() }
            return
        }
        skeletons.forEach { skeleton in
            skeleton.alpha = 0.38
            UIView.animate(
                withDuration: 0.9,
                delay: 0,
                options: [.autoreverse, .repeat, .allowUserInteraction]
            ) {
                skeleton.alpha = 1
            }
        }
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
    var nilIfBlank: String? {
        trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }
}

@MainActor
private final class PresentationGate {
    var invalidated = false
}
#endif
