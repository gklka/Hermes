import AppKit
import Combine

final class MainWindowController: NSWindowController, NSToolbarDelegate, NSWindowDelegate, NSMenuItemValidation {
    private let split: MainSplitViewController
    private var cancellables: Set<AnyCancellable> = []

    init() {
        let split = MainSplitViewController()
        self.split = split
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1040, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.minSize = NSSize(width: 640, height: 420)
        window.title = "Messenger"
        window.isReleasedWhenClosed = false
        // Reopen on the Space you're on now (like Messages), instead of switching back to the
        // Space where it was last shown.
        window.collectionBehavior.insert(.moveToActiveSpace)
        window.contentViewController = split
        window.setContentSize(NSSize(width: 1040, height: 720))
        window.center()
        window.setFrameAutosaveName("MainWindow")

        super.init(window: window)

        let toolbar = NSToolbar(identifier: "MainToolbar")
        toolbar.displayMode = .iconOnly
        toolbar.delegate = self
        window.toolbar = toolbar
        window.toolbarStyle = .unified
        window.delegate = self

        split.onConversationChanged = { [weak self] conversation in
            self?.subscribePresence(conversation)
            self?.updateTitle(conversation)
        }
        split.onFilterChanged = { [weak self] in
            self?.updateFilterItem()
        }
        split.onSidebarCollapsedChanged = { [weak self] in
            self?.updateSidebarItems()
        }
        ChatStore.shared.changes
            .sink { [weak self] change in
                guard let self else { return }
                switch change {
                case .connection:
                    // Subscriptions don't survive a reconnect.
                    self.presenceThreadID = nil
                    self.subscribePresence(self.split.selectedConversation)
                    self.updateTitle(self.split.selectedConversation)
                case .conversations:
                    self.updateTitle(self.split.selectedConversation)
                case .presence(let userID) where userID == self.split.selectedConversation?.id:
                    self.updateTitle(self.split.selectedConversation)
                default:
                    break
                }
            }
            .store(in: &cancellables)
        // Keeps "Active 5m ago" current.
        Timer.publish(every: 60, on: .main, in: .common).autoconnect()
            .sink { [weak self] _ in
                guard let self else { return }
                self.updateTitle(self.split.selectedConversation)
            }
            .store(in: &cancellables)
    }

    /// The 1:1 chat whose contact's presence we're subscribed to.
    private var presenceThreadID: String?

    private func subscribePresence(_ conversation: Conversation?) {
        guard let conversation, !conversation.isGroup, conversation.id != presenceThreadID,
              ChatStore.shared.connectionState == .connected else { return }
        presenceThreadID = conversation.id
        ChatStore.shared.subscribePresence(conversation.id)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func updateTitle(_ conversation: Conversation?) {
        guard let window else { return }
        window.title = conversation?.name ?? "Messenger"
        window.subtitle = Self.subtitle(for: conversation)
        infoToolbarItem?.isHidden = conversation?.isGroup != true
        callToolbarItems.forEach { $0.isHidden = conversation == nil }
    }

    @objc func startAudioCall(_ sender: Any?) {
        guard let conversation = split.selectedConversation else { return }
        CallManager.shared.startCall(threadID: conversation.id, video: false)
    }

    @objc func startVideoCall(_ sender: Any?) {
        guard let conversation = split.selectedConversation else { return }
        CallManager.shared.startCall(threadID: conversation.id, video: true)
    }

    /// The info button: the group chat's members.
    @objc func showMembers(_ sender: Any?) {
        guard let conversation = split.selectedConversation, conversation.isGroup else { return }
        split.presentAsSheet(MembersViewController(threadID: conversation.id))
    }

    /// The connection state, or the chat's member count or presence. Also used by chat windows.
    static func subtitle(for conversation: Conversation?) -> String {
        switch ChatStore.shared.connectionState {
        case .connecting: return "Connecting…"
        case .disconnected: return "Waiting for network…"
        default:
            guard let conversation else { return "" }
            if conversation.isGroup {
                return "\(conversation.participants.count) people"
            }
            return ChatStore.shared.presence[conversation.id].map { presenceText($0) } ?? ""
        }
    }

    private static func presenceText(_ presence: PresenceEvent) -> String {
        if presence.isOnline { return "Active now" }
        guard presence.lastSeen > 0 else { return "" }
        let date = Date(timeIntervalSince1970: TimeInterval(presence.lastSeen) / 1000)
        let minutes = Int(-date.timeIntervalSinceNow / 60)
        switch minutes {
        case ..<1: return "Active now"
        case ..<60: return "Active \(minutes)m ago"
        case ..<(24 * 60): return "Active \(minutes / 60)h ago"
        default: return "Active \(minutes / (24 * 60))d ago"
        }
    }

    @objc func focusSearch(_ sender: Any?) {
        split.focusSearch()
    }

    @objc func newMessage(_ sender: Any?) {
        split.newMessage()
    }

    @objc func attachFiles(_ sender: Any?) {
        split.attachFiles()
    }

    /// Edit → Find in Chat (⌥⌘F): search the open chat's messages.
    @objc func findInChat(_ sender: Any?) {
        split.findInChat()
    }

    /// File → Export Chat (⇧⌘E): a Markdown transcript of the open chat.
    @objc func exportChat(_ sender: Any?) {
        guard let conversation = split.selectedConversation else { return }
        ChatExport.run(threadID: conversation.id, in: window)
    }

    /// Edit → Edit Message (⌘E): the selected message, or the last one you sent.
    @objc func editMessage(_ sender: Any?) {
        split.editMessage()
    }

    /// Opens a chat (e.g. from a notification); with `messageID`, scrolls to that message and selects it.
    func select(threadID: String, revealing messageID: String? = nil) {
        split.select(threadID: threadID, revealing: messageID)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        split.windowDidBecomeKey()
    }

    @objc func toggleUnread(_ sender: Any?) {
        split.toggleUnread()
    }

    @objc func sendLike(_ sender: Any?) {
        split.sendLike()
    }

    /// Conversation › Refresh (⌘R): throws away the open chat's stored messages and loads them again.
    @objc func refreshChat(_ sender: Any?) {
        guard let threadID = split.selectedConversation?.id else { return }
        Task { await ChatStore.shared.resync(threadID) }
    }

    @objc private func selectFilter(_ sender: NSMenuItem) {
        guard let filter = ConversationFilter(rawValue: sender.tag) else { return }
        split.filter = filter
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(selectFilter(_:)):
            menuItem.state = menuItem.tag == split.filter.rawValue ? .on : .off
        case #selector(toggleUnread(_:)):
            let unread = (split.selectedConversation?.unreadCount ?? 0) > 0
            menuItem.title = unread ? "Mark as Read" : "Mark as Unread"
            return split.selectedConversation != nil
        case #selector(sendLike(_:)), #selector(editMessage(_:)), #selector(findInChat(_:)), #selector(exportChat(_:)), #selector(refreshChat(_:)),
             #selector(startAudioCall(_:)), #selector(startVideoCall(_:)):
            return split.selectedConversation != nil
        default:
            break
        }
        return true
    }

