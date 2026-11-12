import AppKit
import WebKit

/// The Messenger accounts on this Mac (File › Add Account…, the Account menu). The app runs one
/// at a time, the active one, chosen at launch; switching relaunches it. Each has its own data
/// folder, web view data and account-specific settings (`defaultsKey`). The first one keeps the
/// original places (Application Support/Hermes, the web view's first data store, settings without
/// a suffix). The main account (the first to log in) is the only one in Spotlight, Siri and
/// Shortcuts, the share sheet and the widget.
nonisolated struct StoredAccount: Codable, Hashable {
    /// Names its data folder, Application Support/Hermes/Accounts/<key> (empty: Hermes itself).
    let key: String
    let webStoreID: UUID
    /// Set once it has logged in.
    var userID: String?
    var name: String?
}

nonisolated enum Accounts {
    private static let listKey = "Accounts"
    private static let activeKey = "ActiveAccount"
    private static let mainKey = "MainAccount"
    private static let chatToOpenKey = "AccountChatToOpen"
    private static let removedWebStoresKey = "RemovedWebStores"
    private static var defaults: UserDefaults { .standard }

    static let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Hermes", isDirectory: true)
    /// The web view's data store from before there were accounts.
    private static let firstWebStoreID = UUID(uuidString: "6F1C2B7E-4E1A-4C55-9B7A-2D0E7F9A1C31")!

    static var all: [StoredAccount] {
        get { defaults.data(forKey: listKey).flatMap { try? JSONDecoder().decode([StoredAccount].self, from: $0) } ?? [] }
        set { defaults.set(try? JSONEncoder().encode(newValue), forKey: listKey) }
    }

    /// The ones that have logged in, as the Account menu lists them.
    static var loggedIn: [StoredAccount] { all.filter { $0.userID != nil } }

    /// The key of the account this run of the app is for.
    static let active: String = {
        var list = all
        if list.isEmpty {
            list = [StoredAccount(key: "", webStoreID: firstWebStoreID)]
            all = list
        }
        let key = list.first { $0.key == defaults.string(forKey: activeKey) }?.key ?? list[0].key
        defaults.set(key, forKey: activeKey)
        return key
    }()

    static var current: StoredAccount? { all.first { $0.key == active } }

    static func folder(for key: String) -> URL {
        key.isEmpty ? root : root.appendingPathComponent("Accounts/\(key)", isDirectory: true)
    }

    static var webStoreID: UUID { current?.webStoreID ?? firstWebStoreID }

    /// A setting of the active account's (the first one's are without a suffix).
    static func defaultsKey(_ key: String) -> String {
        active.isEmpty ? key : "\(key).\(active)"
    }

    /// Whether the active account is the main one, in Spotlight, Siri and Shortcuts.
    static var isMain: Bool { DemoMode.isOn || defaults.string(forKey: mainKey) == active }

    static func isMainAccount(_ account: StoredAccount) -> Bool { defaults.string(forKey: mainKey) == account.key }

    static var main: StoredAccount? { all.first { isMainAccount($0) } }

    /// The account's picture, as the Account menu shows it.
    static func pictureFile(for key: String) -> URL { folder(for: key).appendingPathComponent("account.png") }

    // MARK: - Changes

    /// Logged in (or reconnected): remembers who it is. The first account to log in is the main one.
    @MainActor
    static func recordLogin(_ account: Account) {
        guard !DemoMode.isOn else { return }
        var list = all
        guard let index = list.firstIndex(where: { $0.key == active }) else { return }
        list[index].userID = account.id
        list[index].name = account.name
        all = list
        if main == nil { defaults.set(active, forKey: mainKey) }
    }

    /// Saves the account's picture for the Account menu.
    @MainActor
    static func savePicture(of account: Account) async {
        guard !DemoMode.isOn else { return }
        guard let url = account.avatarURL.flatMap(URL.init(string:)) else {
            CoreBridge.shared.log("Accounts: no picture for the account")
            return
        }
        guard let image = await ImageCache.shared.image(for: url),
              let png = RoundAvatar.image(image, name: account.name, size: 64).pngData else {
            CoreBridge.shared.log("Accounts: couldn't load the account's picture")
            return
        }
        do {
            try png.write(to: pictureFile(for: active))
        } catch {
            CoreBridge.shared.log("Accounts: couldn't save the account's picture: \(error)")
        }
    }

    /// The account that logged in in this one's place, if it's already on this Mac.
    static func existing(userID: String) -> StoredAccount? {
        all.first { $0.userID == userID && $0.key != active }
    }

    /// Adds a new account and relaunches with it, showing the login.
    @MainActor
    static func add() {
        let account = StoredAccount(key: String(UUID().uuidString.prefix(8)).lowercased(), webStoreID: UUID())
        all.append(account)
        switchTo(account.key)
    }

    /// Relaunches the app with the account; `chat` ("<thread ID>" or "<thread ID>|<message ID>")
    /// opens once its chats are loaded. A new account that didn't log in isn't kept.
    @MainActor
    static func switchTo(_ key: String, openingChat chat: String? = nil) {
        if key != active, current?.userID == nil {
            remove(active)
        }
        defaults.set(key, forKey: activeKey)
        defaults.set(chat, forKey: chatToOpenKey)
        relaunch()
    }

    /// The chat to open after switching accounts, once.
    static func takeChatToOpen() -> (threadID: String, messageID: String?)? {
        guard let chat = defaults.string(forKey: chatToOpenKey) else { return nil }
        defaults.removeObject(forKey: chatToOpenKey)
        let parts = chat.split(separator: "|", maxSplits: 1).map(String.init)
        guard let threadID = parts.first else { return nil }
        return (threadID, parts.count > 1 ? parts[1] : nil)
    }

    /// The active account logged out: it's forgotten, unless it's the only one (then its folder
    /// waits for the next login). Returns the account to switch to.
    static func loggedOut() -> StoredAccount? {
        try? FileManager.default.removeItem(at: pictureFile(for: active))
        guard loggedIn.contains(where: { $0.key != active }) else {
            var list = all
            if let index = list.firstIndex(where: { $0.key == active }) {
                list[index].userID = nil
                list[index].name = nil
            }
            all = list
            return nil
        }
        remove(active)
        // The main account first.
        return main ?? loggedIn.first
    }

    /// Forgets the account. Its folder and web view data go at the next launch (they're in use).
    private static func remove(_ key: String) {
        guard let account = all.first(where: { $0.key == key }) else { return }
        all = all.filter { $0.key != key }
        if account.webStoreID != firstWebStoreID {
            defaults.set((defaults.stringArray(forKey: removedWebStoresKey) ?? []) + [account.webStoreID.uuidString],
                         forKey: removedWebStoresKey)
        }
        if defaults.string(forKey: mainKey) == key {
            // The next one to have logged in becomes the main account.
            defaults.set(loggedIn.first?.key, forKey: mainKey)
        }
    }

    /// At launch: deletes what's left of removed accounts.
    @MainActor
    static func cleanUp() {
        guard !DemoMode.isOn else { return }
        let keys = Set(all.map(\.key))
        let folders = (try? FileManager.default.contentsOfDirectory(
            at: root.appendingPathComponent("Accounts", isDirectory: true), includingPropertiesForKeys: nil)) ?? []
        for folder in folders where !keys.contains(folder.lastPathComponent) {
            try? FileManager.default.removeItem(at: folder)
        }
        let stores = (defaults.stringArray(forKey: removedWebStoresKey) ?? []).compactMap(UUID.init(uuidString:))
        guard !stores.isEmpty else { return }
        defaults.removeObject(forKey: removedWebStoresKey)
        Task {
            for store in stores {
                try? await WKWebsiteDataStore.remove(forIdentifier: store)
            }
        }
    }

    /// Opens the app again once this copy has quit, so only one account ever runs.
    @MainActor
    private static func relaunch() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            "-c", "while kill -0 \"$1\" 2>/dev/null; do sleep 0.2; done; /usr/bin/open \"$0\"",
            Bundle.main.bundlePath, String(ProcessInfo.processInfo.processIdentifier),
        ]
        do {
            try process.run()
        } catch {
            CoreBridge.shared.log("Accounts: couldn't relaunch: \(error)")
        }
        NSApp.terminate(nil)
    }
}

private extension NSImage {
    var pngData: Data? {
        guard let tiff = tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }
}
