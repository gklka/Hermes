import AppKit

/// Demo mode, for the website's screenshots (`Support/Demo/screenshots.sh`): launched with
/// `-DemoData <folder>`, the app shows the sample chats in `<folder>/demo.json` instead of
/// starting the core, never connects to Messenger or its web app, and stages scenes written to
/// `<folder>/command` (see `DemoDirector`). Its data folder is that folder.
enum DemoMode {
    nonisolated static let folder: URL? = UserDefaults.standard.string(forKey: "DemoData")
        .map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true) }

    nonisolated static var isOn: Bool { folder != nil }
}

/// Answers the app's core requests from `demo.json` (the core's JSON shapes, Models.swift).
final class DemoCore {
    static let shared = DemoCore()

    private struct Data: Decodable {
        let account: Account
        let conversations: [Conversation]
        let messages: [String: [ChatMessage]]
        var contacts: [Participant]?
        var presence: [PresenceEvent]?
        var accounts: [DemoAccount]?
    }

    /// An account in the Account menu.
    private struct DemoAccount: Decodable {
        let key: String
        let userID: String
        let name: String
    }

    private var data: Data?
    private let encoder = JSONEncoder()

    func start() {
        guard let folder = DemoMode.folder else { return }
        do {
            let raw = try Foundation.Data(contentsOf: folder.appendingPathComponent("demo.json"))
            data = try JSONDecoder().decode(Data.self, from: raw)
        } catch {
            NSLog("Demo: couldn't read demo.json: \(error)")
        }
        Accounts.showDemo((data?.accounts ?? []).map {
            StoredAccount(key: $0.key, webStoreID: UUID(), userID: $0.userID, name: $0.name)
        })
        emit("state", State(state: "connected", account: data?.account))
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            for presence in self?.data?.presence ?? [] {
                self?.emit("presence", Presence(userID: presence.userID, isOnline: presence.isOnline, lastSeen: presence.lastSeen))
            }
        }
    }

    /// A response envelope for the request, as the core would send it.
    func respond(_ method: String, _ params: Foundation.Data) -> Foundation.Data {
        let params = (try? JSONSerialization.jsonObject(with: params)) as? [String: Any] ?? [:]
        let threadID = params["threadID"] as? String ?? ""
        let messages = data?.messages[threadID] ?? []
        let result: Encodable
        switch method {
        case "threads.list":
            result = data?.conversations ?? []
        case "messages.list", "messages.stored":
            let before = params["before"] as? Int64 ?? .max
            let limit = params["limit"] as? Int ?? 50
            let page = messages.filter { $0.timestamp < before }.suffix(limit)
            result = Page(messages: Array(page), hasMore: false)
        case "messages.search":
            let text = params["text"] as? String ?? ""
            result = Page(messages: messages.filter {
                $0.text.range(of: text, options: [.caseInsensitive, .diacriticInsensitive]) != nil
            }, hasMore: false)
        case "messages.pinned":
            result = Page(messages: messages.filter { $0.isPinned == true }, hasMore: false)
        case "contacts.search", "contacts.searchPeople":
            let text = params["text"] as? String ?? ""
            result = (data?.contacts ?? []).filter {
                text.isEmpty || $0.name.range(of: text, options: [.caseInsensitive, .diacriticInsensitive]) != nil
            }
        case "userAgent":
            result = ["userAgent": ""]
        case "web.threadPath", "web.threadWebID":
            result = ["path": "", "webID": ""]
        case "messages.fetchOlder":
            result = ["fetched": 0, "hasMore": 0]
        default:
            result = [String: String]()
        }
        let body = (try? encoder.encode(result)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        return Foundation.Data("{\"type\":\"response\",\"id\":0,\"result\":\(body)}".utf8)
    }

    /// Delivers an event to the app, as the core would.
    func emit(_ name: String, _ payload: some Encodable) {
        let body = (try? encoder.encode(payload)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        let envelope = Foundation.Data("{\"type\":\"event\",\"event\":\"\(name)\",\"data\":\(body)}".utf8)
        CoreBridge.shared.onEvent?(name, envelope)
    }

    func message(_ id: String) -> ChatMessage? {
        data?.messages.values.lazy.compactMap { $0.first { $0.id == id } }.first
    }

    private struct Page: Encodable {
        let messages: [ChatMessage]
        let hasMore: Bool
    }

    // Events' payloads (the app's event types are only Decodable).
    private struct State: Encodable {
        let state: String
        let account: Account?
    }

    private struct Presence: Encodable {
        let userID: String
        let isOnline: Bool
        let lastSeen: Int64
    }

    struct Typing: Encodable {
        let threadID: String
        let senderID: String
        let isTyping: Bool
    }
}

/// Stages the screenshots' scenes. `Support/Demo/screenshots.sh` writes commands to
/// `<folder>/command`, one per line; when they're done (and the windows have settled) the
/// director writes `<folder>/done`.
final class DemoDirector {
    static let shared = DemoDirector()

    private var timer: Timer?
    /// The menu `accountmenu` opened (it stays open until `closewindows`).
    private var openMenu: NSMenu?

    func start() {
        guard DemoMode.isOn else { return }
        let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        // Also while a menu is open.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private var commandFile: URL? { DemoMode.folder?.appendingPathComponent("command") }
    private var doneFile: URL? { DemoMode.folder?.appendingPathComponent("done") }

    private func poll() {
        guard let commandFile, let doneFile, let text = try? String(contentsOf: commandFile, encoding: .utf8) else { return }
        try? FileManager.default.removeItem(at: commandFile)
        Task {
            for line in text.split(separator: "\n") {
                await run(line.split(separator: " ", maxSplits: 1).map(String.init))
            }
            try? await Task.sleep(for: .milliseconds(1200))
            try? Foundation.Data("ok".utf8).write(to: doneFile)
        }
    }

    private var main: MainWindowController? {
        NSApp.windows.lazy.compactMap { $0.windowController as? MainWindowController }.first
    }

    private var chat: ChatViewController? { main?.chatViewController }

    private func run(_ words: [String]) async {
        guard let command = words.first else { return }
        let argument = words.count > 1 ? words[1] : ""
        let parts = argument.split(separator: " ").map(String.init)
        switch command {
        case "appearance":
            NSApp.appearance = NSAppearance(named: argument == "dark" ? .darkAqua : .aqua)
        case "size":
            // Content size, centered on the screen.
            guard parts.count == 2, let width = Double(parts[0]), let height = Double(parts[1]),
                  let window = NSApp.keyWindow ?? main?.window else { return }
            window.setContentSize(NSSize(width: width, height: height))
            window.center()
        case "sidebar":
            if let width = Double(argument) { main?.split.splitView.setPosition(width, ofDividerAt: 0) }
        case "select":
            main?.window?.makeKeyAndOrderFront(nil)
            main?.select(threadID: argument)
        case "filter":
            if let filter = ConversationFilter.allCases.first(where: { $0.title.lowercased() == argument }) {
                main?.split.filter = filter
            }
        case "typing", "stoptyping":
            // typing <thread> <user>
            guard parts.count == 2 else { return }
            DemoCore.shared.emit("typing", DemoCore.Typing(threadID: parts[0], senderID: parts[1], isTyping: command == "typing"))
        case "find":
            chat?.startSearch()
            chat?.searchBar.searchField.stringValue = argument
            chat?.searchChanged(argument)
        case "endfind":
            chat?.endSearch()
        case "tapback":
            guard let chat, let message = DemoCore.shared.message(argument), let row = chat.rowIndex(ofMessage: argument) else { return }
            chat.tableView.scrollRowToVisible(row)
            guard let cell = chat.tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? MessageCellView else { return }
            chat.messageCellDidDoubleClick(cell, message: message, bubble: cell.bubbleView)
        case "edits":
            if let message = DemoCore.shared.message(argument) { chat?.messageCellDidToggleEdits(message) }
        case "window":
            ChatWindowController.show(threadID: argument)
        case "accountmenu":
            // The Account menu, open over the main window's chat (its menu bar isn't in the picture).
            // It's drawn outside the app, in the Mac's appearance, not the app's.
            guard let menu = NSApp.mainMenu?.item(withTitle: "Account")?.submenu,
                  let content = main?.window?.contentView else { return }
            openMenu = menu
            NSApp.activate()
            // Low enough that all of its window (shadow included) is over the main window.
            let point = NSPoint(x: Double(argument) ?? 340, y: content.bounds.height - 110)
            // It runs until it's closed, so after this command returns; from the run loop, not
            // the main queue, which would be blocked meanwhile (and with it the director).
            RunLoop.main.perform(inModes: [.default]) {
                MainActor.assumeIsolated { _ = menu.popUp(positioning: nil, at: point, in: content) }
            }
        case "closewindows":
            openMenu?.cancelTracking()
            openMenu = nil
            ChatWindowController.closeAll()
            for window in NSApp.windows where window is NSPanel { window.orderOut(nil) }
            for window in NSApp.windows {
                if let parent = window.sheetParent {
                    parent.endSheet(window)
                    window.orderOut(nil)
                }
            }
        case "members":
            main?.showMembers(nil)
        case "call":
            // call <thread>: an incoming call from that chat.
            guard let conversation = ChatStore.shared.conversation(argument) else { return }
            let buttons = [
                IncomingCallPanel.Button(index: 0, label: "Decline", tone: "decline"),
                IncomingCallPanel.Button(index: 1, label: "Accept", tone: "accept"),
            ]
            let panel = IncomingCallPanel(name: conversation.name, detail: "Incoming video call",
                                          conversation: conversation, imageURL: conversation.avatarURL,
                                          buttons: buttons) { _ in }
            panel.present()
            if let main = main?.window {
                // Next to the main window, so they're in one picture.
                panel.setFrameOrigin(NSPoint(x: main.frame.maxX - panel.frame.width + 40, y: main.frame.maxY - panel.frame.height + 40))
            }
        case "wait":
            try? await Task.sleep(for: .milliseconds(Int(argument) ?? 500))
        case "activate":
            NSApp.activate()
        default:
            NSLog("Demo: unknown command \(command)")
        }
    }
}

