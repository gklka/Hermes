import AppKit
import Combine

/// A chat: its messages in a table, the compose bar under them, and Find in Chat over them.
/// The main window and chat windows each have one.
///
/// The work is split across files by topic: +Search (Find in Chat), +Animations (rows moving,
/// arriving and fading), +Scrolling, +MessageActions (menus, reactions, Quick Look) and
/// +Compose (sending, editing, typing). Their state is here, since extensions can't hold it.
final class ChatViewController: NSViewController {
    private(set) var threadID: String?

    enum Row: Hashable {
        case separator(String)
        case caption(String, CaptionCellView.Placement)
        /// "Not Delivered" under a failed message; clicking offers to resend or delete it.
        case notDelivered(ChatMessage)
        case restore
        /// A spinner: earlier messages are being loaded (from the web app, or Messenger's history).
        case loading
        case message(ChatMessage, MessageCellView.Layout)
        /// Under a message: the people whose read position it is (their last seen message).
        case readers([Participant])
        case typing
    }

    let store = ChatStore.shared
    let scrollView = NSScrollView()
    let tableView = ChatTableView()
    let compose = ComposeView()
    private let emptyLabel = NSTextField(labelWithString: "No Conversation Selected")
    var rows: [Row] = []
    private var cancellables: Set<AnyCancellable> = []
    private var lastConversation: Conversation?
    private var lastBubbleMaxWidth: CGFloat = 0

    /// Measured row heights, for the current bubble width.
    var rowHeights: [Row: CGFloat] = [:]
    private var rowHeightsWidth: CGFloat = 0
    /// Cells used only for measuring rows.
    private var sizingCells: [String: NSView] = [:]

    /// Every chat view (the main window's and those in chat windows), for app-wide callbacks.
    private static let instances = NSHashTable<ChatViewController>.weakObjects()

    // MARK: State of Find in Chat (+Search)

    let searchBar = ChatSearchBar()
    /// The messages found while Find in Chat has text (shown instead of the chat's messages).
    var searchResults: [ChatMessage]?
    var searchTask: Task<Void, Never>?

    // MARK: State of the animations (+Animations)

    /// Above the messages (under the compose bar, which isn't in this view): what fades out
    /// after its row is gone, and the read pictures flying to a new message. Rows rebuilt
    /// meanwhile can't cover them here.
    let animationOverlay = PassthroughView()
    /// The rows the last reload showed (by `rowKey`), to tell what's new, and in which chat.
    var shownKeys: Set<String> = []
    var shownThreadID: String?
    /// New rows (by `rowKey`) that zoom in when their cells appear.
    var appearing: Set<String> = []
    /// "Sending…", "Sent" and "Not Delivered" as last shown.
    var statusesShown: Set<String> = []
    /// Which message each person's read picture is under (by person ID), as last shown.
    var readerPositionsShown: [String: String] = [:]
    /// People whose picture is flying to its new place (with the flight, so an older flight
    /// landing doesn't show a newer one's picture early). Their picture there stays hidden.
    var flyingReaders: [String: UUID] = [:]
    /// The typing bubble stays a little after typing stops, so a message arriving right after
    /// can take its place.
    var typingLingerUntil: Date?
    var typingLingerTimer: Timer?
    /// The cell animating from typing to the message. Reloads (e.g. the read receipt right
    /// after) get this same cell for its row until it's done; a new cell would cut it short.
    var transitioning: (key: String, cell: MessageCellView, until: Date)?

    // MARK: State of scrolling (+Scrolling)

    var isLoadingOlder = false
    /// Loads in a row (at the top) that brought nothing older, to stop asking by itself.
    var olderLoadsWithoutNews = 0
    /// A message to scroll to and select once it's loaded (from a clicked notification, a
    /// Spotlight result or a Find in Chat result).
    var pendingReveal: String?
    /// Older pages loaded while looking for the pending message, and the most to load.
    var revealPagesLoaded = 0
    var revealPageLimit = 40

    // MARK: State of the message actions (+MessageActions)

    /// The clicked message, shown dimmed until a click lands anywhere else.
    var selectedMessageID: String?
    var deselectMonitor: Any?
    /// Edited messages whose earlier versions are shown.
    var expandedEdits: Set<String> = []
    /// The attachment shown by each Quick Look item, to zoom from its picture in the chat.
    var previewAttachmentIDs: [String] = []
    weak var previewCell: MessageCellView?
    var previewMessageID: String?
    /// Identifies the current Quick Look session, so late downloads don't touch a newer one.
    var previewSession: UUID?

    // MARK: State of the compose bar (+Compose)

