import AppKit
import Combine
import CoreSpotlight

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = ChatStore.shared
    private var mainWindowController: MainWindowController?
    private var loginWindowController: LoginWindowController?
    private var cancellables: Set<AnyCancellable> = []
    private var didLoadConversations = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenu.build()

        store.changes
            .sink { [weak self] change in
                if case .connection = change { self?.connectionChanged() }
            }
            .store(in: &cancellables)

        store.start()

        Notifier.shared.onOpenThread = { [weak self] threadID, messageID in
            guard let self, self.mainWindowController != nil else { return }
            self.openChat(threadID, revealing: messageID)
        }
        Notifier.shared.start()
        DockBadge.shared.start()
    }

    /// A chat (and message) chosen in Spotlight before the chats were loaded.
    private var spotlightTarget: (threadID: String, messageID: String?)?

    /// A chat or message chosen in Spotlight (see SpotlightIndex). Chats are identified by their
    /// thread ID, messages by "MessageEntity/<thread ID>|<message ID>" (the entity's type, then its ID).
    func application(_ application: NSApplication, continue userActivity: NSUserActivity,
                     restorationHandler: @escaping ([any NSUserActivityRestoring]) -> Void) -> Bool {
        guard userActivity.activityType == CSSearchableItemActionType,
              var identifier = userActivity.userInfo?[CSSearchableItemActivityIdentifier] as? String else { return false }
        let entityPrefix = "MessageEntity/"
        if identifier.hasPrefix(entityPrefix) {
            identifier.removeFirst(entityPrefix.count)
        }
        let parts = identifier.split(separator: "|", maxSplits: 1).map(String.init)
        let target = (threadID: parts[0], messageID: parts.count > 1 ? parts[1] : nil)
        if didLoadConversations, mainWindowController != nil {
            openChat(target.threadID, revealing: target.messageID)
        } else {
            spotlightTarget = target
        }
        return true
    }

    /// `messengermac://share?id=…` from the share extension (ShareSupport).
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            ShareSupport.shared.handle(url)
        }
    }

    // MARK: - Dock menu

    /// The five most recent chats (unread ones in bold), then New Message.
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        guard didLoadConversations else { return nil }
        let menu = NSMenu()
        for conversation in store.conversations.filter({ !$0.name.isEmpty }).prefix(5) {
            let item = NSMenuItem(title: conversation.name, action: #selector(openDockChat(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = conversation.id
            // The picture as loaded for the chat list.
            let picture = conversation.avatarURL.flatMap(URL.init(string:)).flatMap { ImageCache.shared.cached($0) }
            item.image = RoundAvatar.image(picture, name: conversation.name, size: 18)
            if conversation.unreadCount > 0 || store.unseenReactions[conversation.id] != nil {
                item.attributedTitle = NSAttributedString(
                    string: conversation.name,
                    attributes: [.font: NSFontManager.shared.convert(.menuFont(ofSize: 0), toHaveTrait: .boldFontMask)]
                )
            }
            menu.addItem(item)
        }
        if !menu.items.isEmpty {
            menu.addItem(.separator())
        }
        let newMessage = NSMenuItem(title: "New Message", action: #selector(dockNewMessage(_:)), keyEquivalent: "")
        newMessage.target = self
        menu.addItem(newMessage)
        return menu
    }

    @objc private func openDockChat(_ sender: NSMenuItem) {
        guard let threadID = sender.representedObject as? String else { return }
        openChat(threadID)
    }

    @objc private func dockNewMessage(_ sender: Any?) {
        showMain()
        NSApp.activate()
        mainWindowController?.newMessage(sender)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { mainWindowController?.showWindow(nil) }
        return true
    }

    private func connectionChanged() {
        switch store.connectionState {
        case .loggedOut:
            // Logged out, or the session ended: nothing of the account stays on screen,
            // searchable or offered, and nothing reads its web app any more.
            didLoadConversations = false
            SpotlightIndex.shared.clear()
            ShareSupport.shared.clear()
            Notifier.shared.reset()
            WebChatImporter.shared.stop()
            WebHistoryImporter.shared.reset()
            WebThemeReader.shared.reset()
            Task { await WebSyncController.shared.endSession(deletingData: false) }
            ChatWindowController.closeAll()
            mainWindowController?.close()
            mainWindowController = nil
            showLogin()
        case .connecting, .connected, .disconnected:
            loginWindowController?.close()
            loginWindowController = nil
            showMain()
            if !didLoadConversations {
                didLoadConversations = true
                Task {
                    await store.loadConversations()
                    // Launched by choosing a chat in Spotlight.
                    if let target = spotlightTarget {
                        spotlightTarget = nil
                        mainWindowController?.select(threadID: target.threadID, revealing: target.messageID)
                    }
                }
                WebChatImporter.shared.start()
                SpotlightIndex.shared.start()
                ShareSupport.shared.start()
            }
        }
    }

    private func showLogin() {
        if loginWindowController == nil {
            loginWindowController = LoginWindowController { [weak self] cookies in
                guard let self else { return }
                Task {
                    do {
                        try await self.store.login(cookies: cookies)
                    } catch {
                        self.loginWindowController?.showError(error.localizedDescription)
                    }
                }
            }
        }
        loginWindowController?.showWindow(nil)
        loginWindowController?.window?.center()
        NSApp.activate()
    }

    private func showMain() {
        if mainWindowController == nil {
            mainWindowController = MainWindowController()
        }
        mainWindowController?.showWindow(nil)
    }

    /// Brings the main window forward with the chat (scrolled to the message) open.
    func openChat(_ threadID: String, revealing messageID: String? = nil) {
        showMain()
        mainWindowController?.select(threadID: threadID, revealing: messageID)
        NSApp.activate()
    }

    @objc func showWebSync(_ sender: Any?) {
        Task { await WebSyncController.shared.start(showWindow: true) }
    }

    /// Asks first: logging out deletes the account's chats from this Mac.
    @objc func logOut(_ sender: Any?) {
        guard let window = NSApp.keyWindow ?? mainWindowController?.window else {
            Task { await logOutNow() }
            return
        }
        NSAlert.confirm(
            "Log out of Messenger?",
            detail: "Your chats are removed from this Mac. After logging back in, you'll need your PIN to restore your encrypted chats.",
            button: "Log Out", in: window
        ) { [weak self] in
            await self?.logOutNow()
        }
    }

    /// Logging out also deletes the account's web app session (and its restored encrypted
    /// chats), the copies of sent files and the link previews.
    private func logOutNow() async {
        await store.logout()
        await WebSyncController.shared.endSession(deletingData: true)
        OutgoingMedia.clear()
        LinkPreviews.shared.clear()
    }
}