    /// The filter icon is filled while a filter other than "All" is active.
    private func updateFilterItem() {
        let symbol = split.filter == .all ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill"
        filterItem?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Filter")
    }

    /// Filter and Open Chat belong to the sidebar, so they're hidden while it's collapsed.
    private func updateSidebarItems() {
        let collapsed = split.isSidebarCollapsed
        filterItem?.isHidden = collapsed
        newMessageToolbarItem?.isHidden = collapsed
    }

    // MARK: - NSToolbarDelegate

    private static let newMessageItem = NSToolbarItem.Identifier("newMessage")
    private static let filterItemID = NSToolbarItem.Identifier("filter")
    private static let infoItem = NSToolbarItem.Identifier("info")
    private weak var filterItem: NSMenuToolbarItem?
    private weak var newMessageToolbarItem: NSToolbarItem?
    private weak var infoToolbarItem: NSToolbarItem?
    private var callToolbarItems: [NSToolbarItem] = []

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.toggleSidebar, .flexibleSpace, Self.filterItemID, Self.newMessageItem, .sidebarTrackingSeparator, .flexibleSpace,
         CallManager.audioCallItem, CallManager.videoCallItem, Self.infoItem]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch itemIdentifier {
        case Self.newMessageItem:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.image = NSImage(systemSymbolName: "square.and.pencil", accessibilityDescription: "Open Chat")
            item.label = "Open Chat"
            item.toolTip = "Open Chat (⌘O)"
            item.target = self
            item.action = #selector(newMessage(_:))
            item.isHidden = split.isSidebarCollapsed
            newMessageToolbarItem = item
            return item
        case Self.filterItemID:
            let menu = NSMenu()
            for filter in ConversationFilter.allCases {
                let menuItem = NSMenuItem(title: filter.title, action: #selector(selectFilter(_:)), keyEquivalent: "")
                menuItem.target = self
                menuItem.tag = filter.rawValue
                menu.addItem(menuItem)
            }
            let item = NSMenuToolbarItem(itemIdentifier: itemIdentifier)
            item.menu = menu
            item.showsIndicator = false
            item.label = "Filter"
            item.toolTip = "Filter Conversations"
            item.isHidden = split.isSidebarCollapsed
            filterItem = item
            updateFilterItem()
            return item
        case Self.infoItem:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.image = NSImage(systemSymbolName: "info.circle", accessibilityDescription: "Members")
            item.label = "Members"
            item.toolTip = "Members"
            item.target = self
            item.action = #selector(showMembers(_:))
            item.isHidden = split.selectedConversation?.isGroup != true
            infoToolbarItem = item
            return item
        case CallManager.audioCallItem, CallManager.videoCallItem:
            let item = CallManager.toolbarItem(itemIdentifier, target: self)
            item.isHidden = split.selectedConversation == nil
            callToolbarItems.append(item)
            return item
        default:
            return nil
        }
    }
}

final class MainSplitViewController: NSSplitViewController {
    private let list = ConversationListViewController()
    private let chat = ChatViewController()

    var onConversationChanged: ((Conversation?) -> Void)?
    var onSidebarCollapsedChanged: (() -> Void)?
    private var collapseObservation: NSKeyValueObservation?

