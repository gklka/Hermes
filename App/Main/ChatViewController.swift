import AppKit
import Combine
import ImageIO
import UniformTypeIdentifiers

final class ChatViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, MessageCellDelegate, ComposeViewDelegate {
    private(set) var threadID: String?

    private enum Row: Hashable {
        case separator(String)
        case caption(String, CaptionCellView.Placement, NSColor)
        case restore
        case message(ChatMessage, MessageCellView.Layout)
        case typing
    }

    /// Measured row heights, for the current bubble width.
    private var rowHeights: [Row: CGFloat] = [:]
    private var rowHeightsWidth: CGFloat = 0
    /// Cells used only for measuring rows.
    private var sizingCells: [String: NSView] = [:]

    private let store = ChatStore.shared
    private let scrollView = NSScrollView()
    private let tableView = ChatTableView()
    private let compose = ComposeView()
    private let emptyLabel = NSTextField(labelWithString: "No Conversation Selected")
    private var rows: [Row] = []
    private var cancellables: Set<AnyCancellable> = []
    private var lastBubbleMaxWidth: CGFloat = 0
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
        root.onStartLiveResize = {
            WebSyncController.shared.leaveWindowForLiveResize()
        }
        root.onEndLiveResize = { [weak self] in
            WebSyncController.shared.returnAfterLiveResize()
            self?.reloadIfBubbleWidthChanged()
        }
        view = root
        WebSyncController.shared.embedInvisibly(in: root)

        let column = NSTableColumn(identifier: .init("message"))
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.usesAutomaticRowHeights = false
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
                        self.updateComposeTheme()
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
        NotificationCenter.default.addObserver(
            self, selector: #selector(restoreWindowClosed), name: NSWindow.willCloseNotification, object: WebSyncController.shared.window
        )

        // No notifications for the chat that's on screen.
        Notifier.shared.isThreadVisible = { [weak self] threadID in
            guard let self, self.threadID == threadID, let window = self.view.window else { return false }
            return NSApp.isActive && window.isKeyWindow && !window.isMiniaturized
        }

