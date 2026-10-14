import AppKit
import Combine
import ImageIO
import UniformTypeIdentifiers

final class ChatViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, MessageCellDelegate, ComposeViewDelegate {
    private(set) var threadID: String?

    private enum Row: Hashable {
        case separator(String)
        case caption(String, CaptionCellView.Placement, NSColor)
        /// "Not Delivered" under a failed message; clicking offers to resend or delete it.
        case notDelivered(ChatMessage)
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

    private static let reactionChoices = ReactionChoices.standard

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

        // The compose bar is a split view accessory (see composeAccessory); messages scroll under it.
        for view in [scrollView, emptyLabel] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: root.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            emptyLabel.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: root.centerYAnchor),
        ])
        updateEmptyState()
    }

    /// Every chat view (the main window's and those in chat windows), for app-wide callbacks.
    private static let instances = NSHashTable<ChatViewController>.weakObjects()

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
                    self.typingChanged()
                    self.reload()
                case .conversations:
                    // Participant names / read markers or the theme may have changed. Other
                    // updates (snippet, activity time, unread) happen constantly while syncing
                    // and don't change the chat, so they don't reload it.
                    let conversation = self.store.conversation(threadID)
                    let old = self.lastConversation
                    self.lastConversation = conversation
                    let changed = conversation?.participants != old?.participants
                        || conversation?.isGroup != old?.isGroup
                        || conversation?.isEncrypted != old?.isEncrypted
                        || conversation?.bubbleColors != old?.bubbleColors
                        || conversation?.quickEmoji != old?.quickEmoji
                    if changed {
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

        Self.instances.add(self)
        WebHistoryImporter.shared.onStateChange = { threadID, _ in
            for chat in Self.instances.allObjects where chat.threadID == threadID { chat.reload() }
        }
        NotificationCenter.default.addObserver(
            self, selector: #selector(restoreWindowClosed), name: NSWindow.willCloseNotification, object: WebSyncController.shared.window
        )

        // No notifications for a chat that's on screen (in the main window or its own).
        Notifier.shared.isThreadVisible = { threadID in
            Self.instances.allObjects.contains { chat in
                guard chat.threadID == threadID, let window = chat.view.window else { return false }
                return NSApp.isActive && window.isKeyWindow && !window.isMiniaturized
            }
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
        if editTarget != nil {
            // Leaving the chat cancels the edit and brings back what was typed before it.
            finishEditing()
        }
        if let current = self.threadID {
            drafts[current] = compose.hasContent ? compose.draft : nil
            stopTyping()
        }
        self.threadID = threadID
        // Find in Chat and a lingering typing bubble belong to the chat they were in.
        resetSearch()
        endTypingLinger()
        selectMessage(nil)
        pendingReveal = nil
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
        store.clearMarkedUnread(threadID)
        Notifier.shared.clear(threadID: threadID)
        compose.focus()
        store.refreshTheme(threadID)
        Task {
            await store.openThread(threadID)
            if self.threadID == threadID {
                reload(scrollToBottom: true)
                markReadIfVisible()
            }
            if store.conversation(threadID)?.isEncrypted == true {
                // An encrypted chat's theme changed while the app wasn't running only shows in
                // the web app. Read first (a few seconds): the history import can scroll back
                // for minutes and would hold the web view the whole time.
                await WebThemeReader.shared.refresh(threadID: threadID)
                WebHistoryImporter.shared.importHistory(threadID: threadID)
            }
        }
    }

    /// The compose button shows the chat's quick reaction, tinted with its theme color (a
    /// gradient's lower color, which is the one next to the compose bar).
    private func updateComposeTheme() {
        compose.setQuickReaction(lastConversation?.quickEmoji, tint: BubbleColors.theme(lastConversation?.bubbleColors).last)
    }

    func markReadIfVisible() {
        guard let threadID, let window = view.window, window.isKeyWindow, NSApp.isActive else { return }
        // Its new reactions are seen too (they count in the Dock badge).
        store.clearUnseenReactions(threadID)
        guard !store.markedUnread.contains(threadID),
              let conversation = store.conversation(threadID), conversation.unreadCount > 0 else { return }
        store.markRead(threadID)
    }

    private func updateEmptyState() {
        emptyLabel.isHidden = threadID != nil
        scrollView.isHidden = threadID == nil
        composeAccessory.isHidden = threadID == nil
        if threadID == nil { searchAccessory.isHidden = true }
    }

    /// The compose bar, at the bottom of the chat's split view item; messages scroll under it
    /// with a soft edge, like Messages.
    lazy var composeAccessory: NSSplitViewItemAccessoryViewController = {
        let accessory = NSSplitViewItemAccessoryViewController()
        accessory.view = compose
        accessory.automaticallyAppliesContentInsets = false
        if #available(macOS 26.1, *) {
            accessory.preferredScrollEdgeEffectStyle = .soft
        }
        return accessory
    }()

    // MARK: - Find in Chat

    private let searchBar = ChatSearchBar()
    /// The messages found while Find in Chat has text (shown instead of the chat's messages).
    private var searchResults: [ChatMessage]?
    private var searchTask: Task<Void, Never>?
    /// How many pages of older history a search may fetch from Messenger.
    private static let searchPageLimit = 50

    /// Find in Chat's bar, at the top of the chat's split view item (hidden until used).
    lazy var searchAccessory: NSSplitViewItemAccessoryViewController = {
        searchBar.onChange = { [weak self] text in self?.searchChanged(text) }
        searchBar.onClose = { [weak self] in self?.endSearch() }
        let accessory = NSSplitViewItemAccessoryViewController()
        accessory.view = searchBar
        accessory.automaticallyAppliesContentInsets = false
        if #available(macOS 26.1, *) {
            accessory.preferredScrollEdgeEffectStyle = .soft
        }
        accessory.isHidden = true
        return accessory
    }()

    /// Edit → Find in Chat.
    func startSearch() {
        guard threadID != nil else { return }
        searchAccessory.isHidden = false
        view.window?.makeFirstResponder(searchBar.searchField)
        searchBar.searchField.currentEditor()?.selectAll(nil)
    }

    func endSearch() {
        let wasSearching = searchResults != nil
        resetSearch()
        if wasSearching { reload(scrollToBottom: true) }
        compose.focus()
    }

    private func resetSearch() {
        searchTask?.cancel()
        searchTask = nil
        searchResults = nil
        // Back from results to the chat isn't new messages arriving.
        shownThreadID = nil
        searchBar.searchField.stringValue = ""
        searchBar.status = ""
        searchAccessory.isHidden = true
    }

    /// Searches the stored messages, then fetches older history page by page (where Messenger
    /// has it) and searches again after each, until the start, the page limit, or a new search.
    private func searchChanged(_ text: String) {
        searchTask?.cancel()
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let threadID, !text.isEmpty else {
            searchResults = nil
            shownThreadID = nil
            searchBar.status = ""
            reload(scrollToBottom: true)
            return
        }
        searchTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            var pages = 0
            var canFetch = true
            while !Task.isCancelled {
                guard let self, let page = await self.store.searchMessages(in: threadID, text: text),
                      !Task.isCancelled, self.threadID == threadID else { return }
                let fetching = canFetch && page.hasMore && pages < Self.searchPageLimit
                self.showSearchResults(page.messages, fetchingOlder: fetching)
                guard fetching, let result = await self.store.fetchOlderForSearch(threadID) else { return }
                pages += 1
                // No progress: search once more, then stop.
                canFetch = result.fetched > 0
            }
        }
    }

    private func showSearchResults(_ messages: [ChatMessage], fetchingOlder: Bool) {
        searchResults = messages
        // Results don't animate in.
        shownThreadID = nil
        let found = switch messages.count {
        case 0: "No matches"
        case 1: "1 found"
        default: "\(messages.count) found"
        }
        searchBar.status = fetchingOlder ? "\(found) · searching older…" : found
        reload(scrollToBottom: true)
    }

    // MARK: - Rows

    private var bubbleMaxWidth: CGFloat {
        min(520, max(220, scrollView.contentSize.width * 0.68))
    }

    private func buildRows() -> [Row] {
        guard let threadID, let conversation = store.conversation(threadID) else { return [] }
        // Find in Chat shows only what it found.
        let isSearching = searchResults != nil
        let messages = searchResults ?? store.messages(in: threadID)
        let selfID = store.account?.id
        var result: [Row] = []
        let groupGap: Int64 = 5 * 60 * 1000
        let outgoingColors = BubbleColors.theme(conversation.bubbleColors)
        var previous: ChatMessage?

        if isSearching {
            // The result count is in the search bar.
        } else if WebHistoryImporter.shared.importing.contains(threadID) {
            result.append(.caption("Loading earlier messages from Messenger web…", .center, .secondaryLabelColor))
        } else if conversation.isEncrypted && (messages.isEmpty || WebHistoryImporter.shared.needsRestore.contains(threadID)) {
            result.append(.restore)
        }

        for (index, message) in messages.enumerated() {
            var startsSection = false
            if isSearching {
                // Each result stands alone, under its exact time.
                result.append(.separator(Formatters.exact(message.date)))
                startsSection = true
            } else if previous == nil || message.timestamp - (previous?.timestamp ?? 0) > 60 * 60 * 1000 {
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
            let continuesToNext = !isSearching && next.map {
                !$0.isSystem && $0.senderID == message.senderID && $0.timestamp - message.timestamp < groupGap
            } ?? false

            var layout = MessageCellView.Layout()
            layout.maxWidth = bubbleMaxWidth
            layout.isFirstInGroup = !continuesPrevious
            layout.outgoingColors = outgoingColors
            layout.showsEditHistory = expandedEdits.contains(message.id)
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

        if isSearching { return result }

        if let last = messages.last(where: { !$0.isSystem }), last.isFromMe, last.id == messages.last?.id {
            switch last.status {
            case .pending:
                result.append(.caption("Sending…", .trailing, .secondaryLabelColor))
            case .failed:
                result.append(.notDelivered(last))
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

        if !(store.typing[threadID]?.isEmpty ?? true) || isTypingLingering {
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
        let wasAtBottom = isScrolledToBottom || Date() < pinnedToBottomUntil
        let anchor = forceBottom || wasAtBottom ? nil : scrollAnchor()

        // Heights depend on the bubble width; old messages' heights are kept (also across chats).
        if rowHeightsWidth != bubbleMaxWidth || rowHeights.count > 20_000 {
            rowHeights.removeAll()
            rowHeightsWidth = bubbleMaxWidth
        }
        var newRows = buildRows()
        let sameChat = shownThreadID == threadID
        // New messages (or the typing indicator) at the bottom of the chat being read animate in.
        var fresh = anchor == nil ? Self.appended(newRows, after: shownKeys, sameChat: sameChat) : []
        // A message arriving while the typing bubble showed: the bubble turns into it. (Typing
        // may have stopped before or with the message; the updates come in either order.)
        var arrivedFromTyping: (index: Int, row: Row)?
        if sameChat, shownKeys.contains("typing"), typingCellOnScreen() != nil,
           let arrived = newRows.last(where: { Self.isIncoming($0, in: fresh) }),
           let key = Self.appearanceKey(arrived) {
            endTypingLinger()
            newRows = buildRows()
            fresh.remove("typing")
            fresh.remove(key)
            if let index = newRows.firstIndex(where: { Self.appearanceKey($0) == key }) {
                arrivedFromTyping = (index, newRows[index])
                // First the chat around it, with the typing bubble still in the message's place
                // (the typing cell is unique, so it's the same cell after the reload).
                newRows[index] = .typing
            }
        }
        if !sameChat { appearing = [:] }
        let shown = Set(newRows.compactMap(Self.appearanceKey))
        // Earlier reloads' new rows keep their animation until their cells appear (a reload can
        // follow before the animated scroll brings them on screen).
        appearing = appearing.filter { shown.contains($0.key) }
        for key in fresh where appearing[key] == nil { appearing[key] = .zoom }
        shownKeys = shown
        shownThreadID = threadID
        rows = newRows
        tableView.reloadData()
        tableView.layoutSubtreeIfNeeded()
        if let arrived = arrivedFromTyping {
            finishTypingTransition(at: arrived.index, into: arrived.row)
        }

        if let anchor {
            // Keep the same messages on screen (e.g. when older ones are added above).
            restore(anchor)
        } else if forceBottom || wasAtBottom {
            scrollToBottom(animated: !fresh.isEmpty || !appearing.isEmpty || arrivedFromTyping != nil
                || Date() < pinnedToBottomUntil)
        }
        revealPendingMessage()
        alignGradients()
    }

    // MARK: - Appearance animations

    /// What the last reload showed (messages and the typing indicator), to tell what's new.
    private var shownKeys: Set<String> = []
    private var shownThreadID: String?

    private enum Appearance {
        /// Zooms up from its center.
        case zoom
    }

    /// Rows to animate when their cells appear.
    private var appearing: [String: Appearance] = [:]

    /// While an animated scroll to the bottom runs, reloads keep following the bottom (mid-way
    /// the view isn't at the bottom yet).
    private var pinnedToBottomUntil = Date.distantPast

    private static func isIncoming(_ row: Row, in keys: Set<String>) -> Bool {
        guard case .message(let message, _) = row, !message.isFromMe, !message.isSystem,
              let key = appearanceKey(row) else { return false }
        return keys.contains(key)
    }

    // MARK: - Typing bubble

    /// The typing bubble stays a little after typing stops, so a message arriving right after
    /// can take its place.
    private var typingLingerUntil: Date?
    private var typingLingerTimer: Timer?
    private static let typingLinger: TimeInterval = 2

    private var isTypingLingering: Bool {
        typingLingerUntil.map { $0 > Date() } ?? false
    }

    /// Typing started or stopped in the open chat.
    private func typingChanged() {
        guard let threadID else { return }
        if !(store.typing[threadID]?.isEmpty ?? true) {
            endTypingLinger()
        } else if shownKeys.contains("typing"), typingLingerUntil == nil {
            typingLingerUntil = Date().addingTimeInterval(Self.typingLinger)
            typingLingerTimer = Timer.scheduledTimer(withTimeInterval: Self.typingLinger, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.endTypingLinger()
                    self?.reload()
                }
            }
        }
    }

    private func endTypingLinger() {
        typingLingerTimer?.invalidate()
        typingLingerTimer = nil
        typingLingerUntil = nil
    }

    /// The typing bubble's cell, if it's on screen.
    private func typingCellOnScreen() -> MessageCellView? {
        guard let row = rows.firstIndex(where: { if case .typing = $0 { return true }; return false }) else { return nil }
        let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? MessageCellView
        return cell?.isTyping == true ? cell : nil
    }

    /// The message takes the typing bubble's row, in the same cell: the row gets the message's
    /// height and the cell animates from typing to the message (see `transitionFromTyping`).
    private func finishTypingTransition(at index: Int, into row: Row) {
        guard index < rows.count, case .message(let message, let layout) = row,
              let cell = tableView.view(atColumn: 0, row: index, makeIfNecessary: false) as? MessageCellView,
              let typing = cell.typingBubble else {
            CoreBridge.shared.log("Chat: typing → message without transition (cell not on screen)")
            // Not on screen after all: just show it.
            rows[index] = row
            tableView.reloadData(forRowIndexes: IndexSet(integer: index), columnIndexes: IndexSet(integer: 0))
            tableView.noteHeightOfRows(withIndexesChanged: IndexSet(integer: index))
            return
        }
        rows[index] = row
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            tableView.noteHeightOfRows(withIndexesChanged: IndexSet(integer: index))
        }
        tableView.layoutSubtreeIfNeeded()
        cell.delegate = self
        CoreBridge.shared.log("Chat: typing → message transition (from \(typing.size.width)×\(typing.size.height))")
        cell.transitionFromTyping(typing, to: message, layout: layout, store: store, duration: Self.typingTransition)
        appearing[Self.appearanceKey(row) ?? ""] = nil
        if let key = Self.appearanceKey(row) {
            transitioning = (key, cell, Date().addingTimeInterval(Self.typingTransition + 0.1))
        }
    }

    private static let typingTransition: TimeInterval = 0.35

    /// The cell animating from typing to the message. Reloads (e.g. the read receipt right
    /// after) get this same cell for its row until it's done; a new cell would cut it short.
    private var transitioning: (key: String, cell: MessageCellView, until: Date)?

    private func transitioningCell(for row: Row) -> MessageCellView? {
        guard let transitioning, Date() < transitioning.until else {
            self.transitioning = nil
            return nil
        }
        return Self.appearanceKey(row) == transitioning.key ? transitioning.cell : nil
    }

    /// A message keeps its key when the server confirms it (its local echo's ID), so a sent
    /// message animates once.
    private static func appearanceKey(_ row: Row) -> String? {
        switch row {
        case .message(let message, _): message.pendingID ?? message.id
        case .typing: "typing"
        default: nil
        }
    }

    /// The rows newly added at the end: a few at most (a burst is a load or sync, not arrivals),
    /// in the chat that was already showing, outside search.
    private static func appended(_ rows: [Row], after shown: Set<String>, sameChat: Bool) -> Set<String> {
        guard sameChat, !shown.isEmpty else { return [] }
        var keys: Set<String> = []
        for row in rows.reversed() {
            // Captions ("Sent", "Read") change with every receipt; they don't animate.
            guard let key = appearanceKey(row) else { continue }
            // The typing bubble stays last (it lingers), so a message arriving lands above it.
            if case .typing = row {
                if !shown.contains(key) { keys.insert(key) }
                continue
            }
            if shown.contains(key) { break }
            keys.insert(key)
            if keys.count > 3 { return [] }
        }
        return keys
    }

    func tableView(_ tableView: NSTableView, didAdd rowView: NSTableRowView, forRow row: Int) {
        guard !appearing.isEmpty, row < rows.count, let key = Self.appearanceKey(rows[row]),
              let appearance = appearing.removeValue(forKey: key),
              let cell = rowView.view(atColumn: 0) as? AppearingCell else { return }
        // Once laid out, so it starts from the bubble's real geometry.
        DispatchQueue.main.async {
            switch appearance {
            case .zoom: cell.appearingContent.animateAppearance()
            }
        }
    }

    /// A message to scroll to and select once it's loaded (from a clicked notification, a
    /// Spotlight result or a Find in Chat result).
    private var pendingReveal: String?
    /// Older pages loaded while looking for the pending message, and the most to load.
    private var revealPagesLoaded = 0
    private var revealPageLimit = 40

    /// `stored`: the message is known to be in the database (a search result), so earlier pages
    /// are loaded until it shows up, even if the chat had seemed to have no more history (the
    /// search may have fetched more since).
    func reveal(messageID: String, stored: Bool = false) {
        pendingReveal = messageID
        revealPagesLoaded = 0
        revealPageLimit = stored ? 1000 : 40
        if stored, let threadID {
            store.resetHistoryEnd(threadID)
        }
        revealPendingMessage()
    }

    private func revealPendingMessage() {
        guard let id = pendingReveal else { return }
        guard let row = rows.firstIndex(where: {
            if case .message(let message, _) = $0 { return message.id == id }
            return false
        }) else {
            // An older message (e.g. from Spotlight): load earlier pages until it shows up.
            guard let threadID, !store.messages(in: threadID).isEmpty, revealPagesLoaded < revealPageLimit else { return }
            revealPagesLoaded += 1
            Task { await store.loadOlderMessages(threadID) }
            return
        }
        pendingReveal = nil
        // In the middle of the view, with the messages around it.
        let rect = tableView.rect(ofRow: row)
        let visible = scrollView.contentView.bounds
        let y = min(max(0, rect.midY - visible.height / 2), max(0, tableView.bounds.height - visible.height))
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: y))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        selectMessage(id)
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

    private func scrollToBottom(animated: Bool = false) {
        guard !rows.isEmpty else { return }
        guard animated else {
            tableView.scrollRowToVisible(rows.count - 1)
            return
        }
        let clip = scrollView.contentView
        // The last row just above the compose bar, which overlaps the bottom (content inset).
        let insets = scrollView.contentInsets
        let bottom = tableView.bounds.height + insets.bottom - clip.bounds.height
        let origin = NSPoint(x: clip.bounds.origin.x, y: max(-insets.top, bottom))
        guard abs(origin.y - clip.bounds.origin.y) > 0.5 else { return }
        pinnedToBottomUntil = Date().addingTimeInterval(0.35)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            clip.animator().setBoundsOrigin(origin)
        } completionHandler: { [weak self] in
            guard let self else { return }
            self.scrollView.reflectScrolledClipView(clip)
        }
    }

    enum ScrollKey {
        case pageUp, pageDown, home, end
    }

    /// Page Up/Down, Home and End scroll the messages, wherever the focus is.
    func scroll(_ key: ScrollKey) {
        guard threadID != nil, !rows.isEmpty else { return }
        let clip = scrollView.contentView
        let insets = clip.contentInsets
        let page = max(clip.bounds.height - insets.top - insets.bottom - 40, 40)
        var origin = clip.bounds.origin
        switch key {
        case .pageUp: origin.y -= page
        case .pageDown: origin.y += page
        case .home: origin.y = -insets.top
        case .end: origin.y = tableView.frame.height - clip.bounds.height + insets.bottom
        }
        let target = clip.constrainBoundsRect(NSRect(origin: origin, size: clip.bounds.size)).origin
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            clip.animator().setBoundsOrigin(target)
        }
        scrollView.reflectScrolledClipView(clip)
        // Overlay scrollers only appear by themselves for trackpad and mouse scrolling.
        scrollView.flashScrollers()
    }

    /// ⌘L: sends the chat's quick reaction (like the compose button does when it's empty).
    func sendLike() {
        compose.sendQuickReaction()
    }

    @objc private func scrolled() {
        alignGradients()
        guard let threadID, !isLoadingOlder, searchResults == nil, scrollView.contentView.bounds.minY < 200, !rows.isEmpty else { return }
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
            cell.onClick = nil
            return cell
        case .notDelivered(let message):
            let cell = reuse("Caption", sizing: sizing, CaptionCellView.init)
            cell.configure("Not Delivered", placement: .trailing, color: .systemRed, maxWidth: bubbleMaxWidth)
            cell.onClick = { [weak self] in self?.messageCellDidClickFailure(message) }
            return cell
        case .restore:
            let cell = reuse("Restore", sizing: sizing, RestoreCellView.init)
            cell.configure(maxWidth: bubbleMaxWidth)
            return cell
        case .message(let message, let layout):
            let cell = (sizing ? nil : transitioningCell(for: row)) ?? reuse("Message", sizing: sizing, MessageCellView.init)
            cell.delegate = self
            cell.configure(message, layout: layout, store: store)
            cell.isMessageSelected = !sizing && message.id == selectedMessageID
            return cell
        case .typing:
            // A message cell in its typing state, under its own identifier: there's one typing
            // row, so it's the same cell across reloads and can turn into the message.
            let cell = reuse("TypingMessage", sizing: sizing, MessageCellView.init)
            var layout = MessageCellView.Layout()
            layout.maxWidth = bubbleMaxWidth
            layout.reserveAvatarSpace = threadID.flatMap { store.conversation($0) }?.isGroup ?? false
            cell.configureTyping(layout: layout)
            return cell
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

        // Tapback rows, like Messages.
        let mine = message.reactions.first { $0.senderID == store.account?.id }?.emoji
        let reactions = NSMenuItem()
        reactions.view = ReactionMenuView(
            current: mine,
            onPick: { [weak self] emoji in self?.toggleReaction(emoji, on: message) },
            onMore: { [weak self, weak cell] in
                guard let self, let cell else { return }
                self.showEmojiInput(for: message, anchor: cell.anchorView)
            }
        )
        menu.addItem(reactions)
        menu.addItem(.separator())

        let reply = menu.addItem(withTitle: "Reply", action: #selector(replyFromMenu(_:)), keyEquivalent: "")
        reply.target = self
        reply.representedObject = message

        if !message.text.isEmpty {
            let copy = menu.addItem(withTitle: "Copy", action: #selector(copyFromMenu(_:)), keyEquivalent: "")
            copy.target = self
            copy.representedObject = message
        }

        if message.isFromMe {
            if !message.text.isEmpty, message.status != .failed {
                let edit = menu.addItem(withTitle: "Edit", action: #selector(editFromMenu(_:)), keyEquivalent: "")
                edit.target = self
                edit.representedObject = message
            }
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

    // MARK: - Edits

    /// Edited messages whose earlier versions are shown.
    private var expandedEdits: Set<String> = []

    func messageCellDidToggleEdits(_ message: ChatMessage) {
        if expandedEdits.remove(message.id) == nil {
            expandedEdits.insert(message.id)
        }
        reload()
    }

    // MARK: - Selecting a message

    /// The clicked message, shown dimmed until a click lands anywhere else.
    private var selectedMessageID: String?
    private var deselectMonitor: Any?

    func messageCellDidClick(_ cell: MessageCellView, message: ChatMessage) {
        guard searchResults == nil else {
            // A found message: back to the chat, at that message.
            endSearch()
            reveal(messageID: message.id, stored: true)
            return
        }
        selectMessage(message.id)
    }

    private func selectMessage(_ id: String?) {
        guard id != selectedMessageID else { return }
        selectedMessageID = id
        let visible = tableView.rows(in: tableView.visibleRect)
        for row in visible.lowerBound..<visible.upperBound {
            guard let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? MessageCellView else { continue }
            cell.isMessageSelected = id != nil && cell.message?.id == id
        }
        if id == nil, let deselectMonitor {
            NSEvent.removeMonitor(deselectMonitor)
            self.deselectMonitor = nil
        } else if id != nil, deselectMonitor == nil {
            deselectMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
                self?.deselectUnlessInSelection(event)
                return event
            }
        }
    }

    /// Any click outside the selected message's bubble deselects it (a click on another bubble
    /// then selects that one).
    private func deselectUnlessInSelection(_ event: NSEvent) {
        guard let selectedMessageID else { return }
        if event.window === view.window {
            let visible = tableView.rows(in: tableView.visibleRect)
            for row in visible.lowerBound..<visible.upperBound {
                guard let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? MessageCellView,
                      cell.message?.id == selectedMessageID else { continue }
                let anchor = cell.anchorView
                if anchor.bounds.contains(anchor.convert(event.locationInWindow, from: nil)) { return }
            }
        }
        selectMessage(nil)
    }

    func messageCellDidClickFailure(_ message: ChatMessage) {
        guard let window = view.window else { return }
        let alert = NSAlert()
        alert.messageText = "Your message was not delivered."
        alert.informativeText = "You can try sending it again or delete it."
        alert.addButton(withTitle: "Try Again")
        alert.addButton(withTitle: "Delete").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            switch response {
            case .alertFirstButtonReturn:
                self?.store.resend(message)
            case .alertSecondButtonReturn:
                self?.store.discard(message)
            default:
                break
            }
        }
    }

    // MARK: - Sender menu

    func messageCell(_ cell: MessageCellView, menuForSenderOf message: ChatMessage) -> NSMenu? {
        guard !message.isFromMe else { return nil }
        let name = store.participant(message.senderID, in: message.threadID)?.name ?? "Unknown"
        let menu = NSMenu()
        func add(_ title: String, symbol: String, action: Selector) {
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
            item.target = self
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            item.representedObject = (message.senderID, name)
        }
        add("Message", symbol: "message", action: #selector(messageSender(_:)))
        add("View Profile", symbol: "person.crop.circle", action: #selector(viewSenderProfile(_:)))
        menu.addItem(.separator())
        add("Block…", symbol: "person.crop.circle.badge.xmark", action: #selector(blockSender(_:)))
        return menu
    }

    @objc private func messageSender(_ sender: NSMenuItem) {
        guard let (userID, _) = sender.representedObject as? (String, String) else { return }
        Task {
            do {
                let conversation = try await store.openDirectChat(with: userID)
                (view.window?.windowController as? MainWindowController)?.select(threadID: conversation.id)
            } catch {
                _ = presentError(error)
            }
        }
    }

    @objc private func viewSenderProfile(_ sender: NSMenuItem) {
        guard let (userID, _) = sender.representedObject as? (String, String),
              let url = URL(string: "https://www.facebook.com/\(userID)") else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func blockSender(_ sender: NSMenuItem) {
        guard let (userID, name) = sender.representedObject as? (String, String), let window = view.window else { return }
        let alert = NSAlert()
        alert.messageText = "Block \(name)?"
        alert.informativeText = "They won't be able to message or call you on Messenger."
        alert.addButton(withTitle: "Block").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            Task {
                do {
                    try await self?.store.block(userID: userID)
                } catch {
                    _ = self?.presentError(error)
                }
            }
        }
    }

    func messageCell(_ cell: MessageCellView, showReactionsOf message: ChatMessage, anchor: NSView) {
        let selfID = store.account?.id
        let people = message.reactions.map { reaction -> ReactionsViewController.Entry in
            let participant = store.participant(reaction.senderID, in: message.threadID)
            if reaction.senderID == selfID, let account = store.account {
                // The account itself often has no picture; your contact entry does.
                return .init(emoji: reaction.emoji, name: "You", avatarURL: participant?.avatarURL ?? account.avatarURL)
            }
            return .init(emoji: reaction.emoji, name: participant?.name ?? "Unknown", avatarURL: participant?.avatarURL)
        }
        guard !people.isEmpty else { return }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = ReactionsViewController(entries: people)
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
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

    /// Lets you react with any emoji (the "more" button in the context menu's tapback rows).
    private func showEmojiInput(for message: ChatMessage, anchor: NSView) {
        let input = EmojiInputViewController()
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = input
        input.onPick = { [weak self, weak popover] emoji in
            popover?.close()
            self?.toggleReaction(emoji, on: message)
        }
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
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
        store.clearMarkedUnread(threadID)
        if let message = editTarget {
            finishEditing()
            guard !text.isEmpty, text != message.text else { return }
            Task {
                do {
                    try await store.edit(message, text: text)
                } catch {
                    guard let window = view.window else { return }
                    let alert = NSAlert()
                    alert.messageText = "The message couldn't be edited."
                    alert.informativeText = "Messenger only allows editing a message for 15 minutes after sending it, and only five times.\n\n\(error.localizedDescription)"
                    alert.beginSheetModal(for: window, completionHandler: nil)
                }
            }
            return
        }
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
        if editTarget != nil {
            finishEditing()
            return
        }
        replyTarget = nil
        compose.hideReply()
    }

    // MARK: - Editing

    /// The sent message being edited in the compose field, and what the field held before.
    private var editTarget: ChatMessage?
    private var draftBeforeEditing: NSAttributedString?

    /// ⌘E: edits the selected message if it's yours, otherwise the last one you sent.
    func editMessage() {
        guard let threadID else { return }
        let mine = store.messages(in: threadID).filter {
            $0.isFromMe && !$0.isUnsent && !$0.isSystem && $0.status != .pending && $0.status != .failed && !$0.text.isEmpty
        }
        guard let message = mine.first(where: { $0.id == selectedMessageID }) ?? mine.last else {
            NSSound.beep()
            return
        }
        startEditing(message)
    }

    private func startEditing(_ message: ChatMessage) {
        if editTarget == nil {
            draftBeforeEditing = compose.draft
        }
        editTarget = message
        replyTarget = nil
        selectMessage(nil)
        compose.showEditing(message.text)
    }

    private func finishEditing() {
        editTarget = nil
        compose.hideReply()
        compose.draft = draftBeforeEditing ?? NSAttributedString()
        draftBeforeEditing = nil
    }

    @objc private func editFromMenu(_ sender: NSMenuItem) {
        guard let message = sender.representedObject as? ChatMessage else { return }
        startEditing(message)
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
        if event?.type == .leftMouseDown, responder is AttachmentView || responder is ReactionsBadge || responder is CaptionCellView {
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