    var isSidebarCollapsed: Bool {
        splitViewItems.first?.isCollapsed ?? false
    }

    var selectedConversation: Conversation? {
        chat.threadID.flatMap { ChatStore.shared.conversation($0) }
    }

    private static let sidebarWidthKey = "SidebarWidth"
    /// Don't save widths from the initial layout pass, before the saved one is applied.
    private var didRestoreSidebarWidth = false

    override func viewDidLoad() {
        super.viewDidLoad()

        let sidebar = NSSplitViewItem(sidebarWithViewController: list)
        sidebar.minimumThickness = 240
        sidebar.maximumThickness = 420
        sidebar.canCollapse = true
        // Keep the sidebar's width when the window is resized.
        sidebar.holdingPriority = .defaultLow + 10
        sidebar.addTopAlignedAccessoryViewController(list.searchAccessory)

        let content = NSSplitViewItem(viewController: chat)
        content.minimumThickness = 380
        content.addBottomAlignedAccessoryViewController(chat.composeAccessory)
        content.addBottomAlignedAccessoryViewController(chat.requestAccessory)
        content.addTopAlignedAccessoryViewController(chat.searchAccessory)

        addSplitViewItem(sidebar)
        addSplitViewItem(content)

        collapseObservation = sidebar.observe(\.isCollapsed) { [weak self] _, _ in
            DispatchQueue.main.async { self?.onSidebarCollapsedChanged?() }
        }

        list.onSelect = { [weak self] threadID in
            guard let self else { return }
            self.chat.show(threadID: threadID)
            self.onConversationChanged?(self.selectedConversation)
        }

        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.handleShortcut(event) else { return event }
            return nil
        }
        // Three-finger swipe up/down: the chat above/below (a swipe up has a positive deltaY).
        NSEvent.addLocalMonitorForEvents(matching: .swipe) { [weak self] event in
            guard let self, let window = self.view.window, event.window === window, window.attachedSheet == nil,
                  event.deltaY != 0, abs(event.deltaY) > abs(event.deltaX) else { return event }
            self.list.selectAdjacentConversation(event.deltaY > 0 ? -1 : 1)
            return nil
        }
    }

    /// ⌘1–⌘9 pick a chat from the list; Page Up/Down, Home and End scroll the messages even
    /// while the message field has the focus.
    private func handleShortcut(_ event: NSEvent) -> Bool {
        guard let window = view.window, event.window === window, window.attachedSheet == nil else { return false }
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        guard let character = event.charactersIgnoringModifiers?.unicodeScalars.first else { return false }
        if modifiers == .command, let digit = Int(String(character)), (1...9).contains(digit) {
            list.selectConversation(at: digit - 1)
            return true
        }
        return chat.handleScrollKey(event)
    }

    /// Conversation → Mark as Unread/Read for the open chat.
    func toggleUnread() {
        guard let conversation = selectedConversation else { return }
        ChatStore.shared.toggleRead(conversation)
    }

    func sendLike() {
        chat.sendLike()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        guard !didRestoreSidebarWidth else { return }
        let saved = UserDefaults.standard.double(forKey: Self.sidebarWidthKey)
        splitView.setPosition(saved > 0 ? saved : 300, ofDividerAt: 0)
        didRestoreSidebarWidth = true
    }

    override func splitViewDidResizeSubviews(_ notification: Notification) {
        super.splitViewDidResizeSubviews(notification)
        guard didRestoreSidebarWidth, let sidebar = splitViewItems.first, !sidebar.isCollapsed else { return }
        UserDefaults.standard.set(Double(sidebar.viewController.view.frame.width), forKey: Self.sidebarWidthKey)
    }

    func focusSearch() {
        list.focusSearch()
    }

    var filter: ConversationFilter {
        get { list.filter }
        set { list.filter = newValue }
    }

    var onFilterChanged: (() -> Void)? {
        get { list.onFilterChanged }
        set { list.onFilterChanged = newValue }
    }

    func newMessage() {
        let picker = NewMessageViewController()
        picker.onPick = { [weak self] entry in
            guard case .person(let contact) = entry else {
                self?.list.select(threadID: entry.id)
                return
            }
            Task {
                do {
                    let conversation = try await ChatStore.shared.openDirectChat(with: contact.id)
                    self?.list.select(threadID: conversation.id)
                } catch {
                    _ = self?.presentError(error)
                }
            }
        }
        presentAsSheet(picker)
    }

    func windowDidBecomeKey() {
        chat.markReadIfVisible()
        if let threadID = chat.threadID {
            Notifier.shared.clear(threadID: threadID)
        }
    }

    func select(threadID: String, revealing messageID: String? = nil) {
        if let sidebar = splitViewItems.first, sidebar.isCollapsed {
            sidebar.animator().isCollapsed = false
        }
        list.select(threadID: threadID)
        if let messageID {
            chat.reveal(messageID: messageID)
        }
    }

    func attachFiles() {
        chat.attachFiles()
    }

    func findInChat() {
        chat.startSearch()
    }

    func editMessage() {
        chat.editMessage()
    }
}
