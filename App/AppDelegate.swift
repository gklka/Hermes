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