    var replyTarget: ChatMessage?
    var isTypingSent = false
    var typingStopTimer: Timer?
    /// What was typed in each chat, kept when switching chats.
    var drafts: [String: NSAttributedString] = [:]
    /// The sent message being edited in the compose field, and what the field held before.
    var editTarget: ChatMessage?
    var draftBeforeEditing: NSAttributedString?

    // MARK: - Setting up

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
        for view in [scrollView, animationOverlay, emptyLabel] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: root.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            animationOverlay.topAnchor.constraint(equalTo: scrollView.topAnchor),
            animationOverlay.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor),
            animationOverlay.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor),
            animationOverlay.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor),
            emptyLabel.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: root.centerYAnchor),
        ])
        updateEmptyState()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        store.changes
            .sink { [weak self] change in self?.storeChanged(change) }
            .store(in: &cancellables)

        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification, object: scrollView.contentView
        )

        Self.instances.add(self)
        WebHistoryImporter.shared.onStateChange = { threadID in
            for chat in Self.instances.allObjects where chat.threadID == threadID { chat.reload() }
        }
        NotificationCenter.default.addObserver(
            self, selector: #selector(restoreWindowClosed), name: NSWindow.willCloseNotification, object: WebSyncController.shared.window
        )

        // No notifications for a chat that's on screen (in the main window or its own).
        Notifier.shared.isThreadVisible = { threadID in
            Self.instances.allObjects.contains { $0.threadID == threadID && $0.isOnScreen }
        }
        // Coming back to the app (its window may have stayed key) or uncovering the window: the
        // chat on screen is read now, and its notifications go.
        NotificationCenter.default.addObserver(
            self, selector: #selector(maybeBecameVisible), name: NSApplication.didBecomeActiveNotification, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(maybeBecameVisible), name: NSWindow.didChangeOcclusionStateNotification, object: nil
        )

        // Typing while no text field is active goes to the compose field. The event is returned,
        // so it's delivered to the field once it's focused (dead keys and input methods work too).
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.shouldRedirectTyping(event) else { return event }
            self.compose.focus()
            return event
        }
    }

    private func storeChanged(_ change: ChatStore.Change) {
        guard let threadID else { return }
        switch change {
        case .messages(let id) where id == threadID:
            reload()
            markReadIfVisible()
        case .typing(let id) where id == threadID:
            typingChanged()
            reload()
        case .conversations:
            // Participant names / read markers or the theme may have changed. Other updates
            // (snippet, activity time, unread) happen constantly while syncing and don't change
            // the chat, so they don't reload it.
            let conversation = store.conversation(threadID)
            let old = lastConversation
            lastConversation = conversation
            let changed = conversation?.participants != old?.participants
                || conversation?.isGroup != old?.isGroup
                || conversation?.isEncrypted != old?.isEncrypted
                || conversation?.bubbleColors != old?.bubbleColors
                || conversation?.quickEmoji != old?.quickEmoji
            if changed {
                updateComposeTheme()
                reload()
            }
        default:
            break
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

    /// After the user restored chats in the web window, pick up the chat list (every chat view
    /// asks; they wait for the same import) and retry this chat.
    @objc private func restoreWindowClosed() {
        Task {
            await WebChatImporter.shared.runOnce()
            if let threadID, WebHistoryImporter.shared.needsRestore.contains(threadID) {
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

    // MARK: - Showing a chat

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
                // Queued at once (the Activity window shows it), even while another chat is
                // being read. An encrypted chat's theme changed while the app wasn't running
                // only shows in the web app; reading it waits its turn for the page too.
                WebHistoryImporter.shared.importHistory(threadID: threadID)
                await WebThemeReader.shared.refresh(threadID: threadID)
            }
        }
    }

    /// The compose button shows the chat's quick reaction, tinted with its theme color (a
    /// gradient's lower color, which is the one next to the compose bar).
    private func updateComposeTheme() {
        compose.setQuickReaction(lastConversation?.quickEmoji, tint: BubbleColors.theme(lastConversation?.bubbleColors).last)
        updateMentionCandidates()
    }

    /// In a group chat, its other members can be tagged with @ (not in encrypted groups, whose
    /// tags the core doesn't send).
    private func updateMentionCandidates() {
        guard let conversation = lastConversation, conversation.isGroup, !conversation.isEncrypted else {
            compose.mentionCandidates = []
            return
        }
        let selfID = store.account?.id
        compose.mentionCandidates = conversation.participants
            .filter { $0.id != selfID && !$0.name.isEmpty }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            .map { MentionCandidate(id: $0.id, name: $0.name, avatarURL: $0.avatarURL) }
    }

    /// The chat is in front of the user: its window is the active app's key window, and showing.
    var isOnScreen: Bool {
        guard threadID != nil, let window = view.window else { return false }
        return NSApp.isActive && window.isKeyWindow && !window.isMiniaturized && window.occlusionState.contains(.visible)
    }

    @objc private func maybeBecameVisible(_ notification: Notification) {
        if let window = notification.object as? NSWindow, window !== view.window { return }
        guard isOnScreen, let threadID else { return }
        markReadIfVisible()
        Notifier.shared.clear(threadID: threadID)
    }

    func markReadIfVisible() {
        guard let threadID, isOnScreen else { return }
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
    lazy var composeAccessory: NSSplitViewItemAccessoryViewController = Self.accessory(compose)

    /// Find in Chat's bar, at the top of the chat's split view item (hidden until used).
    lazy var searchAccessory: NSSplitViewItemAccessoryViewController = {
        searchBar.onChange = { [weak self] text in self?.searchChanged(text) }
        searchBar.onClose = { [weak self] in self?.endSearch() }
        let accessory = Self.accessory(searchBar)
        accessory.isHidden = true
        return accessory
    }()

    private static func accessory(_ view: NSView) -> NSSplitViewItemAccessoryViewController {
        let accessory = NSSplitViewItemAccessoryViewController()
        accessory.view = view
        accessory.automaticallyAppliesContentInsets = false
        if #available(macOS 26.1, *) {
            accessory.preferredScrollEdgeEffectStyle = .soft
        }
        return accessory
    }

    // MARK: - Rows

    var bubbleMaxWidth: CGFloat {
        min(520, max(220, scrollView.contentSize.width * 0.68))
    }

    /// Messages from the same person less than this far apart form a run (one name, one picture).
    private static let runGap: Int64 = 5 * 60 * 1000
    /// A gap this long starts a new section, under its time.
    private static let sectionGap: Int64 = 60 * 60 * 1000

    private func buildRows() -> [Row] {
        guard let threadID, let conversation = store.conversation(threadID) else { return [] }
        // Find in Chat shows only what it found: each result alone, under its exact time (the
        // result count is in the search bar).
        if let searchResults {
            return searchResults.flatMap { message in
                [.separator(Formatters.exact(message.date)),
                 messageRow(message, in: conversation, continuesPrevious: false, continuesToNext: false)]
            }
        }

        let messages = store.messages(in: threadID)
        let seenAt = Self.readPositions(in: messages, of: conversation, selfID: store.account?.id)
        var result: [Row] = []
        if WebHistoryImporter.shared.isPending(threadID) {
            // Queued or being imported from the web app (e.g. still downloading after a restore).
            result.append(.loading)
        } else if conversation.isEncrypted && (messages.isEmpty || WebHistoryImporter.shared.needsRestore.contains(threadID)) {
            result.append(.restore)
        } else if !messages.isEmpty && (store.hasOlderMessages(threadID) || WebHistoryImporter.shared.hasEarlier(threadID)) {
            // Scrolling up to it loads them (scrolled()).
            result.append(.loading)
        }

        for (index, message) in messages.enumerated() {
            let previous = index > 0 ? messages[index - 1] : nil
            let next = index + 1 < messages.count ? messages[index + 1] : nil
            let startsSection = previous.map { message.timestamp - $0.timestamp > Self.sectionGap } ?? true
            if startsSection {
                result.append(.separator(Formatters.separator(message.date)))
            }
            if message.isSystem {
                result.append(.caption(message.text, .center))
                continue
            }
            result.append(messageRow(
                message, in: conversation,
                continuesPrevious: !startsSection && previous.map { Self.inSameRun($0, message) } ?? false,
                continuesToNext: next.map { Self.inSameRun(message, $0) } ?? false
            ))
            if let readers = seenAt[message.id] {
                result.append(.readers(readers))
            }
        }

        if let status = Self.statusRow(for: messages, seenAt: seenAt) {
            result.append(status)
        }
        if !(store.typing[threadID]?.isEmpty ?? true) || isTypingLingering {
            result.append(.typing)
        }
        return result
    }

    private func messageRow(_ message: ChatMessage, in conversation: Conversation, continuesPrevious: Bool, continuesToNext: Bool) -> Row {
        var layout = MessageCellView.Layout()
        layout.maxWidth = bubbleMaxWidth
        layout.isFirstInGroup = !continuesPrevious
        layout.outgoingColors = BubbleColors.theme(conversation.bubbleColors)
        layout.showsEditHistory = expandedEdits.contains(message.id)
        if conversation.isGroup && !message.isFromMe {
            let participant = store.participant(message.senderID, in: conversation.id)
            layout.senderName = participant?.name ?? "Unknown"
            layout.avatarURL = participant?.avatarURL
            layout.showSenderName = !continuesPrevious
            layout.reserveAvatarSpace = true
            layout.showAvatar = !continuesToNext
        }
        return .message(message, layout)
    }

    private static func inSameRun(_ earlier: ChatMessage, _ later: ChatMessage) -> Bool {
        !earlier.isSystem && !later.isSystem && earlier.senderID == later.senderID
            && later.timestamp - earlier.timestamp < runGap
    }

    /// The status under your message when it's the chat's last: "Sending…", "Not Delivered",
    /// or "Sent" until someone has seen it (then their picture under it says so).
    private static func statusRow(for messages: [ChatMessage], seenAt: [String: [Participant]]) -> Row? {
        guard let last = messages.last(where: { !$0.isSystem }), last.isFromMe, last.id == messages.last?.id else { return nil }
        switch last.status {
        case .pending: return .caption("Sending…", .trailing)
        case .failed: return .notDelivered(last)
        default: return seenAt[last.id] == nil ? .caption("Sent", .trailing) : nil
        }
    }

    /// Each other person's read position: the last loaded message they've seen (by their read
    /// watermark), by message ID. Not one they sent themselves: that they've seen their own
    /// message says nothing (and someone who wrote last has read everything before).
    private static func readPositions(in messages: [ChatMessage], of conversation: Conversation, selfID: String?) -> [String: [Participant]] {
        let candidates = messages.filter { !$0.isSystem && $0.status != .pending && $0.status != .failed }
        guard !candidates.isEmpty else { return [:] }
        var positions: [String: [Participant]] = [:]
        for participant in conversation.participants where participant.id != selfID {
            guard let watermark = participant.readWatermark, watermark > 0 else { continue }
            // The last message at or before the watermark (the messages are in time order).
            var low = 0, high = candidates.count
            while low < high {
                let mid = (low + high) / 2
                if candidates[mid].timestamp <= watermark { low = mid + 1 } else { high = mid }
            }
            guard low > 0 else { continue }
            let seen = candidates[low - 1]
            guard seen.senderID != participant.id else { continue }
            positions[seen.id, default: []].append(participant)
        }
        return positions
    }

    /// The row showing the message, if it's loaded.
    func rowIndex(ofMessage id: String) -> Int? {
        rows.firstIndex {
            if case .message(let message, _) = $0 { return message.id == id }
            return false
        }
    }

    /// The rows on screen (within the rows there are, also in the middle of a reload).
    var visibleRowIndices: Range<Int> {
        let range = tableView.rows(in: tableView.visibleRect)
        let upper = min(range.upperBound, rows.count)
        return min(range.lowerBound, upper)..<upper
    }

    /// The cells of one kind on screen, with their rows.
    func visibleCells<Cell: NSView>(_ type: Cell.Type) -> [(row: Int, cell: Cell)] {
        visibleRowIndices.compactMap { row in
            (tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? Cell).map { (row, $0) }
        }
    }

    // MARK: - Reloading

    /// Rebuilds the rows from the store and shows them. What was on screen stays put (or, at
    /// the bottom, the chat stays at the bottom), and what changed animates: new messages zoom
    /// in, rows that moved glide, statuses fade, read pictures fly to their new message, and a
    /// message replacing the typing bubble grows out of it.
    func reload(scrollToBottom forceBottom: Bool = false) {
        let wasAtBottom = isScrolledToBottom
        let anchor = forceBottom || wasAtBottom ? nil : scrollAnchor()

        // Heights depend on the bubble width; old messages' heights are kept (also across chats).
        if rowHeightsWidth != bubbleMaxWidth || rowHeights.count > 20_000 {
            rowHeights.removeAll()
            rowHeightsWidth = bubbleMaxWidth
        }
        // Where the read pictures and the rows are now, to animate the ones that move.
        let readerFramesBefore = readerFramesOnScreen()
        let rowsBefore = rowPositionsOnScreen()
        let statusesBefore = statusSnapshots()
        var newRows = buildRows()
        let sameChat = shownThreadID == threadID
        // New messages (or the typing indicator) at the bottom of the chat being read animate in.
        var fresh = anchor == nil ? Self.appended(newRows, after: shownKeys, sameChat: sameChat) : []
        // A message arriving while the typing bubble showed: the bubble turns into it. (Typing
        // may have stopped before or with the message; the updates come in either order.)
        var arrivedFromTyping: (index: Int, row: Row)?
        if sameChat, shownKeys.contains(Self.typingKey), typingCellOnScreen() != nil,
           let arrived = newRows.last(where: { Self.isIncoming($0, in: fresh) }),
           let key = Self.rowKey(arrived) {
            endTypingLinger()
            newRows = buildRows()
            fresh.remove(Self.typingKey)
            fresh.remove(key)
            if let index = newRows.firstIndex(where: { Self.rowKey($0) == key }) {
                arrivedFromTyping = (index, newRows[index])
                // First the chat around it, with the typing bubble still in the message's place
                // (the typing cell is unique, so it's the same cell after the reload).
                newRows[index] = .typing
            }
        }
        if !sameChat { appearing = [] }
        let shown = Set(newRows.compactMap { Self.rowKey($0) })
        // Earlier reloads' new rows keep their animation until their cells appear (a reload can
        // follow before the animated scroll brings them on screen).
        appearing = appearing.intersection(shown).union(fresh)
        shownKeys = shown
        shownThreadID = threadID
        rows = newRows
        tableView.reloadData()
        tableView.layoutSubtreeIfNeeded()
        if let arrived = arrivedFromTyping {
            finishTypingTransition(at: arrived.index, into: arrived.row)
        }
        let positions = Self.readerPositions(in: rows)
        // Moved to another message, or newly shown (e.g. replacing "Sent").
        let moved = Set(positions.compactMap { reader, messageID in
            readerPositionsShown[reader] != messageID ? reader : nil
        })
        readerPositionsShown = positions
        let statuses = Set(Self.statusKeys(in: rows).values)

        if let anchor {
            // Keep the same messages on screen (e.g. when older ones are added above).
            restore(anchor)
        } else if forceBottom || wasAtBottom {
            // At once: the rows glide from where they were instead (below).
            scrollToBottom()
        }
        // On screen positions are final now: rows glide, a gone status fades where it was.
        if sameChat {
            slideMovedRows(from: rowsBefore)
            fadeStatuses(appeared: statuses.subtracting(statusesShown), gone: statusesBefore.filter { !statuses.contains($0.key) })
        }
        statusesShown = statuses
        revealPendingMessage()
        alignGradients()
        if sameChat, !moved.isEmpty {
            slideReaders(moved, from: readerFramesBefore)
        }
    }
}

// MARK: - NSTableViewDataSource, NSTableViewDelegate

extension ChatViewController: NSTableViewDataSource, NSTableViewDelegate {
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

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        false
    }

    func tableView(_ tableView: NSTableView, didAdd rowView: NSTableRowView, forRow row: Int) {
        animateIfArriving(rowView, at: row)
    }

    /// A configured cell for the row: reused from the table, or for measuring, one kept for that.
    private func cell(for row: Row, sizing: Bool) -> NSView {
        switch row {
        case .separator(let text):
            let cell = reuse("Caption", sizing: sizing) { CaptionCellView() }
            cell.configure(text, maxWidth: bubbleMaxWidth)
            cell.onClick = nil
            return cell
        case .caption(let text, let placement):
            let cell = reuse("Caption", sizing: sizing) { CaptionCellView() }
            cell.configure(text, placement: placement, maxWidth: bubbleMaxWidth)
            cell.onClick = nil
            return cell
        case .notDelivered(let message):
            let cell = reuse("Caption", sizing: sizing) { CaptionCellView() }
            cell.configure("Not Delivered", placement: .trailing, color: .systemRed, maxWidth: bubbleMaxWidth)
            cell.onClick = { [weak self] in self?.messageCellDidClickFailure(message) }
            return cell
        case .restore:
            let cell = reuse("Restore", sizing: sizing) { RestoreCellView() }
            cell.configure(maxWidth: bubbleMaxWidth)
            return cell
        case .loading:
            return reuse("Loading", sizing: sizing) { LoadingCellView() }
        case .message(let message, let layout):
            let cell = (sizing ? nil : transitioningCell(for: row)) ?? reuse("Message", sizing: sizing) { MessageCellView() }
            cell.delegate = self
            cell.configure(message, layout: layout, store: store)
            cell.isMessageSelected = !sizing && message.id == selectedMessageID
            return cell
        case .readers(let readers):
            let cell = reuse("Readers", sizing: sizing) { ReadersCellView() }
            cell.configure(readers, hiding: sizing ? [] : Set(flyingReaders.keys))
            return cell
        case .typing:
            // A message cell in its typing state, under its own identifier: there's one typing
            // row, so it's the same cell across reloads and can turn into the message.
            let cell = reuse("TypingMessage", sizing: sizing) { MessageCellView() }
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
}
