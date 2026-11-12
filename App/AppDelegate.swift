import AppKit
import Combine
import CoreSpotlight
import Sparkle

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = ChatStore.shared
    /// Updates from the GitHub releases (Info.plist's SUFeedURL), checked daily and from
    /// Hermes › Check for Updates….
    private let updater = SPUStandardUpdaterController(startingUpdater: !DemoMode.isOn, updaterDelegate: nil, userDriverDelegate: nil)
    private var mainWindowController: MainWindowController?
    private var loginWindowController: LoginWindowController?
    private var cancellables: Set<AnyCancellable> = []
    private var didLoadConversations = false

    /// Set by the `-QuietLaunch YES` launch argument: show the app's windows without stealing
    /// focus (so a background relaunch, e.g. during development, doesn't interrupt your work).
    static let quietLaunch = UserDefaults.standard.bool(forKey: "QuietLaunch")

    /// Shows a window controller's window — quietly (ordered in, not made key, app not activated)
    /// on a quiet launch, so it doesn't take focus; normally otherwise.
    private func present(_ controller: NSWindowController?) {
        if Self.quietLaunch, let window = controller?.window {
            window.orderFront(nil)
        } else {
            controller?.showWindow(nil)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenu.build()
        Accounts.cleanUp()
        // Switched accounts to open a chat (from Spotlight or the widget).
        spotlightTarget = Accounts.takeChatToOpen()

        store.changes
            .sink { [weak self] change in
                if case .connection = change { self?.connectionChanged() }
            }
            .store(in: &cancellables)

        store.start()
        if DemoMode.isOn {
            // Sample chats only: no network, notifications or system integration.
            DemoDirector.shared.start()
            return
        }
        ConnectionWatcher.shared.start()

        Notifier.shared.onOpenThread = { [weak self] threadID, messageID in
            guard let self, self.mainWindowController != nil else { return }
            self.openChat(threadID, revealing: messageID)
        }
        Notifier.shared.start()
        DockBadge.shared.start()
        WebSyncController.shared.onRestoreFinished = { WebHistoryImporter.shared.restoreFinished() }
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
        // Spotlight has the main account's chats.
        guard Accounts.isMain else {
            if let main = Accounts.main { Accounts.switchTo(main.key, openingChat: identifier) }
            return true
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

    /// `hermes://share?id=…` from the share extension (ShareSupport).
    func application(_ application: NSApplication, open urls: [URL]) {
        // The widget and the share extension have the main account's chats: switch to it (a
        // share waits in the Outbox until then).
        if !Accounts.isMain, let main = Accounts.main {
            let chat = urls.lazy.filter { $0.host() == ShareHandoff.chatHost }
                .compactMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "id" }?.value }
                .first
            Accounts.switchTo(main.key, openingChat: chat)
            return
        }
        for url in urls {
            // The widget opens a chat with hermes://chat?id=<thread ID>.
            if url.host() == ShareHandoff.chatHost,
               let id = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "id" })?.value, !id.isEmpty {
                openChat(id)
            } else {
                ShareSupport.shared.handle(url)
            }
        }
    }

    // MARK: - Dock menu

    /// The five most recent chats (unread ones in bold), then Open Chat.
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
            if store.isUnread(conversation) {
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
        let newChat = NSMenuItem(title: "New Chat…", action: #selector(dockNewChat(_:)), keyEquivalent: "")
        newChat.target = self
        menu.addItem(newChat)
        let newMessage = NSMenuItem(title: "Open Chat…", action: #selector(dockNewMessage(_:)), keyEquivalent: "")
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

    @objc private func dockNewChat(_ sender: Any?) {
        showMain()
        NSApp.activate()
        mainWindowController?.newChat(sender)
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
            if Accounts.isMain {
                SpotlightIndex.shared.clear()
                ShareSupport.shared.clear()
            }
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
            // Only the first time: reconnecting (e.g. after a network change) leaves a closed
            // window closed.
            if mainWindowController == nil { showMain() }
            if let account = store.account, !DemoMode.isOn {
                Accounts.recordLogin(account)
                // Only the main account is in Spotlight, the share sheet and the widget.
                if Accounts.isMain {
                    SpotlightIndex.shared.start()
                    ShareSupport.shared.start()
                }
            }
            if !didLoadConversations {
                didLoadConversations = true
                Task {
                    await store.loadConversations()
                    guard !DemoMode.isOn else { return }
                    if let account = store.account {
                        await Accounts.savePicture(of: account)
                    }
                    WebHistoryImporter.shared.chatsLoaded()
                    // Launched by choosing a chat in Spotlight.
                    if let target = spotlightTarget {
                        spotlightTarget = nil
                        mainWindowController?.select(threadID: target.threadID, revealing: target.messageID)
                    }
                }
                guard !DemoMode.isOn else { return }
                WebChatImporter.shared.start()
            }
        }
    }

    private func showLogin() {
        if loginWindowController == nil {
            loginWindowController = LoginWindowController { [weak self] cookies in
                guard let self else { return }
                // An account that's already on this Mac: switch to it instead.
                if let userID = cookies["c_user"], let existing = Accounts.existing(userID: userID) {
                    Accounts.switchTo(existing.key)
                    return
                }
                Task {
                    do {
                        try await self.store.login(cookies: cookies)
                    } catch {
                        self.loginWindowController?.showError(error.localizedDescription)
                    }
                }
            }
        }
        present(loginWindowController)
        loginWindowController?.window?.center()
        if !Self.quietLaunch { NSApp.activate() }
    }

    private func showMain() {
        if mainWindowController == nil {
            mainWindowController = MainWindowController()
        }
        present(mainWindowController)
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

    @objc func toggleActivity(_ sender: Any?) {
        ActivityWindowController.shared.toggle()
    }

    /// View ▸ Prefer Nicknames: show people by their Apple Contacts nickname where they have one.
    @objc func togglePreferNicknames(_ sender: Any?) {
        ContactCards.shared.setPrefersNicknames(!ContactCards.shared.prefersNicknames)
    }

    /// Hermes › Check for Updates….
    @objc func checkForUpdates(_ sender: Any?) {
        updater.checkForUpdates(sender)
    }

    /// File › Add Account…: relaunches with a new account, which shows the login.
    @objc func addAccount(_ sender: Any?) {
        Accounts.add()
    }

    /// An account in the Account menu: relaunches with it.
    @objc func switchAccount(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String, key != Accounts.active else { return }
        Accounts.switchTo(key)
    }

    /// Asks first: logging out deletes the account and its chats from this Mac.
    @objc func logOut(_ sender: Any?) {
        guard let window = NSApp.keyWindow ?? mainWindowController?.window else {
            Task { await logOutNow() }
            return
        }
        var detail = "The account and its chats are removed from this Mac. To use it again, add it with File › Add Account…, then restore your encrypted chats with your PIN."
        // As Accounts.loggedOut picks it: the main account, or the next one.
        let others = Accounts.loggedIn.filter { $0.key != Accounts.active }
        if let next = others.first(where: { Accounts.isMainAccount($0) }) ?? others.first, let name = next.name {
            detail += "\n\nHermes then switches to \(name)."
        }
        NSAlert.confirm(
            "Log out of \(store.account?.name ?? "Messenger")?",
            detail: detail,
            button: "Log Out", in: window
        ) { [weak self] in
            await self?.logOutNow()
        }
    }

    /// Logging out also deletes the account's web app session (and its restored encrypted
    /// chats), the copies of sent files and the link previews, then the account itself:
    /// Hermes switches to another one, or shows the login if it was the only one.
    private func logOutNow() async {
        if Accounts.isMain {
            SpotlightIndex.shared.clear()
            ShareSupport.shared.clear()
        }
        await store.logout()
        await WebSyncController.shared.endSession(deletingData: true)
        OutgoingMedia.clear()
        LinkPreviews.shared.clear()
        ImageCache.shared.clear()
        LocationCardView.clearCache()
        if let next = Accounts.loggedOut() {
            Accounts.switchTo(next.key)
        }
    }
}

extension AppDelegate: NSMenuItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(togglePreferNicknames(_:)) {
            menuItem.state = ContactCards.shared.prefersNicknames ? .on : .off
        }
        if menuItem.action == #selector(logOut(_:)) {
            menuItem.title = store.account.map { "Log Out \($0.name)…" } ?? "Log Out…"
            return store.account != nil
        }
        return true
    }
}