        // Typing while no text field is active goes to the compose field. The event is returned,
        // so it's delivered to the field once it's focused (dead keys and input methods work too).
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.shouldRedirectTyping(event) else { return event }
            self.compose.focus()
            return event
        }
    }

    private func shouldRedirectTyping(_ event: NSEvent) -> Bool {
        guard threadID != nil, let window = view.window, event.window === window, window.attachedSheet == nil else { return false }
        if let text = window.firstResponder as? NSTextView, text.isEditable {
            return false
        }
        // ⌘V pastes into the message field too.
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if modifiers == .command, event.charactersIgnoringModifiers?.lowercased() == "v" {
            return true
        }
        guard modifiers.intersection([.command, .control]).isEmpty else { return false }
        // Printable characters only: no Return, Tab, Esc, Delete, arrows or function keys.
        guard let characters = event.charactersIgnoringModifiers, !characters.isEmpty else { return false }
        return characters.unicodeScalars.allSatisfy { scalar in
            scalar.value >= 0x20 && scalar.value != 0x7F && !(0xF700...0xF8FF).contains(scalar.value)
        }
    }

    /// After the user restored chats in the web window, pick up the chat list and retry this chat.
    @objc private func restoreWindowClosed() {
        guard let threadID, WebHistoryImporter.shared.needsRestore.contains(threadID) else { return }
        Task {
            await WebChatImporter.shared.runOnce()
            if self.threadID == threadID {
                WebHistoryImporter.shared.importHistory(threadID: threadID)
            }
        }
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        // Reloading re-measures every row, far too slow for each step of a live resize; the
        // bubbles keep their width until the resize ends.
        if !view.inLiveResize {
            reloadIfBubbleWidthChanged()
        }
    }

    /// Bubble widths depend on the chat's width (up to a maximum), so reload when they change.
    private func reloadIfBubbleWidthChanged() {
        let width = bubbleMaxWidth
        guard abs(width - lastBubbleMaxWidth) > 1 else { return }
        lastBubbleMaxWidth = width
        // Defer so we don't re-enter layout from inside viewDidLayout.
        DispatchQueue.main.async { [weak self] in self?.reload() }
    }

    // MARK: - Showing a thread

    func show(threadID: String?) {
        if let current = self.threadID {
            drafts[current] = compose.hasContent ? compose.draft : nil
            stopTyping()
        }
        self.threadID = threadID
        lastConversation = threadID.flatMap { store.conversation($0) }
        updateComposeTheme()
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
        Notifier.shared.clear(threadID: threadID)
        compose.focus()
        Task {
            await store.openThread(threadID)
            if self.threadID == threadID {
                reload(scrollToBottom: true)
                markReadIfVisible()
            }
            // Theme first (a few seconds): the history import can scroll back for minutes and
            // would hold the web view the whole time.
            await WebThemeReader.shared.refresh(threadID: threadID)
            if store.conversation(threadID)?.isEncrypted == true {
                WebHistoryImporter.shared.importHistory(threadID: threadID)
            }
        }
    }

    /// The compose button shows the chat's quick reaction, tinted with its theme color.
    private func updateComposeTheme() {
        compose.setQuickReaction(lastConversation?.quickEmoji, tint: BubbleColors.theme(lastConversation?.bubbleColors).first)
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
        let outgoingColors = BubbleColors.theme(conversation.bubbleColors)
        var previous: ChatMessage?

        if WebHistoryImporter.shared.importing.contains(threadID) {
            result.append(.caption("Loading earlier messages from Messenger web…", .center, .secondaryLabelColor))
        } else if conversation.isEncrypted && (messages.isEmpty || WebHistoryImporter.shared.needsRestore.contains(threadID)) {
            result.append(.restore)
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
            layout.outgoingColors = outgoingColors
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

    /// The first message on screen and how far its top is from the top of the visible area.
    private struct ScrollAnchor {
        let messageID: String
        let offset: CGFloat
    }

    /// With `changedRow`, the first message below that row (so a row growing at the top of the
    /// screen pushes what's above it up, instead of what's below it down).
    private func scrollAnchor(below changedRow: Int? = nil) -> ScrollAnchor? {
        let visible = scrollView.contentView.bounds
        let range = tableView.rows(in: visible)
        let start = max(range.lowerBound, changedRow.map { $0 + 1 } ?? 0)
        guard start < range.upperBound else { return nil }
        for row in start..<range.upperBound where rows.indices.contains(row) {
            if case .message(let message, _) = rows[row] {
                return ScrollAnchor(messageID: message.id, offset: tableView.rect(ofRow: row).minY - visible.minY)
            }
        }
        return nil
    }

    /// Scrolls so the anchor message is back where it was on screen.
    private func restore(_ anchor: ScrollAnchor) {
        guard let row = rows.firstIndex(where: {
            if case .message(let message, _) = $0 { return message.id == anchor.messageID }
            return false
        }) else { return }
        let y = tableView.rect(ofRow: row).minY - anchor.offset
        guard abs(y - scrollView.contentView.bounds.minY) > 0.5 else { return }
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: y))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    private func reload(scrollToBottom forceBottom: Bool = false) {
        let wasAtBottom = isScrolledToBottom
        let anchor = forceBottom || wasAtBottom ? nil : scrollAnchor()

        // Heights depend on the bubble width; old messages' heights are kept (also across chats).
        if rowHeightsWidth != bubbleMaxWidth || rowHeights.count > 20_000 {
            rowHeights.removeAll()
            rowHeightsWidth = bubbleMaxWidth
        }
        rows = buildRows()
        tableView.reloadData()
        tableView.layoutSubtreeIfNeeded()

        if let anchor {
            // Keep the same messages on screen (e.g. when older ones are added above).
            restore(anchor)
        } else if forceBottom || wasAtBottom {
            scrollToBottom()
        }
        alignGradients()
    }

    /// Gradient themes span the visible chat, so visible bubbles are realigned as it scrolls.
    private func alignGradients() {
        guard let threadID, (store.conversation(threadID)?.bubbleColors?.count ?? 0) > 1 else { return }
        let visible = tableView.rows(in: scrollView.contentView.bounds)
        for row in visible.lowerBound..<visible.upperBound {
            if let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? MessageCellView {
                cell.alignGradient(to: scrollView.contentView)
            }
        }
    }

    private func scrollToBottom() {
        guard !rows.isEmpty else { return }
        tableView.scrollRowToVisible(rows.count - 1)
    }

    @objc private func scrolled() {
        alignGradients()
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
        cell(for: rows[row], sizing: false)
    }

    /// Every row is measured up front (and cached), so the chat's height is exact and scrolling
    /// back doesn't jump as rows get measured (as with automatic row heights).
    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        if let height = rowHeights[rows[row]] { return height }
        let cell = cell(for: rows[row], sizing: true)
        let width = cell.widthAnchor.constraint(equalToConstant: max(tableView.bounds.width, scrollView.contentSize.width))
        width.isActive = true
        let height = max(1, cell.fittingSize.height.rounded(.up))
        width.isActive = false
        rowHeights[rows[row]] = height
        return height
    }

    /// A configured cell for the row: reused from the table, or for measuring, one kept for that.
    private func cell(for row: Row, sizing: Bool) -> NSView {
        switch row {
        case .separator(let text):
            let cell = reuse("Caption", sizing: sizing, CaptionCellView.init)
            cell.configure(text, maxWidth: bubbleMaxWidth)
            return cell
        case .caption(let text, let placement, let color):
            let cell = reuse("Caption", sizing: sizing, CaptionCellView.init)
            cell.configure(text, placement: placement, color: color, maxWidth: bubbleMaxWidth)
            return cell
        case .restore:
            let cell = reuse("Restore", sizing: sizing, RestoreCellView.init)
            cell.configure(maxWidth: bubbleMaxWidth)
            return cell
        case .message(let message, let layout):
            let cell = reuse("Message", sizing: sizing, MessageCellView.init)
            cell.delegate = self
            cell.configure(message, layout: layout, store: store)
            return cell
        case .typing:
            return reuse("Typing", sizing: sizing, TypingCellView.init)
        }
    }

    private func reuse<T: NSView>(_ identifier: String, sizing: Bool, _ make: () -> T) -> T {
        if sizing {
            if let cell = sizingCells[identifier] as? T { return cell }
            let cell = make()
            sizingCells[identifier] = cell
            return cell
        }
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

    func messageCellDidLoadLinkPreview(messageID: String) {
        let isThisMessage = { (row: Row) -> Bool in
            if case .message(let message, _) = row { return message.id == messageID }
            return false
        }
        guard let row = rows.firstIndex(where: isThisMessage) else {
            // Measured in another chat (heights are kept across chats).
            rowHeights = rowHeights.filter { !isThisMessage($0.key) }
            return
        }
        let oldHeight = rowHeights.removeValue(forKey: rows[row])
        guard tableView(tableView, heightOfRow: row) != oldHeight else { return }
        let wasAtBottom = isScrolledToBottom
        // Rows below the screen don't move what's shown.
        let anchor = wasAtBottom ? nil : scrollAnchor(below: row)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            tableView.noteHeightOfRows(withIndexesChanged: IndexSet(integer: row))
        }
        tableView.layoutSubtreeIfNeeded()
        if let anchor {
            restore(anchor)
        } else if wasAtBottom {
            scrollToBottom()
        }
    }

    func messageCell(_ cell: MessageCellView, open attachment: Attachment, of message: ChatMessage) {
        if attachment.kind == .link {
            if let string = attachment.url, let url = URL(string: string) {
                NSWorkspace.shared.open(url)
            }
            return
        }
        // Quick Look with all of the message's attachments, starting at the clicked one. Pictures
        // not downloaded yet show the low-res version from the chat until the full one arrives.
        let attachments = message.attachments.filter { $0.kind != .link }
        Task {
            var items: [MediaViewer.Item] = []
            var ids: [String] = []
            var pending: [Attachment] = []
            var startIndex = 0
            for item in attachments {
                let isPicture = [.image, .gif, .sticker].contains(item.kind)
                var viewerItem: MediaViewer.Item?
                if let downloaded = store.downloadedFile(for: item, in: message) {
                    viewerItem = MediaViewer.Item(
                        url: downloaded, title: Self.title(of: item),
                        pixelSize: isPicture ? Self.localPixelSize(downloaded) : Self.videoSize(of: item)
                    )
                } else if isPicture, let image = cell.attachmentView(for: item.id)?.displayedImage?
                            .cgImage(forProposedRect: nil, context: nil, hints: nil) {
                    let size = await finalPixelSize(of: item, in: message, thumbnail: image)
                    if let preview = await Self.writeQuickLookPreview(image, finalSize: size, attachmentID: item.id) {
                        viewerItem = MediaViewer.Item(url: preview, title: Self.title(of: item), pixelSize: size)
                        pending.append(item)
                    }
                }
                if viewerItem == nil {
                    do {
                        let url = try await store.localFile(for: item, in: message)
                        viewerItem = MediaViewer.Item(
                            url: url, title: Self.title(of: item),
                            pixelSize: isPicture ? Self.localPixelSize(url) : Self.videoSize(of: item)
                        )
                    } catch {
                        if item.id == attachment.id {
                            _ = presentError(error)
                            return
                        }
                        CoreBridge.shared.log("Quick Look: attachment \(item.id) unavailable: \(error)")
                    }
                }
                guard let viewerItem else { continue }
                if item.id == attachment.id { startIndex = items.count }
                items.append(viewerItem)
                ids.append(item.id)
            }
            previewCell = cell
            previewMessageID = message.id
            previewAttachmentIDs = ids
            let session = UUID()
            previewSession = session
            MediaViewer.shared.show(items, at: startIndex, over: view.window) { [weak self] index in
                self?.zoomSource(forItemAt: index)
            }

            for item in pending {
                do {
                    let url = try await store.localFile(for: item, in: message)
                    if session == previewSession, let index = previewAttachmentIDs.firstIndex(of: item.id) {
                        MediaViewer.shared.replaceItem(at: index, with: url)
                    }
                } catch {
                    CoreBridge.shared.log("Quick Look: full-size \(item.id) unavailable, keeping the preview: \(error)")
                }
            }
        }
    }

    private static func title(of attachment: Attachment) -> String {
        if let filename = attachment.filename, !filename.isEmpty { return filename }
        switch attachment.kind {
        case .image: return "Photo"
        case .gif: return "GIF"
        case .sticker: return "Sticker"
        case .video: return "Video"
        case .audio: return "Voice Message"
        case .file, .link: return "File"
        }
    }

    /// A downloaded picture's pixel size (reading just its header).
    private static func localPixelSize(_ url: URL) -> CGSize? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int, width > 0, height > 0 else { return nil }
        let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
        return orientation >= 5 ? CGSize(width: height, height: width) : CGSize(width: width, height: height)
    }

    /// A video's window size: its reported shape (the preview's), at least 960 points on the long side.
    private static func videoSize(of attachment: Attachment) -> CGSize? {
        guard attachment.kind == .video, let width = attachment.width, let height = attachment.height,
              width > 0, height > 0 else { return nil }
        let scale = max(1, 960 / CGFloat(max(width, height)))
        return CGSize(width: CGFloat(width) * scale, height: CGFloat(height) * scale)
    }

    /// The full-size picture's pixel size, so the preview opens Quick Look at its final size.
    /// Encrypted chats report it; regular chats only report the preview's size, so it's read from
    /// the full image's header, or else guessed from the thumbnail's shape.
    private func finalPixelSize(of attachment: Attachment, in message: ChatMessage, thumbnail: CGImage) async -> CGSize {
        let reported = CGSize(width: attachment.width ?? 0, height: attachment.height ?? 0)
        let hasReported = reported.width > 0 && reported.height > 0
        let encrypted = store.conversation(message.threadID)?.isEncrypted ?? false
        if encrypted && hasReported {
            return reported
        }
        if !encrypted, let string = attachment.url, let url = URL(string: string), url.scheme?.hasPrefix("http") == true,
           let probed = await Self.probePixelSize(url) {
            return probed
        }
        // Guess: the thumbnail's shape at Messenger's usual full size (2048 px on the long side).
        let shape = hasReported ? reported : CGSize(width: thumbnail.width, height: thumbnail.height)
        let longSide = max(2048, max(reported.width, reported.height))
        let scale = longSide / max(shape.width, shape.height)
        return CGSize(width: (shape.width * scale).rounded(), height: (shape.height * scale).rounded())
    }

    /// Reads an image's pixel size from the start of its file (the header), without downloading it all.
    @concurrent nonisolated private static func probePixelSize(_ url: URL) async -> CGSize? {
        var request = URLRequest(url: url, timeoutInterval: 1.5)
        request.setValue("bytes=0-65535", forHTTPHeaderField: "Range")
        guard let (data, _) = try? await URLSession.shared.data(for: request) else { return nil }
        if let size = headerPixelSize(data) {
            return size
        }
        // Other formats: ImageIO, which needs the whole file (small files come back whole).
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int, width > 0, height > 0 else { return nil }
        // EXIF orientations 5–8 are rotated by 90°, which swaps the shown width and height.
        let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
        return orientation >= 5 ? CGSize(width: height, height: width) : CGSize(width: width, height: height)
    }

    /// Pixel size from the first bytes of a JPEG, PNG or WebP file (Facebook serves full-size
    /// photos as WebP). ImageIO wants much more of the file than the header to tell the size.
    nonisolated private static func headerPixelSize(_ data: Data) -> CGSize? {
        let b = [UInt8](data.prefix(65536))
        func be16(_ i: Int) -> Int { Int(b[i]) << 8 | Int(b[i + 1]) }
        func le16(_ i: Int) -> Int { Int(b[i]) | Int(b[i + 1]) << 8 }
        func le24(_ i: Int) -> Int { Int(b[i]) | Int(b[i + 1]) << 8 | Int(b[i + 2]) << 16 }
        func size(_ w: Int, _ h: Int) -> CGSize? { w > 0 && h > 0 ? CGSize(width: w, height: h) : nil }
        // PNG: the IHDR chunk.
        if b.count >= 24, b[0] == 0x89, b[1] == 0x50, b[2] == 0x4E, b[3] == 0x47 {
            return size(be16(16) << 16 | be16(18), be16(20) << 16 | be16(22))
        }
        // WebP: "RIFF....WEBP", then a VP8 / VP8L / VP8X chunk.
        if b.count >= 30, b[0] == 0x52, b[1] == 0x49, b[2] == 0x46, b[3] == 0x46,
           b[8] == 0x57, b[9] == 0x45, b[10] == 0x42, b[11] == 0x50 {
            switch (b[12], b[13], b[14], b[15]) {
            case (0x56, 0x50, 0x38, 0x20): // "VP8 " (lossy)
                return size(le16(26) & 0x3FFF, le16(28) & 0x3FFF)
            case (0x56, 0x50, 0x38, 0x4C): // "VP8L" (lossless)
                let bits = Int(b[21]) | Int(b[22]) << 8 | Int(b[23]) << 16 | Int(b[24]) << 24
                return size((bits & 0x3FFF) + 1, ((bits >> 14) & 0x3FFF) + 1)
            case (0x56, 0x50, 0x38, 0x58): // "VP8X" (extended)
                return size(le24(24) + 1, le24(27) + 1)
            default:
                return nil
            }
        }
        // JPEG: the first start-of-frame marker.
        guard b.count > 4, b[0] == 0xFF, b[1] == 0xD8 else { return nil }
        var i = 2
        while i + 9 < b.count {
            guard b[i] == 0xFF else { return nil }
            let marker = b[i + 1]
            if marker == 0xFF { i += 1; continue }
            if marker == 0x01 || (0xD0...0xD8).contains(marker) { i += 2; continue }
            if (0xC0...0xCF).contains(marker), ![0xC4, 0xC8, 0xCC].contains(marker) {
                return size(be16(i + 7), be16(i + 5))
            }
            i += 2 + be16(i + 2)
        }
        return nil
    }

    /// Writes the chat's low-res picture, scaled up to the full picture's size, to a temporary
    /// file Quick Look can show. At the final size, Quick Look opens its window at the size it
    /// keeps when the full picture replaces it.
    @concurrent nonisolated private static func writeQuickLookPreview(_ image: CGImage, finalSize: CGSize, attachmentID: String) async -> URL? {
        // Large enough for any screen while keeping the aspect ratio exact.
        let scale = min(1, 6000 / max(finalSize.width, finalSize.height))
        let width = max(1, Int((finalSize.width * scale).rounded()))
        let height = max(1, Int((finalSize.height * scale).rounded()))
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let scaled = context.makeImage() else { return nil }

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("QuickLookPreviews", isDirectory: true)
        let name = attachmentID.replacingOccurrences(of: "/", with: "_")
        let url = directory.appendingPathComponent("\(name)-preview.jpg")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            return nil
        }
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        let properties: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: 0.8,
            kCGImagePropertyDPIWidth: 72,
            kCGImagePropertyDPIHeight: 72,
        ]
        CGImageDestinationAddImage(destination, scaled, properties as CFDictionary)
        return CGImageDestinationFinalize(destination) ? url : nil
    }

    // MARK: - Quick Look

    /// The attachment shown by each viewer item, to zoom from its picture in the chat.
    private var previewAttachmentIDs: [String] = []
    private weak var previewCell: MessageCellView?
    private var previewMessageID: String?
    /// Identifies the current viewer session, so late downloads don't touch a newer one.
    private var previewSession: UUID?

    /// Where viewer item `index`'s picture is in the chat (on screen), while it's visible.
    private func zoomSource(forItemAt index: Int) -> (frame: NSRect, image: NSImage)? {
        guard previewAttachmentIDs.indices.contains(index),
              let cell = previewCell, cell.message?.id == previewMessageID,
              let view = cell.attachmentView(for: previewAttachmentIDs[index]), let window = view.window,
              let image = view.displayedImage else { return nil }
        // Only while it's visible in the message list (cells are reused once scrolled away).
        let rect = view.convert(view.bounds, to: scrollView.contentView)
        guard scrollView.contentView.bounds.intersects(rect) else { return nil }
        return (window.convertToScreen(view.convert(view.bounds, to: nil)), image)
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

    /// File → Attach Files…: stages the chosen files in the compose field.
    func attachFiles() {
        guard threadID != nil, let window = view.window else { return }
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

/// The message table. A table view keeps mouse-downs for itself (row tracking) unless the
/// clicked subview opts in, so attachments get them here and can be dragged out.
final class ChatTableView: NSTableView {
    override func validateProposedFirstResponder(_ responder: NSResponder, for event: NSEvent?) -> Bool {
        if event?.type == .leftMouseDown, responder is AttachmentView {
            return true
        }
        return super.validateProposedFirstResponder(responder, for: event)
    }
}

/// Accepts files and images dragged anywhere onto the conversation; they're staged in the
/// compose field.
final class DropTargetView: NSView {
    var onDrop: ((NSPasteboard) -> Bool)?
    var onStartLiveResize: (() -> Void)?
    var onEndLiveResize: (() -> Void)?

    override func viewWillStartLiveResize() {
        super.viewWillStartLiveResize()
        onStartLiveResize?()
    }

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        onEndLiveResize?()
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes(ComposeTextView.attachmentTypes)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        ComposeTextView.hasAttachments(sender.draggingPasteboard) ? .copy : []
    }

    // Called continuously during the drag; without it the drop isn't accepted.
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        draggingEntered(sender)
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
