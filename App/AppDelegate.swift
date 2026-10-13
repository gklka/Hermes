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

    /// A chat chosen in Spotlight before the chats were loaded.
    private var spotlightThreadID: String?

    /// A chat chosen in Spotlight (see SpotlightIndex).
    func application(_ application: NSApplication, continue userActivity: NSUserActivity,
                     restorationHandler: @escaping ([any NSUserActivityRestoring]) -> Void) -> Bool {
        guard userActivity.activityType == CSSearchableItemActionType,
              let threadID = userActivity.userInfo?[CSSearchableItemActivityIdentifier] as? String else { return false }
        if didLoadConversations, let mainWindowController {
            showMain()
            mainWindowController.select(threadID: threadID)
            NSApp.activate()
        } else {
            spotlightThreadID = threadID
        }
        return true
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
                    if let threadID = spotlightThreadID {
                        spotlightThreadID = nil
                        mainWindowController?.select(threadID: threadID)
                    }
                }
                WebChatImporter.shared.start()
                SpotlightIndex.shared.start()
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
