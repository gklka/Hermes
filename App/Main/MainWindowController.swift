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
        var subtitle = ""
        switch ChatStore.shared.connectionState {
        case .connecting: subtitle = "Connecting…"
        case .disconnected: subtitle = "Waiting for network…"
        default:
            if let conversation {
                if conversation.isGroup {
                    subtitle = "\(conversation.participants.count) people"
                } else if let presence = ChatStore.shared.presence[conversation.id] {
                    subtitle = Self.presenceText(presence)
                }
            }
        }
        window.subtitle = subtitle
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

    /// Opens a chat (e.g. from a notification).
    /// Opens a chat; with `messageID`, scrolls to that message and selects it.
    func select(threadID: String, revealing messageID: String? = nil) {
        split.select(threadID: threadID, revealing: messageID)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        split.windowDidBecomeKey()
    }

    @objc private func selectFilter(_ sender: NSMenuItem) {
        guard let filter = ConversationFilter(rawValue: sender.tag) else { return }
        split.filter = filter
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(selectFilter(_:)) {
            menuItem.state = menuItem.tag == split.filter.rawValue ? .on : .off
        }
        return true
    }

    /// The filter icon is filled while a filter other than "All" is active.
    private func updateFilterItem() {
        let symbol = split.filter == .all ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill"
        filterItem?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Filter")
    }

    /// Filter and New Message belong to the sidebar, so they're hidden while it's collapsed.
    private func updateSidebarItems() {
        let collapsed = split.isSidebarCollapsed
        filterItem?.isHidden = collapsed
        newMessageToolbarItem?.isHidden = collapsed
    }

    // MARK: - NSToolbarDelegate

    private static let newMessageItem = NSToolbarItem.Identifier("newMessage")
    private static let filterItemID = NSToolbarItem.Identifier("filter")
    private weak var filterItem: NSMenuToolbarItem?
    private weak var newMessageToolbarItem: NSToolbarItem?

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.toggleSidebar, .flexibleSpace, Self.filterItemID, Self.newMessageItem, .sidebarTrackingSeparator, .flexibleSpace]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch itemIdentifier {
        case Self.newMessageItem:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.image = NSImage(systemSymbolName: "square.and.pencil", accessibilityDescription: "New Message")
            item.label = "New Message"
            item.toolTip = "New Message (⌘N)"
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
        picker.onPick = { [weak self] contact in
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
}
