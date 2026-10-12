import AppKit
import Combine

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
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { mainWindowController?.showWindow(nil) }
        return true
    }

    private func connectionChanged() {
        switch store.connectionState {
        case .loggedOut:
            didLoadConversations = false
            mainWindowController?.close()
            mainWindowController = nil
            showLogin()
        case .connecting, .connected, .disconnected:
            loginWindowController?.close()
            loginWindowController = nil
            showMain()
            if !didLoadConversations {
                didLoadConversations = true
                Task { await store.loadConversations() }
                WebChatImporter.shared.start()
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
