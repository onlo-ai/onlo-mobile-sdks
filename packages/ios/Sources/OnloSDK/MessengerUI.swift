import Foundation

/// The SDK-owned messenger is available only where UIKit is available. It is
/// deliberately a host-presented controller: initialization never adds an
/// overlay, window, navigation item, or permission prompt.
#if canImport(UIKit)
import UIKit

@MainActor
public final class OnloMessengerPresenter: NSObject, UIAdaptivePresentationControllerDelegate {
    private let sdk: OnloSDK
    private weak var navigationController: UINavigationController?
    private weak var messengerController: OnloMessengerViewController?
    private var invalidatorID: UUID?

    public init(sdk: OnloSDK) {
        self.sdk = sdk
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
        dismissIfStale()
        guard host.viewIfLoaded?.window != nil, !host.isBeingDismissed else {
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
            let config = try? await sdk.currentConfiguration()
            guard !gate.invalidated,
                  host.viewIfLoaded?.window != nil,
                  !host.isBeingDismissed else { throw OnloError.invalidState }
            let target: String?
            switch intent { case let .messenger(conversationId): target = conversationId }
            let controller = OnloMessengerViewController(sdk: sdk, conversationId: target, config: config)
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

    private func dismissIfStale() {
        guard let navigationController else { return }
        navigationController.dismiss(animated: false)
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
private final class OnloMessengerViewController: UIViewController, UITableViewDataSource, UITableViewDelegate, UITextFieldDelegate {
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
    private var screenState: ScreenState = .loading
    private var selectedConversationId: String?
    /// Native-memory-only optimistic and streamed rows. They make a durable
    /// send visible immediately, while the authorised transcript remains the
    /// source of truth after acceptance/completion.
    private var pendingOutgoingMessage: PendingOutgoingMessage?
    private var streamedReplyText = ""
    private var loadTask: Task<Void, Never>?
    private var sendTask: Task<Void, Never>?

    private let statusLabel = UILabel()
    private let tableView = UITableView(frame: .zero, style: .plain)
    private let composer = UITextField()
    private let sendButton = UIButton(type: .system)

    private struct PendingOutgoingMessage {
        let text: String
        var clientMessageId: String?
    }

    private enum VisibleRow {
        case inbox(ConversationSummary)
        case transcript(TranscriptMessage)
        case pendingOutgoing(String)
        case streamedReply(String)
    }

    init(sdk: OnloSDK, conversationId: String?, config: MobileConfig?) {
        self.sdk = sdk
        self.requestedConversationId = conversationId
        self.config = config
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = config?.appearance.botName ?? "Support"
        view.backgroundColor = color(config?.appearance.light.background) ?? .systemBackground
        navigationItem.leftBarButtonItem = UIBarButtonItem(barButtonSystemItem: .close, target: self, action: #selector(close))

        statusLabel.numberOfLines = 0
        statusLabel.textAlignment = .center
        statusLabel.font = .preferredFont(forTextStyle: .footnote)
        statusLabel.adjustsFontForContentSizeCategory = true
        statusLabel.accessibilityTraits = .staticText

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
        sendButton.tintColor = color(config?.appearance.accent)

        let composerRow = UIStackView(arrangedSubviews: [composer, sendButton])
        composerRow.axis = .horizontal
        composerRow.spacing = 8
        composerRow.alignment = .center
        sendButton.setContentHuggingPriority(.required, for: .horizontal)

        let stack = UIStackView(arrangedSubviews: [statusLabel, tableView, composerRow])
        stack.axis = .vertical
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 10),
            stack.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor, constant: -10),
            composer.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
        ])
        render()
    }

    deinit { loadTask?.cancel(); sendTask?.cancel() }

    func redactForAccountBoundary() {
        loadTask?.cancel(); loadTask = nil
        sendTask?.cancel(); sendTask = nil
        selectedConversationId = nil
        pendingOutgoingMessage = nil
        streamedReplyText = ""
        composer.text = nil
        composer.isEnabled = false
        sendButton.isEnabled = false
        screenState = .failed
        render()
    }

    func loadInitialContent() {
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
                } else {
                    let inbox = try await sdk.messengerInbox()
                    guard !Task.isCancelled else { return }
                    screenState = .inbox(inbox)
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

    @objc private func close() { dismiss(animated: true) }

    @objc private func send() {
        let message = composer.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !message.isEmpty, sendTask == nil else { return }
        composer.text = ""
        composer.isEnabled = false
        sendButton.isEnabled = false
        pendingOutgoingMessage = PendingOutgoingMessage(text: message, clientMessageId: nil)
        streamedReplyText = ""
        render()
        sendTask = Task { [weak self] in
            guard let self else { return }
            do {
                let stream = try await sdk.sendMessage(message: message)
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
                    case let .accepted(clientMessageId, _, conversationId, _, _, _):
                        pendingOutgoingMessage?.clientMessageId = clientMessageId
                        selectedConversationId = conversationId
                        screenState = .loading
                        render()
                        await refreshTranscript(conversationId: conversationId, completed: false)
                    case let .text(content):
                        streamedReplyText.append(content)
                        render()
                    case let .done(conversationId, _, _, _, _):
                        selectedConversationId = conversationId
                        await refreshTranscript(conversationId: conversationId, completed: true)
                    case .error:
                        break
                    }
                }
            } catch {
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

    private func render() {
        switch screenState {
        case .loading:
            statusLabel.text = pendingOutgoingMessage == nil ? "Loading support" : "Message queued"
            statusLabel.accessibilityLabel = statusLabel.text
            composer.isHidden = false; sendButton.isHidden = false
        case .inbox(let conversations):
            if pendingOutgoingMessage != nil || !streamedReplyText.isEmpty {
                statusLabel.text = "Message queued"
            } else {
                statusLabel.text = conversations.isEmpty ? "No conversations yet" : "Conversations"
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
        tableView.reloadData()
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
        switch visibleRows[indexPath.row] {
        case let .inbox(item):
            cell.textLabel?.text = item.title
            cell.accessibilityLabel = item.unread ? "Unread conversation, \(item.title)" : item.title
            cell.accessoryType = .disclosureIndicator
        case let .transcript(message):
            cell.textLabel?.text = message.text
            cell.accessibilityLabel = "\(message.role): \(message.text)"
            cell.accessoryType = .none
        case let .pendingOutgoing(text):
            cell.textLabel?.text = text
            cell.accessibilityLabel = "You: \(text), queued"
            cell.accessoryType = .none
        case let .streamedReply(text):
            cell.textLabel?.text = text
            cell.accessibilityLabel = "Support: \(text), replying"
            cell.accessoryType = .none
        }
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        guard case let .inbox(item) = visibleRows[indexPath.row] else { return }
        showConversation(item.id)
    }

    private var visibleRows: [VisibleRow] {
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

    private func refreshTranscript(conversationId: String, completed: Bool) async {
        do {
            guard let transcript = try await sdk.messengerTranscript(conversationId: conversationId) else {
                render()
                return
            }
            screenState = .transcript(transcript)
            if let clientMessageId = pendingOutgoingMessage?.clientMessageId,
               transcript.messages.contains(where: { $0.externalId == clientMessageId }) {
                pendingOutgoingMessage = nil
            }
            if completed { streamedReplyText = "" }
        } catch {
            // Keep the already-rendered native-memory rows. The durable outbox
            // and authorised transcript reconciliation remain owned by the SDK.
        }
        render()
    }
}

@MainActor
private final class PresentationGate {
    var invalidated = false
}
#endif
