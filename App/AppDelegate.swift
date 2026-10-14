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
            self.showMain()
            self.mainWindowController?.select(threadID: threadID, revealing: messageID)
            NSApp.activate()
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
        if didLoadConversations, let mainWindowController {
            showMain()
            mainWindowController.select(threadID: target.threadID, revealing: target.messageID)
            NSApp.activate()
        } else {
            spotlightTarget = target
        }
        return true
    }

    /// `messengermac://share?id=…` from the share extension (ShareSupport).
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            _ = ShareSupport.shared.handle(url)
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
            item.image = Self.dockAvatar(conversation)
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
        showMain()
        mainWindowController?.select(threadID: threadID)
        NSApp.activate()
    }

    @objc private func dockNewMessage(_ sender: Any?) {
        showMain()
        NSApp.activate()
        mainWindowController?.newMessage(sender)
    }

    /// The chat's picture as loaded for the chat list, round, or initials on gray.
    private static func dockAvatar(_ conversation: Conversation) -> NSImage {
        let picture = conversation.avatarURL.flatMap(URL.init(string:)).flatMap { ImageCache.shared.cached($0) }
        let size = NSSize(width: 18, height: 18)
        return NSImage(size: size, flipped: false) { rect in
            NSBezierPath(ovalIn: rect).addClip()
            if let picture {
                picture.draw(in: rect)
            } else {
                NSColor(calibratedWhite: 0.6, alpha: 1).setFill()
                rect.fill()
                let initials = AvatarView.initials(of: conversation.name)
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 7, weight: .medium), .foregroundColor: NSColor.white,
                ]
                let textSize = initials.size(withAttributes: attributes)
                initials.draw(at: NSPoint(x: rect.midX - textSize.width / 2, y: rect.midY - textSize.height / 2), withAttributes: attributes)
            }
            return true
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { mainWindowController?.showWindow(nil) }
        return true
    }

    private func connectionChanged() {
        switch store.connectionState {
        case .loggedOut:
            didLoadConversations = false
            SpotlightIndex.shared.clear()
            ShareSupport.shared.clear()
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

    @objc func showWebSync(_ sender: Any?) {
        Task { await WebSyncController.shared.start(showWindow: true) }
    }

    @objc func logOut(_ sender: Any?) {
        Task { await store.logout() }
    }
}
