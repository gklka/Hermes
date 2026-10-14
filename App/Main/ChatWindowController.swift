import AppKit
import Combine

/// A chat in its own window, without the sidebar: double-click a chat in the list (or its context
/// menu's Open in New Window). One window per chat; opening it again brings it to the front.
final class ChatWindowController: NSWindowController, NSWindowDelegate, NSMenuItemValidation, NSToolbarDelegate {
    private static var open: [String: ChatWindowController] = [:]

    static func show(threadID: String) {
        let controller = open[threadID] ?? ChatWindowController(threadID: threadID)
        open[threadID] = controller
        controller.showWindow(nil)
        NSApp.activate()
    }

    /// After logging out.
    static func closeAll() {
        for controller in open.values { controller.close() }
    }

    private let threadID: String
    private let chat = ChatViewController()
    private var cancellables: Set<AnyCancellable> = []
    private var keyMonitor: Any?

    private init(threadID: String) {
        self.threadID = threadID
        let split = NSSplitViewController()
        let item = NSSplitViewItem(viewController: chat)
        item.minimumThickness = 380
        // The compose bar sits at the bottom of the split view item, as in the main window.
        item.addBottomAlignedAccessoryViewController(chat.composeAccessory)
        item.addTopAlignedAccessoryViewController(chat.searchAccessory)
        split.addSplitViewItem(item)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.minSize = NSSize(width: 380, height: 420)
        window.isReleasedWhenClosed = false
        window.contentViewController = split
        window.setContentSize(NSSize(width: 560, height: 720))
        // The chat's picture, name and status in the titlebar (the header item below), as tall
        // as the main window's.
        window.titleVisibility = .hidden
        window.toolbarStyle = .unified
        super.init(window: window)
        let toolbar = NSToolbar(identifier: "ChatWindowToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        window.toolbar = toolbar
        window.delegate = self
        // Each chat keeps its window's frame; a new one cascades from the key window.
        if !window.setFrameUsingName(Self.frameName(threadID)) {
            window.center()
            if let key = NSApp.keyWindow {
                window.setFrameTopLeftPoint(NSPoint(x: key.frame.minX + 28, y: key.frame.maxY - 28))
            }
        }
        window.setFrameAutosaveName(Self.frameName(threadID))

        chat.loadViewIfNeeded()
        chat.show(threadID: threadID)
        updateTitle()
        if let conversation = ChatStore.shared.conversation(threadID), !conversation.isGroup,
           ChatStore.shared.connectionState == .connected {
            ChatStore.shared.subscribePresence(threadID)
        }

        ChatStore.shared.changes
            .sink { [weak self] change in
                guard let self else { return }
                switch change {
                case .connection:
                    // Subscriptions don't survive a reconnect.
                    if ChatStore.shared.connectionState == .connected { ChatStore.shared.subscribePresence(self.threadID) }
                    self.updateTitle()
                case .conversations:
                    // The chat was deleted or left.
                    if ChatStore.shared.conversation(self.threadID) == nil { self.close() } else { self.updateTitle() }
                case .presence(let userID) where userID == self.threadID:
                    self.updateTitle()
                default:
                    break
                }
            }
            .store(in: &cancellables)
        // Keeps "Active 5m ago" current.
        Timer.publish(every: 60, on: .main, in: .common).autoconnect()
            .sink { [weak self] _ in self?.updateTitle() }
            .store(in: &cancellables)

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.handleScrollKey(event) else { return event }
            return nil
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private static func frameName(_ threadID: String) -> String { "ChatWindow-\(threadID)" }

    private var conversation: Conversation? { ChatStore.shared.conversation(threadID) }

    private func updateTitle() {
        let conversation = conversation
        // Still the window's title, for the Window menu and Mission Control.
        window?.title = conversation?.name ?? "Messenger"
        let subtitle = MainWindowController.subtitle(for: conversation)
        header.nameLabel.stringValue = conversation?.name ?? ""
        header.subtitleLabel.stringValue = subtitle
        header.subtitleLabel.isHidden = subtitle.isEmpty
        if let conversation {
            header.avatar.configure(conversation, selfID: ChatStore.shared.account?.id)
        }
    }

    // MARK: - Header

    private let header = ChatHeaderView()
    private static let headerItem = NSToolbarItem.Identifier("chatHeader")

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Self.headerItem, .flexibleSpace]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard itemIdentifier == Self.headerItem else { return nil }
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        item.view = header
        item.label = "Chat"
        item.isBordered = false
        return item
    }

    /// Page Up/Down, Home and End scroll the messages even while the message field has the focus.
    private func handleScrollKey(_ event: NSEvent) -> Bool {
        guard let window, event.window === window, window.attachedSheet == nil,
              event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty,
              let character = event.charactersIgnoringModifiers?.unicodeScalars.first else { return false }
        let key: ChatViewController.ScrollKey? = switch Int(character.value) {
        case NSPageUpFunctionKey: .pageUp
        case NSPageDownFunctionKey: .pageDown
        case NSHomeFunctionKey: .home
        case NSEndFunctionKey: .end
        default: nil
        }
        guard let key else { return false }
        chat.scroll(key)
        return true
    }

    // MARK: - NSWindowDelegate

    func windowDidBecomeKey(_ notification: Notification) {
        chat.markReadIfVisible()
        Notifier.shared.clear(threadID: threadID)
    }

    func windowWillClose(_ notification: Notification) {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        cancellables.removeAll()
        // Stops the typing indicator, as when switching chats.
        chat.show(threadID: nil)
        Self.open[threadID] = nil
    }

    // MARK: - Menu commands (as in the main window)

    @objc func attachFiles(_ sender: Any?) {
        chat.attachFiles()
    }

    @objc func findInChat(_ sender: Any?) {
        chat.startSearch()
    }

    @objc func exportChat(_ sender: Any?) {
        ChatExport.run(threadID: threadID, in: window)
    }

    @objc func editMessage(_ sender: Any?) {
        chat.editMessage()
    }

    @objc func sendLike(_ sender: Any?) {
        chat.sendLike()
    }

    @objc func toggleUnread(_ sender: Any?) {
        guard let conversation else { return }
        if conversation.unreadCount > 0 {
            ChatStore.shared.markRead(threadID)
        } else {
            ChatStore.shared.setUnread(true, threadID: threadID)
        }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(toggleUnread(_:)) {
            menuItem.title = (conversation?.unreadCount ?? 0) > 0 ? "Mark as Read" : "Mark as Unread"
        }
        return conversation != nil
    }
}

/// The chat window's titlebar content: the chat's picture, then its name over its status.
private final class ChatHeaderView: NSView {
    let avatar = ConversationAvatarView()
    let nameLabel = NSTextField(labelWithString: "")
    let subtitleLabel = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        nameLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        nameLabel.lineBreakMode = .byTruncatingTail
        subtitleLabel.font = .systemFont(ofSize: 11)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.lineBreakMode = .byTruncatingTail
        for label in [nameLabel, subtitleLabel] {
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }

        let labels = NSStackView(views: [nameLabel, subtitleLabel])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 0
        let row = NSStackView(views: [avatar, labels])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            avatar.widthAnchor.constraint(equalToConstant: 26),
            avatar.heightAnchor.constraint(equalToConstant: 26),
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: 30),
            widthAnchor.constraint(lessThanOrEqualToConstant: 360),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}
