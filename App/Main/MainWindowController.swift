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
                case .connection, .conversations:
                    self.updateTitle(self.split.selectedConversation)
                default:
                    break
                }
            }
            .store(in: &cancellables)
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
                }
                if conversation.isEncrypted {
                    subtitle = subtitle.isEmpty ? "End-to-end encrypted" : subtitle + " · End-to-end encrypted"
                }
            }
        }
        window.subtitle = subtitle
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
    func select(threadID: String) {
        split.select(threadID: threadID)
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

        let content = NSSplitViewItem(viewController: chat)
        content.minimumThickness = 380

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

    func select(threadID: String) {
        if let sidebar = splitViewItems.first, sidebar.isCollapsed {
            sidebar.animator().isCollapsed = false
        }
        list.select(threadID: threadID)
    }

    func attachFiles() {
        chat.attachFiles()
    }
}
