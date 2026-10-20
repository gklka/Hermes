import AppKit
import Combine

enum ConversationFilter: Int, CaseIterable {
    // The raw values are stored (the chosen filter), so new cases get new ones.
    case all = 0, messages = 1, groups = 3, marketplace = 2, requests = 4

    var title: String {
        switch self {
        case .all: "All"
        case .messages: "Messages"
        case .groups: "Groups"
        case .marketplace: "Marketplace"
        case .requests: "Requests"
        }
    }

    func includes(_ conversation: Conversation) -> Bool {
        // Requests only show under their own filter.
        guard self != .requests else { return conversation.isRequest }
        guard !conversation.isRequest else { return false }
        switch self {
        case .all, .requests: return true
        case .messages: return !conversation.isGroup && !conversation.isMarketplace
        case .groups: return conversation.isGroup && !conversation.isMarketplace
        case .marketplace: return conversation.isMarketplace
        }
    }
}

final class ConversationListViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate, NSMenuDelegate {
    var onSelect: ((String?) -> Void)?
    var onFilterChanged: (() -> Void)?

    private static let filterKey = "ConversationFilter"
    var filter = ConversationFilter(rawValue: UserDefaults.standard.integer(forKey: filterKey)) ?? .all {
        didSet {
            UserDefaults.standard.set(filter.rawValue, forKey: Self.filterKey)
            updateRequestsHeader()
            if filter == .requests {
                requestsExhausted = []
                Task { await store.loadRequests(requestTab) }
            }
            reload()
            onFilterChanged?()
        }
    }

    // MARK: Message requests

    /// Which request list the Requests filter shows.
    private var requestTab: RequestList = .mayKnow {
        didSet {
            requestsHeader.tab = requestTab
            if requestTab != oldValue {
                Task { await store.loadRequests(requestTab) }
                reload()
            }
        }
    }

    /// Request lists whose last page brought nothing new: they're all loaded.
    private var requestsExhausted: Set<RequestList> = []

    /// The open request list's next page (Messenger sends a few requests per page).
    private func loadMoreRequests() {
        guard filter == .requests, !isLoadingMore, !requestsExhausted.contains(requestTab) else { return }
        let tab = requestTab
        let count = { self.store.requests.count { $0.requestList == tab } }
        let before = count()
        isLoadingMore = true
        Task {
            await store.loadRequests(tab, more: true)
            // The page's chats arrive shortly after, over the connection.
            try? await Task.sleep(for: .seconds(2))
            if count() == before { requestsExhausted.insert(tab) }
            isLoadingMore = false
            reload()
        }
    }

    private lazy var requestsHeader: RequestsHeaderView = {
        let header = RequestsHeaderView()
        header.onTabChange = { [weak self] tab in self?.requestTab = tab }
        return header
    }()

    private var endsAtSearchField: NSLayoutConstraint?
    private var endsAtRequestsHeader: NSLayoutConstraint?

    /// The Requests header shows under the search field while the list shows requests.
    private func updateRequestsHeader() {
        let showsRequests = filter == .requests
        requestsHeader.isHidden = !showsRequests
        endsAtRequestsHeader?.isActive = showsRequests
        endsAtSearchField?.isActive = !showsRequests
    }

    private let store = ChatStore.shared
    private let searchField = NSSearchField()
    private let scrollView = NSScrollView()
    private let tableView = NSTableView()
    private var rows: [Conversation] = []
    private var selectedID: String?
    /// The first chat is opened once, when the list first loads after launch.
    private var didAutoSelect = false
    private var cancellables: Set<AnyCancellable> = []
    private var isLoadingMore = false

