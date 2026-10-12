import AppKit
import Combine

final class ChatViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, MessageCellDelegate, ComposeViewDelegate {
    private(set) var threadID: String?

    private enum Row {
        case separator(String)
        case caption(String, CaptionCellView.Placement, NSColor)
        case message(ChatMessage, MessageCellView.Layout)
        case typing
    }

    private let store = ChatStore.shared
    private let scrollView = NSScrollView()
    private let tableView = NSTableView()
    private let compose = ComposeView()
    private let emptyLabel = NSTextField(labelWithString: "No Conversation Selected")
    private var rows: [Row] = []
    private var cancellables: Set<AnyCancellable> = []
    private var lastLayoutWidth: CGFloat = 0
    private var isLoadingOlder = false
    private var replyTarget: ChatMessage?
    private var isTypingSent = false
    private var typingStopTimer: Timer?
    private var drafts: [String: NSAttributedString] = [:]
    private var lastConversation: Conversation?

    private static let reactionChoices = ["❤️", "😆", "😮", "😢", "😠", "👍"]

    override func loadView() {
        let root = DropTargetView()
        root.onDrop = { [weak self] pasteboard in
            guard let self, self.threadID != nil else { return false }
            return self.compose.addAttachments(from: pasteboard)
        }
        view = root
        WebSyncController.shared.embedInvisibly(in: root)

        let column = NSTableColumn(identifier: .init("message"))
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.usesAutomaticRowHeights = true
        tableView.selectionHighlightStyle = .none
        tableView.intercellSpacing = .zero
        tableView.backgroundColor = .clear
        tableView.gridStyleMask = []
        tableView.style = .plain
        tableView.dataSource = self
        tableView.delegate = self

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.automaticallyAdjustsContentInsets = true

        compose.delegate = self

        emptyLabel.font = .systemFont(ofSize: 15, weight: .medium)
        emptyLabel.textColor = .tertiaryLabelColor

        for view in [scrollView, compose, emptyLabel] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: root.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: compose.topAnchor),
            compose.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            compose.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            compose.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            emptyLabel.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: root.centerYAnchor),
        ])
        updateEmptyState()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        store.changes
            .sink { [weak self] change in
                guard let self, let threadID = self.threadID else { return }
                switch change {
                case .messages(let id) where id == threadID:
                    self.reload()
                    self.markReadIfVisible()
                case .typing(let id) where id == threadID:
                    self.reload()
                case .conversations:
                    // Participant names / read markers may have changed.
                    let conversation = self.store.conversation(threadID)
                    if conversation != self.lastConversation {
                        self.lastConversation = conversation
                        self.reload()
                    }
                default:
                    break
                }
            }
            .store(in: &cancellables)

        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification, object: scrollView.contentView
        )

        WebHistoryImporter.shared.onStateChange = { [weak self] threadID, _ in
            if threadID == self?.threadID { self?.reload() }
        }
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        // Bubble widths depend on the window width.
        let width = scrollView.contentSize.width
        if abs(width - lastLayoutWidth) > 1 {
            lastLayoutWidth = width
            // Defer so we don't re-enter layout from inside viewDidLayout.
            DispatchQueue.main.async { [weak self] in self?.reload() }
        }
    }

    // MARK: - Showing a thread

    func show(threadID: String?) {
        if let current = self.threadID {
            drafts[current] = compose.hasContent ? compose.draft : nil
            stopTyping()
        }
        self.threadID = threadID
        lastConversation = threadID.flatMap { store.conversation($0) }
        replyTarget = nil
        compose.hideReply()
        if let draft = threadID.flatMap({ drafts[$0] }) {
            compose.draft = draft
        } else {
            compose.text = ""
        }
        updateEmptyState()
        reload(scrollToBottom: true)
        guard let threadID else { return }
        compose.focus()
        Task {
            await store.openThread(threadID)
            if self.threadID == threadID {
                reload(scrollToBottom: true)
                markReadIfVisible()
            }
            if store.conversation(threadID)?.isEncrypted == true {
                WebHistoryImporter.shared.importHistory(threadID: threadID)
            }
        }
    }

    func markReadIfVisible() {
        guard let threadID, let window = view.window, window.isKeyWindow, NSApp.isActive,
              let conversation = store.conversation(threadID), conversation.unreadCount > 0 else { return }
        store.markRead(threadID)
    }

    private func updateEmptyState() {
        emptyLabel.isHidden = threadID != nil
        scrollView.isHidden = threadID == nil
        compose.isHidden = threadID == nil
    }

    // MARK: - Rows

    private var bubbleMaxWidth: CGFloat {
        min(520, max(220, scrollView.contentSize.width * 0.68))
    }

    private func buildRows() -> [Row] {
        guard let threadID, let conversation = store.conversation(threadID) else { return [] }
        let messages = store.messages(in: threadID)
        let selfID = store.account?.id
        var result: [Row] = []
        let groupGap: Int64 = 5 * 60 * 1000
        var previous: ChatMessage?

        if WebHistoryImporter.shared.importing.contains(threadID) {
            result.append(.caption("Loading earlier messages from Messenger web…", .center, .secondaryLabelColor))
        } else if messages.isEmpty && conversation.isEncrypted {
            result.append(.caption(
                "🔒 End-to-end encrypted. Earlier messages appear here once they're restored in Messenger web (File → Restore Encrypted Chats…).",
                .center, .secondaryLabelColor
            ))
        }

        for (index, message) in messages.enumerated() {
            var startsSection = false
            if previous == nil || message.timestamp - (previous?.timestamp ?? 0) > 60 * 60 * 1000 {
                result.append(.separator(Formatters.separator(message.date)))
                startsSection = true
            }
            if message.isSystem {
                result.append(.caption(message.text, .center, .secondaryLabelColor))
                previous = message
                continue
            }
            let next = index + 1 < messages.count ? messages[index + 1] : nil
            let continuesPrevious = !startsSection && previous.map {
                !$0.isSystem && $0.senderID == message.senderID && message.timestamp - $0.timestamp < groupGap
            } ?? false
            let continuesToNext = next.map {
                !$0.isSystem && $0.senderID == message.senderID && $0.timestamp - message.timestamp < groupGap
            } ?? false

            var layout = MessageCellView.Layout()
            layout.maxWidth = bubbleMaxWidth
            layout.isFirstInGroup = !continuesPrevious
            if conversation.isGroup && !message.isFromMe {
                let participant = store.participant(message.senderID, in: threadID)
                layout.senderName = participant?.name ?? "Unknown"
                layout.avatarURL = participant?.avatarURL
                layout.showSenderName = !continuesPrevious
                layout.reserveAvatarSpace = true
                layout.showAvatar = !continuesToNext
            }
            result.append(.message(message, layout))
            previous = message
        }

        if let last = messages.last(where: { !$0.isSystem }), last.isFromMe, last.id == messages.last?.id {
            switch last.status {
            case .pending:
                result.append(.caption("Sending…", .trailing, .secondaryLabelColor))
            case .failed:
                result.append(.caption("Not Delivered", .trailing, .systemRed))
            default:
                let readers = conversation.participants.filter { $0.id != selfID && ($0.readWatermark ?? 0) >= last.timestamp }
                if readers.isEmpty {
                    result.append(.caption("Sent", .trailing, .secondaryLabelColor))
                } else if conversation.isGroup {
                    let names = readers.map { $0.name.split(separator: " ").first.map(String.init) ?? $0.name }
                    result.append(.caption("Seen by \(names.joined(separator: ", "))", .trailing, .secondaryLabelColor))
                } else {
                    result.append(.caption("Read", .trailing, .secondaryLabelColor))
                }
            }
        }

        if !(store.typing[threadID]?.isEmpty ?? true) {
            result.append(.typing)
        }
        return result
    }

    private var isScrolledToBottom: Bool {
        let visible = scrollView.contentView.bounds
        return visible.maxY >= tableView.bounds.height - 40
    }

    private func firstMessageID(_ rows: [Row]) -> String? {
        for row in rows {
            if case .message(let message, _) = row { return message.id }
        }
        return nil
    }

    private func reload(scrollToBottom forceBottom: Bool = false) {
        let wasAtBottom = isScrolledToBottom
        let oldFirst = firstMessageID(rows)
        let oldHeight = tableView.bounds.height
        let oldOffset = scrollView.contentView.bounds.origin.y

        rows = buildRows()
        tableView.reloadData()
        tableView.layoutSubtreeIfNeeded()

        if forceBottom || wasAtBottom {
            scrollToBottom()
        } else if oldFirst != nil, firstMessageID(rows) != oldFirst {
            // Older messages were prepended: keep the same messages on screen.
            let delta = tableView.bounds.height - oldHeight
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: oldOffset + delta))
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
    }

    private func scrollToBottom() {
        guard !rows.isEmpty else { return }
        tableView.scrollRowToVisible(rows.count - 1)
    }

    @objc private func scrolled() {
        guard let threadID, !isLoadingOlder, scrollView.contentView.bounds.minY < 200, !rows.isEmpty else { return }
        isLoadingOlder = true
        Task {
            let started = await store.loadOlderMessages(threadID)
            // Give server backfill a moment before asking again.
            try? await Task.sleep(for: .seconds(started ? 1 : 3))
            isLoadingOlder = false
        }
    }

    // MARK: - NSTableViewDataSource / Delegate

    func numberOfRows(in tableView: NSTableView) -> Int {
        rows.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        switch rows[row] {
        case .separator(let text):
            let cell = reuse("Caption", CaptionCellView.init)
            cell.configure(text, maxWidth: bubbleMaxWidth)
            return cell
        case .caption(let text, let placement, let color):
            let cell = reuse("Caption", CaptionCellView.init)
            cell.configure(text, placement: placement, color: color, maxWidth: bubbleMaxWidth)
            return cell
        case .message(let message, let layout):
            let cell = reuse("Message", MessageCellView.init)
            cell.delegate = self
            cell.configure(message, layout: layout, store: store)
            return cell
        case .typing:
            return reuse("Typing", TypingCellView.init)
        }
    }

    private func reuse<T: NSView>(_ identifier: String, _ make: () -> T) -> T {
        let id = NSUserInterfaceItemIdentifier(identifier)
        if let view = tableView.makeView(withIdentifier: id, owner: self) as? T {
            return view
        }
        let view = make()
        view.identifier = id
        return view
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        false
    }

    // MARK: - MessageCellDelegate

    func messageCell(_ cell: MessageCellView, menuFor message: ChatMessage) -> NSMenu? {
        guard !message.isUnsent, message.status != .pending else { return nil }
        let menu = NSMenu()

        let reactMenu = NSMenu()
        let mine = message.reactions.first { $0.senderID == store.account?.id }?.emoji
        for emoji in Self.reactionChoices {
            let item = NSMenuItem(title: emoji, action: #selector(reactFromMenu(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = (message, emoji)
            item.state = mine == emoji ? .on : .off
            reactMenu.addItem(item)
        }
        menu.addItem(withTitle: "React", action: nil, keyEquivalent: "").submenu = reactMenu

        let reply = menu.addItem(withTitle: "Reply", action: #selector(replyFromMenu(_:)), keyEquivalent: "")
        reply.target = self
        reply.representedObject = message

        if !message.text.isEmpty {
            let copy = menu.addItem(withTitle: "Copy", action: #selector(copyFromMenu(_:)), keyEquivalent: "")
            copy.target = self
            copy.representedObject = message
        }

        if message.isFromMe {
            menu.addItem(.separator())
            let unsend = menu.addItem(withTitle: "Unsend", action: #selector(unsendFromMenu(_:)), keyEquivalent: "")
            unsend.target = self
            unsend.representedObject = message
        }
        return menu
    }

    func messageCellDidDoubleClick(_ cell: MessageCellView, message: ChatMessage, bubble: NSView) {
        let picker = TapbackPicker(choices: Self.reactionChoices, current: message.reactions.first { $0.senderID == store.account?.id }?.emoji)
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = picker
        picker.onPick = { [weak self, weak popover] emoji in
            popover?.close()
            self?.toggleReaction(emoji, on: message)
        }
        popover.show(relativeTo: bubble.bounds, of: bubble, preferredEdge: .maxY)
    }

    func messageCell(_ cell: MessageCellView, open attachment: Attachment, of message: ChatMessage) {
        if attachment.kind == .link {
            if let string = attachment.url, let url = URL(string: string) {
                NSWorkspace.shared.open(url)
            }
            return
        }
        Task {
            do {
                let url = try await store.localFile(for: attachment, in: message)
                NSWorkspace.shared.open(url)
            } catch {
                _ = presentError(error)
            }
        }
    }

    private func toggleReaction(_ emoji: String, on message: ChatMessage) {
        let mine = message.reactions.first { $0.senderID == store.account?.id }?.emoji
        store.react(to: message, with: mine == emoji ? "" : emoji)
    }

    @objc private func reactFromMenu(_ sender: NSMenuItem) {
        guard let (message, emoji) = sender.representedObject as? (ChatMessage, String) else { return }
        toggleReaction(emoji, on: message)
    }

    @objc private func replyFromMenu(_ sender: NSMenuItem) {
        guard let message = sender.representedObject as? ChatMessage else { return }
        replyTarget = message
        let name = store.participantName(message.senderID, in: message.threadID)
        compose.showReply(to: name, text: message.text.isEmpty ? "Attachment" : message.text)
    }

    @objc private func copyFromMenu(_ sender: NSMenuItem) {
        guard let message = sender.representedObject as? ChatMessage else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(message.text, forType: .string)
    }

    @objc private func unsendFromMenu(_ sender: NSMenuItem) {
        guard let message = sender.representedObject as? ChatMessage else { return }
        store.unsend(message)
    }

    // MARK: - ComposeViewDelegate

    func composeView(_ view: ComposeView, send text: String, attachments: [URL]) {
        guard let threadID else { return }
        store.send(text: text, attachments: attachments, in: threadID, replyTo: replyTarget?.id)
        replyTarget = nil
        compose.hideReply()
        stopTyping()
        drafts[threadID] = nil
    }

    func composeViewTextDidChange(_ view: ComposeView) {
        guard let threadID else { return }
        if view.text.isEmpty {
            stopTyping()
            return
        }
        if !isTypingSent {
            isTypingSent = true
            store.setTyping(true, in: threadID)
        }
        typingStopTimer?.invalidate()
        typingStopTimer = Timer.scheduledTimer(withTimeInterval: 4, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.stopTyping() }
        }
    }

    func composeViewAttach(_ view: ComposeView) {
        guard let window = view.window else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK else { return }
            self?.compose.addFiles(panel.urls)
        }
    }

    func composeViewCancelReply(_ view: ComposeView) {
        replyTarget = nil
        compose.hideReply()
    }

    private func stopTyping() {
        typingStopTimer?.invalidate()
        typingStopTimer = nil
        guard isTypingSent, let threadID else { return }
        isTypingSent = false
        store.setTyping(false, in: threadID)
    }

}

/// Accepts files and images dragged anywhere onto the conversation; they're staged in the
/// compose field.
final class DropTargetView: NSView {
    var onDrop: ((NSPasteboard) -> Bool)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes(ComposeTextView.attachmentTypes)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        ComposeTextView.hasAttachments(sender.draggingPasteboard) ? .copy : []
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        onDrop?(sender.draggingPasteboard) ?? false
    }
}

/// Row of emoji buttons shown on double-click, like Messages' tapbacks.
final class TapbackPicker: NSViewController {
    var onPick: ((String) -> Void)?
    private let choices: [String]
    private let current: String?

    init(choices: [String], current: String?) {
        self.choices = choices
        self.current = current
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 6, bottom: 4, right: 6)
        for emoji in choices {
            let button = NSButton(title: emoji, target: self, action: #selector(picked(_:)))
            button.isBordered = false
            button.font = .systemFont(ofSize: 22)
            button.wantsLayer = true
            button.layer?.cornerRadius = 15
            if emoji == current {
                button.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.3).cgColor
            }
            button.widthAnchor.constraint(equalToConstant: 34).isActive = true
            button.heightAnchor.constraint(equalToConstant: 34).isActive = true
            stack.addArrangedSubview(button)
        }
        view = stack
    }

    @objc private func picked(_ sender: NSButton) {
        onPick?(sender.title)
    }
}