    /// The search field, shown above the sidebar's list (which scrolls under it, like Messages),
    /// with the Requests header under it while the list shows message requests.
    lazy var searchAccessory: NSSplitViewItemAccessoryViewController = {
        searchField.placeholderString = "Search"
        searchField.delegate = self
        searchField.sendsSearchStringImmediately = true
        searchField.controlSize = .large
        searchField.translatesAutoresizingMaskIntoConstraints = false
        requestsHeader.translatesAutoresizingMaskIntoConstraints = false
        let container = NSView()
        container.addSubview(searchField)
        container.addSubview(requestsHeader)
        // The bottom is the search field's, or the Requests header's while it shows.
        endsAtSearchField = container.bottomAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 8)
        endsAtRequestsHeader = container.bottomAnchor.constraint(equalTo: requestsHeader.bottomAnchor)
        NSLayoutConstraint.activate([
            searchField.topAnchor.constraint(equalTo: container.topAnchor, constant: 4),
            searchField.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            searchField.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            requestsHeader.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 10),
            requestsHeader.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            requestsHeader.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])
        updateRequestsHeader()
        let accessory = NSSplitViewItemAccessoryViewController()
        accessory.view = container
        accessory.automaticallyAppliesContentInsets = false
        if #available(macOS 26.1, *) {
            accessory.preferredScrollEdgeEffectStyle = .soft
        }
        return accessory
    }()

    override func loadView() {
        view = NSView()

        let column = NSTableColumn(identifier: .init("conversation"))
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.style = .sourceList
        tableView.rowHeight = 64
        tableView.intercellSpacing = NSSize(width: 0, height: 0)
        tableView.backgroundColor = .clear
        tableView.dataSource = self
        tableView.delegate = self
        tableView.allowsEmptySelection = true
        tableView.target = self
        tableView.doubleAction = #selector(doubleClicked(_:))
        let menu = NSMenu()
        menu.delegate = self
        tableView.menu = menu

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.automaticallyAdjustsContentInsets = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        // Full height: the list scrolls under the titlebar and the search accessory.
        view.addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        store.changes
            .sink { [weak self] change in
                switch change {
                case .conversations, .connection:
                    self?.reload()
                case .typing(let threadID):
                    self?.reloadRow(threadID)
                default:
                    break
                }
            }
            .store(in: &cancellables)

        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification, object: scrollView.contentView
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(listedChatsChanged), name: WebChatImporter.listedChatsDidChange, object: nil
        )
        // So the chats' menus know who has a contact card (only if access was given before).
        ContactCards.shared.prepare()
        NotificationCenter.default.addObserver(
            self, selector: #selector(updateLoadingRow), name: WebHistoryImporter.activityDidChange, object: WebChatImporter.shared
        )
        reload()
    }

    func focusSearch() {
        view.window?.makeFirstResponder(searchField)
    }

    /// ⌘1–⌘9: selects the nth chat in the list as it's shown (filtered and searched).
    func selectConversation(at index: Int) {
        guard index < rows.count else { return }
        tableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        tableView.scrollRowToVisible(index)
    }

    /// Three-finger swipe up/down: the chat above (-1) or below (1) the open one.
    func selectAdjacentConversation(_ offset: Int) {
        let current = selectedID.flatMap { id in rows.firstIndex { $0.id == id } }
        let index = current.map { $0 + offset } ?? 0
        guard rows.indices.contains(index) else { return }
        selectConversation(at: index)
    }

    /// Selects a conversation programmatically (e.g. after "Open Chat").
    func select(threadID: String) {
        searchField.stringValue = ""
        selectedID = threadID
        onSelect?(threadID)
        if let conversation = store.conversation(threadID) {
            if let list = conversation.requestList {
                requestTab = list
                if filter != .requests { filter = .requests }
            } else if !filter.includes(conversation) {
                filter = .all
            }
        }
        reload()
        if let index = rows.firstIndex(where: { $0.id == threadID }) {
            tableView.scrollRowToVisible(index)
        }
    }

    private func reload() {
        let query = searchField.stringValue.trimmingCharacters(in: .whitespaces)
        var conversations = filter == .requests ? store.requests : store.conversations
        // As many chats as Messenger web's list has loaded (scrolling to the bottom loads more),
        // and the open one; searching finds them all.
        let listed = WebChatImporter.shared.listedChats
        if query.isEmpty, listed > 0, filter != .requests {
            let selectedIndex = selectedID.flatMap { id in conversations.firstIndex { $0.id == id } } ?? -1
            conversations = Array(conversations.prefix(max(listed, selectedIndex + 1)))
        }
        rows = conversations.filter {
            // Ignoring case and accents: "peter" finds "Péter".
            filter.includes($0) && (filter != .requests || $0.requestList == requestTab)
                && (query.isEmpty || $0.name.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil)
        }
        showsLoadingRow = WebChatImporter.shared.isLoadingMoreChats && query.isEmpty
        tableView.reloadData()
        // A list too short to scroll can't reach its bottom: load more right away, as the web does.
        if query.isEmpty, filter == .all, listed > 0, tableView.bounds.height <= scrollView.contentView.bounds.height {
            WebChatImporter.shared.loadMore()
        }
        if query.isEmpty, filter == .requests, tableView.bounds.height <= scrollView.contentView.bounds.height {
            loadMoreRequests()
        }
        if !didAutoSelect, let first = rows.first {
            didAutoSelect = true
            if selectedID == nil {
                selectedID = first.id
                onSelect?(first.id)
            }
        }
        if let selectedID, let index = rows.firstIndex(where: { $0.id == selectedID }) {
            tableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        }
    }

    private func reloadRow(_ threadID: String) {
        guard let index = rows.firstIndex(where: { $0.id == threadID }) else { return }
        tableView.reloadData(forRowIndexes: IndexSet(integer: index), columnIndexes: IndexSet(integer: 0))
    }

    @objc private func listedChatsChanged() {
        reload()
    }

    /// A spinner row under the chats while the web list's next page loads.
    private var showsLoadingRow = false

    @objc private func updateLoadingRow() {
        let loading = WebChatImporter.shared.isLoadingMoreChats && searchField.stringValue.isEmpty
        guard loading != showsLoadingRow else { return }
        showsLoadingRow = loading
        let index = IndexSet(integer: rows.count)
        if loading {
            tableView.insertRows(at: index, withAnimation: .effectFade)
        } else {
            tableView.removeRows(at: index, withAnimation: .effectFade)
        }
    }

    @objc private func scrolled() {
        let visible = scrollView.contentView.bounds
        guard !isLoadingMore, visible.maxY > tableView.bounds.height - 400 else { return }
        if filter == .requests {
            loadMoreRequests()
            return
        }
        guard rows.count > 10 else { return }
        isLoadingMore = true
        // The web chat list's next page: it shows more chats here too.
        WebChatImporter.shared.loadMore()
        Task {
            await store.loadMoreConversations()
            try? await Task.sleep(for: .seconds(2))
            isLoadingMore = false
        }
    }

    // MARK: - Context menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let row = tableView.clickedRow
        guard row >= 0, row < rows.count else { return }
        let conversation = rows[row]
        let unread = conversation.unreadCount > 0
        menu.addItem(item("Open in New Window", symbol: "macwindow.badge.plus", action: #selector(openInWindow(_:)), conversation))
        menu.addItem(item("Open on Web", symbol: "safari", action: #selector(openOnWeb(_:)), conversation))
        menu.addItem(.separator())
        menu.addItem(item(unread ? "Mark as Read" : "Mark as Unread",
                          symbol: unread ? "envelope.open" : "envelope.badge", action: #selector(toggleUnread), conversation))
        menu.addItem(item(conversation.isMuted ? "Unmute" : "Mute",
                          symbol: conversation.isMuted ? "bell" : "bell.slash", action: #selector(toggleMute), conversation))
        if !conversation.isGroup {
            menu.addItem(item("View Profile", symbol: "person.crop.circle", action: #selector(viewProfile), conversation))
        }
        if !conversation.isGroup, !conversation.isMarketplace {
            // Enabled when the person is among the contacts (or before access was asked for).
            let contacts = ContactCards.shared
            let card = item("Show Contact Card", symbol: "person.text.rectangle", action: #selector(showContactCard), conversation)
            if !contacts.canAsk, contacts.match(userID: conversation.id, name: conversation.name) == nil {
                card.action = nil
            }
            menu.addItem(card)
        }
        menu.addItem(.separator())
        if !conversation.isGroup {
            menu.addItem(item("Block…", symbol: "person.crop.circle.badge.xmark", action: #selector(block), conversation))
        }
        if conversation.isGroup {
            menu.addItem(item("Rename Group…", symbol: "pencil", action: #selector(renameGroup), conversation))
        }
        menu.addItem(item("Delete Chat…", symbol: "trash", action: #selector(deleteChat), conversation))
        if conversation.isGroup {
            menu.addItem(item("Leave Group…", symbol: "rectangle.portrait.and.arrow.right", action: #selector(leaveGroup), conversation))
        }
    }

    private func item(_ title: String, symbol: String, action: Selector, _ conversation: Conversation) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        item.representedObject = conversation
        return item
    }

    @objc private func openInWindow(_ sender: NSMenuItem) {
        guard let conversation = sender.representedObject as? Conversation else { return }
        ChatWindowController.show(threadID: conversation.id)
    }

    @objc private func openOnWeb(_ sender: NSMenuItem) {
        guard let conversation = sender.representedObject as? Conversation else { return }
        Task { [store] in
            if let url = await store.webURL(for: conversation.id) { NSWorkspace.shared.open(url) }
        }
    }

    /// Double-clicking a chat opens it in its own window.
    @objc private func doubleClicked(_ sender: Any?) {
        let row = tableView.clickedRow
        guard row >= 0, row < rows.count else { return }
        ChatWindowController.show(threadID: rows[row].id)
    }

    @objc private func toggleUnread(_ sender: NSMenuItem) {
        guard let conversation = sender.representedObject as? Conversation else { return }
        store.toggleRead(conversation)
    }

    @objc private func toggleMute(_ sender: NSMenuItem) {
        guard let conversation = sender.representedObject as? Conversation else { return }
        store.setMuted(!conversation.isMuted, threadID: conversation.id)
    }

    @objc private func viewProfile(_ sender: NSMenuItem) {
        guard let conversation = sender.representedObject as? Conversation,
              let url = Facebook.profileURL(of: conversation.id) else { return }
        NSWorkspace.shared.open(url)
    }

    /// The person's card from the Contacts app, next to their row.
    @objc private func showContactCard(_ sender: NSMenuItem) {
        guard let conversation = sender.representedObject as? Conversation else { return }
        Task {
            guard let identifier = await ContactCards.shared.findMatch(userID: conversation.id, name: conversation.name) else {
                NSSound.beep()
                return
            }
            guard let row = rows.firstIndex(where: { $0.id == conversation.id }) else { return }
            tableView.scrollRowToVisible(row)
            ContactCards.shared.showCard(identifier, relativeTo: tableView.rect(ofRow: row), of: tableView)
        }
    }

    @objc private func block(_ sender: NSMenuItem) {
        guard let conversation = sender.representedObject as? Conversation else { return }
        confirm("Block \(conversation.name)?",
                info: "They won't be able to message or call you on Messenger.", button: "Block") { [store] in
            try await store.block(userID: conversation.id)
        }
    }

    @objc private func deleteChat(_ sender: NSMenuItem) {
        guard let conversation = sender.representedObject as? Conversation else { return }
        confirm("Delete the chat with \(conversation.name)?",
                info: "This deletes your copy of the conversation. It can't be undone.", button: "Delete") { [store] in
            try await store.deleteThread(conversation.id)
        }
    }

    @objc private func leaveGroup(_ sender: NSMenuItem) {
        guard let conversation = sender.representedObject as? Conversation else { return }
        confirm("Leave \(conversation.name)?",
                info: "You won't get messages from this group anymore.", button: "Leave") { [store] in
            try await store.leaveThread(conversation.id)
        }
    }

    @objc private func renameGroup(_ sender: NSMenuItem) {
        guard let conversation = sender.representedObject as? Conversation, let window = view.window else { return }
        let alert = NSAlert()
        alert.messageText = "Rename Group"
        alert.informativeText = "Everyone in the group sees the new name."
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = conversation.name
        field.placeholderString = "Group name"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [store] response in
            guard response == .alertFirstButtonReturn else { return }
            let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, name != conversation.name else { return }
            Task { try? await store.renameGroup(conversation.id, to: name) }
        }
    }

    private func confirm(_ message: String, info: String, button: String, action: @escaping () async throws -> Void) {
        guard let window = view.window else { return }
        NSAlert.confirm(message, detail: info, button: button, in: window, perform: action)
    }

    // MARK: - Search

    func controlTextDidChange(_ obj: Notification) {
        reload()
    }

    /// Esc clears the search and leaves the field (typing then goes to the message field).
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard control === searchField, commandSelector == #selector(NSResponder.cancelOperation(_:)) else { return false }
        searchField.stringValue = ""
        reload()
        view.window?.makeFirstResponder(nil)
        return true
    }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int {
        rows.count + (showsLoadingRow ? 1 : 0)
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        row < rows.count ? tableView.rowHeight : 44
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        row < rows.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < rows.count else {
            let spinner = NSProgressIndicator()
            spinner.style = .spinning
            spinner.controlSize = .small
            spinner.translatesAutoresizingMaskIntoConstraints = false
            spinner.startAnimation(nil)
            let cell = NSView()
            cell.addSubview(spinner)
            NSLayoutConstraint.activate([
                spinner.centerXAnchor.constraint(equalTo: cell.centerXAnchor),
                spinner.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            return cell
        }
        let id = NSUserInterfaceItemIdentifier("ConversationCell")
        let cell = tableView.makeView(withIdentifier: id, owner: self) as? ConversationCellView ?? {
            let cell = ConversationCellView()
            cell.identifier = id
            return cell
        }()
        let conversation = rows[row]
        cell.configure(conversation, isTyping: !(store.typing[conversation.id]?.isEmpty ?? true), selfID: store.account?.id)
        return cell
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        row < rows.count ? ConversationRowView() : NSTableRowView()
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = tableView.selectedRow
        let id = row >= 0 && row < rows.count ? rows[row].id : nil
        guard id != selectedID else { return }
        selectedID = id
        onSelect?(id)
    }
}

/// Keeps the selected chat in the accent color (like Messages) even while focus is in the
/// compose field, instead of turning gray.
final class ConversationRowView: NSTableRowView {
    private var observers: [NSObjectProtocol] = []

    /// The table sets this as focus moves; follow the window's key state instead.
    override var isEmphasized: Bool {
        get { super.isEmphasized }
        set { super.isEmphasized = window?.isKeyWindow ?? true }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        guard let window else { return }
        super.isEmphasized = window.isKeyWindow
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let window = self.window else { return }
                    self.isEmphasized = window.isKeyWindow
                }
            })
        }
    }
}

final class ConversationCellView: NSTableCellView {
    private let avatar = ConversationAvatarView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let dateLabel = NSTextField(labelWithString: "")
    private let snippetLabel = NSTextField(wrappingLabelWithString: "")
    private let unreadDot = NSView()
    private let mutedIcon = NSImageView()
    /// A hidden view still takes space; these collapse the muted icon when it's hidden.
    private lazy var mutedLeading = mutedIcon.leadingAnchor.constraint(equalTo: nameLabel.trailingAnchor, constant: 4)
    private lazy var mutedCollapsed = mutedIcon.widthAnchor.constraint(equalToConstant: 0)

    init() {
        super.init(frame: .zero)

        nameLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        dateLabel.font = .systemFont(ofSize: 12)
        dateLabel.textColor = .secondaryLabelColor
        dateLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        dateLabel.setContentHuggingPriority(.required, for: .horizontal)

        snippetLabel.font = .systemFont(ofSize: 12)
        snippetLabel.textColor = .secondaryLabelColor
        // Wrapping labels are selectable by default; clicks should select the row instead.
        snippetLabel.isSelectable = false
        snippetLabel.maximumNumberOfLines = 2
        // Word wrap (a truncating mode would keep each paragraph on one line), "…" on line 2.
        snippetLabel.lineBreakMode = .byWordWrapping
        snippetLabel.cell?.truncatesLastVisibleLine = true

        unreadDot.wantsLayer = true
        unreadDot.layer?.cornerRadius = 5
        unreadDot.layer?.backgroundColor = NSColor.controlAccentColor.cgColor

        mutedIcon.image = NSImage(systemSymbolName: "bell.slash.fill", accessibilityDescription: "Muted")
        mutedIcon.contentTintColor = .tertiaryLabelColor
        mutedIcon.symbolConfiguration = .init(pointSize: 10, weight: .regular)

        for view in [avatar, nameLabel, dateLabel, snippetLabel, unreadDot, mutedIcon] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            unreadDot.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            unreadDot.centerYAnchor.constraint(equalTo: centerYAnchor),
            unreadDot.widthAnchor.constraint(equalToConstant: 10),
            unreadDot.heightAnchor.constraint(equalToConstant: 10),

            avatar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            avatar.centerYAnchor.constraint(equalTo: centerYAnchor),
            avatar.widthAnchor.constraint(equalToConstant: 42),
            avatar.heightAnchor.constraint(equalToConstant: 42),

            nameLabel.leadingAnchor.constraint(equalTo: avatar.trailingAnchor, constant: 10),
            nameLabel.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            mutedLeading,
            mutedIcon.centerYAnchor.constraint(equalTo: nameLabel.centerYAnchor),
            dateLabel.leadingAnchor.constraint(greaterThanOrEqualTo: mutedIcon.trailingAnchor, constant: 6),
            dateLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            dateLabel.firstBaselineAnchor.constraint(equalTo: nameLabel.firstBaselineAnchor),

            snippetLabel.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            snippetLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            snippetLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 2),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        // A wrapping label only wraps to its preferred width; it's the space right of the avatar
        // (16 + 42 + 10 leading, 10 trailing).
        snippetLabel.preferredMaxLayoutWidth = max(0, bounds.width - 78)
        super.layout()
    }

    func configure(_ conversation: Conversation, isTyping: Bool, selfID: String?) {
        nameLabel.stringValue = conversation.name
        // Long names (groups listing their members) are cut off; hovering shows them whole.
        nameLabel.toolTip = conversation.name
        dateLabel.stringValue = Formatters.listTimestamp(conversation.lastActivityDate)
        dateLabel.toolTip = Formatters.exact(conversation.lastActivityDate)
        avatar.configure(conversation, selfID: selfID)
        unreadDot.isHidden = conversation.unreadCount == 0
        mutedIcon.isHidden = !conversation.isMuted
        mutedLeading.constant = conversation.isMuted ? 4 : 0
        mutedCollapsed.isActive = !conversation.isMuted

        if isTyping {
            snippetLabel.stringValue = "typing…"
        } else if conversation.snippetUnsent == true {
            let sender = conversation.snippetSenderID
            let who = sender == selfID ? "You"
                : conversation.participants.first { $0.id == sender }?.name ?? (conversation.isGroup ? "Someone" : conversation.name)
            snippetLabel.stringValue = "\(who) unsent a message"
        } else if conversation.snippetSenderID == selfID, !conversation.snippet.isEmpty {
            snippetLabel.stringValue = "You: \(conversation.snippet)"
        } else if conversation.snippet.isEmpty, conversation.isEncrypted {
            snippetLabel.stringValue = "End-to-end encrypted chat"
        } else {
            snippetLabel.stringValue = conversation.snippet
        }
        nameLabel.font = .systemFont(ofSize: 13, weight: conversation.unreadCount > 0 ? .bold : .semibold)
    }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet {
            // Selected rows in the sidebar use an accent-colored highlight; keep text readable.
            let emphasized = backgroundStyle == .emphasized
            nameLabel.textColor = emphasized ? .alternateSelectedControlTextColor : .labelColor
            dateLabel.textColor = emphasized ? .alternateSelectedControlTextColor : .secondaryLabelColor
            snippetLabel.textColor = emphasized ? .alternateSelectedControlTextColor : .secondaryLabelColor
            unreadDot.layer?.backgroundColor = (emphasized ? NSColor.white : NSColor.controlAccentColor).cgColor
        }
    }
}
