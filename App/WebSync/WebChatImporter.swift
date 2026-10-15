import Foundation

/// Reads the encrypted chats from Messenger's web chat list (names, avatars, relative times, and
/// snippets once restored with your PIN) and merges them into the core's chat list. Encrypted
/// chats aren't in the regular sync, so this is how they get their place in the sidebar.
final class WebChatImporter {
    static let shared = WebChatImporter()

    private var timer: Timer?

    struct Row: Codable {
        let webID: String
        let name: String
        let snippet: String
        let age: String
        let avatarURL: String
        var userID: String?
    }

    private struct ImportResult: Decodable {
        let imported: Int
        let unresolved: [String]
    }

    /// Imports now and then every 10 minutes: the chats the web app shows at first. Scrolling
    /// to the bottom of the chat list reads more (`loadMore`), as on the web.
    func start() {
        CoreBridge.shared.log("WebChatImporter: start() called")
        Task { await runOnce() }
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                _ = Task { await self?.runOnce() }
            }
        }
    }

    /// No more imports (the account logged out). One still reading the page may never finish
    /// (the page is closed), so it doesn't block the next account's.
    func stop() {
        timer?.invalidate()
        timer = nil
        currentRun = nil
        stage = nil
        notifyActivity()
        listedChats = 0
        hasReadSinceLaunch = false
        reachedEnd = false
    }

    /// The import running now, if any.
    private var currentRun: (id: UUID, task: Task<Void, Never>)?

    // MARK: - Activity

    /// Where the running import is (nil: none running).
    private enum Stage {
        case startingWebApp
        /// A chat's history (or theme) is being read from the page.
        case waitingForPage
        /// Scrolling through the list; how many encrypted chats it found so far.
        case reading(found: Int)
        /// Opening chats whose person couldn't be matched, to read who it is.
        case matching(done: Int, total: Int)
        case saving

        var text: String {
            switch self {
            case .startingWebApp: return "Starting Messenger web…"
            case .waitingForPage: return "Waiting for Messenger web to finish another task…"
            case .reading(0): return "Waiting for the chat list to appear…"
            case .reading(let found): return "Reading the chat list: \(found) chats so far"
            case .matching(let done, let total): return "Finding out who's in new chats: \(done) of \(total)"
            case .saving: return "Saving the chat list…"
            }
        }

        var progress: Double? {
            if case .matching(let done, let total) = self, total > 0 { return Double(done) / Double(total) }
            return nil
        }
    }

    private struct Record {
        let started: Date
        let ended: Date
        let failed: Bool
        let summary: String
    }

    private var stage: Stage?
    private var started = Date()
    /// The imports finished since launch, the latest first.
    private var log: [Record] = []

    /// Whether the chat list is being read now (other readers of the page wait for it).
    var isReading: Bool { stage != nil }
    /// Whether the web list's next page is being read (the sidebar shows a spinner for it).
    /// Changes post WebHistoryImporter.activityDidChange.
    var isLoadingMoreChats: Bool { stage != nil && isLoadingMore }

    private static let activityName = "Chat List"

    /// The running import and the finished ones, for the Activity window.
    var activityItems: [WebHistoryImporter.ActivityItem] {
        var items: [WebHistoryImporter.ActivityItem] = []
        if let stage {
            items.append(.init(threadID: nil, section: .now, kind: .running, title: isLoadingMore ? "More chats" : "Encrypted chats",
                               status: stage.text, progress: stage.progress, date: started, duration: nil,
                               name: Self.activityName))
        }
        for record in log {
            items.append(.init(threadID: nil, section: .done, kind: record.failed ? .failed : .done, title: "Encrypted chats",
                               status: record.summary, progress: nil, date: record.ended,
                               duration: record.ended.timeIntervalSince(record.started), name: Self.activityName))
        }
        return items
    }

    private func setStage(_ stage: Stage?) {
        self.stage = stage
        notifyActivity()
    }

    private func notifyActivity() {
        NotificationCenter.default.post(name: WebHistoryImporter.activityDidChange, object: self)
    }

    private func finish(_ summary: String, failed: Bool = false) {
        guard stage != nil else { return }
        log.insert(Record(started: started, ended: Date(), failed: failed, summary: summary), at: 0)
        log = Array(log.prefix(20))
        setStage(nil)
    }

    // MARK: - Import

    /// Posted when `listedChats` changes.
    static let listedChatsDidChange = Notification.Name("WebChatImporterListedChatsDidChange")
    private static let listedChatsKey = "WebListedChats"

    /// How many chats (of any kind) the web list has loaded: the sidebar shows as many, like
    /// the web app. 0 while unknown. Kept across launches until the first read after launch.
    private(set) var listedChats = UserDefaults.standard.integer(forKey: WebChatImporter.listedChatsKey) {
        didSet {
            guard listedChats != oldValue else { return }
            UserDefaults.standard.set(listedChats, forKey: Self.listedChatsKey)
            NotificationCenter.default.post(name: Self.listedChatsDidChange, object: self)
        }
    }
    /// The first read since launch: it sets `listedChats` to the web list's first page.
    private var hasReadSinceLaunch = false
    /// The last read for more found nothing new: the web list has no more.
    private(set) var reachedEnd = false
    /// Whether the running read is for more chats.
    private var isLoadingMore = false

    /// What the collect script returns.
    private struct ListResult: Decodable {
        /// The encrypted chats' rows.
        let rows: [Row]
        /// How many chats of any kind the list showed.
        let total: Int
    }

    /// Imports the chats the web list shows at first, or waits for the import already running
    /// (e.g. the restore window closed during one; what follows needs the list).
    func runOnce() async {
        await run(target: 0)
    }

    /// The chat list was scrolled to its bottom: reads the web list's next page.
    func loadMore() {
        // Not again right away (e.g. when the web app can't be started).
        guard currentRun == nil, !reachedEnd, ChatStore.shared.account != nil,
              Date().timeIntervalSince(lastLoadMore) > 3 else { return }
        lastLoadMore = Date()
        Task { await run(target: listedChats + 1) }
    }
    private var lastLoadMore = Date.distantPast

    /// Reads the web list, scrolling it until it shows `target` chats (0: what it shows at first).
    private func run(target: Int) async {
        if let currentRun {
            await currentRun.task.value
            return
        }
        guard let account = ChatStore.shared.account?.id else { return }
        let id = UUID()
        let task = Task {
            let web = WebSyncController.shared
            CoreBridge.shared.log("WebChatImporter:starting\(target > 0 ? ", reading \(target)" : "")")
            started = Date()
            isLoadingMore = target > 0
            setStage(.startingWebApp)
            guard await web.start(showWindow: false) else {
                finish("Messenger web couldn't be started.", failed: true)
                return
            }
            setStage(.waitingForPage)
            do {
                try await web.withExclusiveAccess { await importList(web, for: account, target: target) }
            } catch {
                finish(error.localizedDescription, failed: true)
            }
        }
        currentRun = (id, task)
        await task.value
        if currentRun?.id == id { currentRun = nil }
    }

    private func importList(_ web: WebSyncController, for account: String, target: Int) async {
        // Logged out (or in as someone else) while the page was read.
        func stillLoggedIn() -> Bool { ChatStore.shared.account?.id == account }
        do {
            setStage(.reading(found: 0))
            // The collect script counts what it found in window.__mmChatList.
            let poll = Task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(500))
                    guard let found = try? await web.evaluate("return JSON.stringify((window.__mmChatList || {}).found || 0)", as: Int.self),
                          !Task.isCancelled else { continue }
                    setStage(.reading(found: found))
                }
            }
            // The web app sometimes redirects/re-renders right after loading; retry a few times.
            var list = ListResult(rows: [], total: 0)
            for attempt in 1...3 {
                do {
                    list = try await web.evaluate(Self.collectScript(target: target), as: ListResult.self)
                    break
                } catch where attempt < 3 {
                    try? await Task.sleep(for: .seconds(5))
                }
            }
            poll.cancel()
            let rows = list.rows
            CoreBridge.shared.log("WebChatImporter:found \(rows.count) encrypted chats in web list (\(list.total) chats)")
            // Asked for more than it found: that's all the web list has (new chats can come later).
            reachedEnd = target > 0 && list.total < target
            if list.total > 0 {
                // Later reads keep what was loaded (a reloaded page starts at its first page again).
                listedChats = hasReadSinceLaunch ? max(listedChats, list.total) : list.total
                hasReadSinceLaunch = true
            }
            guard stillLoggedIn() else {
                finish("Logged out while the chat list was read.", failed: true)
                return
            }
            guard !rows.isEmpty else {
                finish("Messenger web showed no encrypted chats.")
                return
            }
            setStage(.saving)
            struct Params: Encodable { let rows: [Row] }
            var result = try await CoreBridge.shared.call("web.importThreads", Params(rows: rows), as: ImportResult.self)

            // Chats whose person couldn't be matched by avatar: open each once in the web app and
            // read the profile link from the chat header (the core caches the mapping).
            if !result.unresolved.isEmpty {
                var resolved = rows
                let unresolved = result.unresolved.prefix(10)
                for (index, webID) in unresolved.enumerated() {
                    setStage(.matching(done: index, total: unresolved.count))
                    let userID = try? await web.evaluate(Self.resolveScript(webID: webID), as: String.self)
                    if let userID, !userID.isEmpty, let index = resolved.firstIndex(where: { $0.webID == webID }) {
                        resolved[index].userID = userID
                    }
                }
                _ = try? await web.evaluate(Self.backToListScript, as: String.self)
                guard stillLoggedIn() else {
                    finish("Logged out while the chat list was read.", failed: true)
                    return
                }
                setStage(.saving)
                result = try await CoreBridge.shared.call("web.importThreads", Params(rows: resolved), as: ImportResult.self)
            }
            CoreBridge.shared.log("WebChatImporter:imported \(result.imported), unresolved \(result.unresolved.count)")
            finish("Read \(rows.count) encrypted chat\(rows.count == 1 ? "" : "s") from Messenger web's chat list.")
        } catch {
            CoreBridge.shared.log("WebChatImporter:\(error)")
            finish(error.localizedDescription, failed: true)
        }
    }

    /// Opens a chat in the web app (client-side navigation) and returns the other person's user ID
    /// from the header's profile link, or "" for group chats / if not found.
    private static func resolveScript(webID: String) -> String {
        """
        const sleep = ms => new Promise(r => setTimeout(r, ms));
        const link = document.querySelector('a[href="/messages/e2ee/t/\(webID)/"]');
        if (!link) return JSON.stringify('');
        link.click();
        for (let i = 0; i < 16; i++) {
          await sleep(500);
          if (!location.pathname.includes('\(webID)')) continue;
          const main = document.querySelector('[role="main"]');
          if (!main) continue;
          const ids = new Set();
          for (const a of main.querySelectorAll('a[href]')) {
            const m = a.getAttribute('href').match(/^\\/(\\d{5,})\\/?$/) || a.getAttribute('href').match(/profile\\.php\\?id=(\\d+)/);
            if (m) ids.add(m[1]);
          }
          if (ids.size === 1) return JSON.stringify(Array.from(ids)[0]);
          if (ids.size > 1) return JSON.stringify('');
        }
        return JSON.stringify('');
        """
    }

    private static let backToListScript = """
    const link = document.querySelector('a[href^="/messages/t/"]');
    if (link) link.click();
    return JSON.stringify('');
    """

    /// Waits for the chat list and returns its encrypted rows in display order (newest first),
    /// and how many chats of any kind it shows. With a target, it scrolls down (the list loads a
    /// page at a time, and drops rows scrolled away) until it has shown that many chats, or ends.
    private static func collectScript(target: Int) -> String {
    """
    const sleep = ms => new Promise(r => setTimeout(r, ms));
    const TARGET = \(target);
    let grid = null;
    for (let i = 0; i < 60 && !grid; i++) {
      grid = document.querySelector('[role="grid"]');
      if (!grid || !grid.querySelector('a[href^="/messages/"]')) { grid = null; await sleep(1000); }
    }
    if (!grid) return JSON.stringify({ rows: [], total: 0 });
    await sleep(1500); // let avatars and times fill in
    const rows = new Map();
    // Every chat shown, encrypted or not.
    const all = new Set();
    // Text with emoji, which the page draws as <img alt="😆">.
    const textOf = node => {
      let s = '';
      for (const n of node.childNodes) {
        if (n.nodeType === Node.TEXT_NODE) s += n.nodeValue;
        else if (n.nodeName === 'IMG') s += n.getAttribute('alt') || '';
        else s += textOf(n);
      }
      return s;
    };
    const collect = () => {
      for (const row of grid.querySelectorAll('[role="row"]')) {
        const link = row.querySelector('a[href^="/messages/"]');
        const chat = link && link.getAttribute('href').match(/^\\/messages\\/(?:e2ee\\/)?t\\/\\d+/);
        if (chat) all.add(chat[0]);
        const a = row.querySelector('a[href^="/messages/e2ee/t/"]');
        if (!a) continue;
        const webID = (a.getAttribute('href').match(/\\/e2ee\\/t\\/(\\d+)/) || [])[1];
        if (!webID) continue;
        const spans = Array.from(a.querySelectorAll('span[dir="auto"]')).map(s => textOf(s).trim()).filter(Boolean);
        const abbr = a.querySelector('abbr');
        const img = a.querySelector('img');
        const entry = {
          webID,
          name: spans[0] || '',
          snippet: spans[1] || '',
          age: abbr ? (abbr.getAttribute('aria-label') || abbr.textContent || '') : '',
          avatarURL: img ? img.src : '',
        };
        // A row that just scrolled in can still be empty: keep the fullest reading (a Map keeps
        // the first insertion's place, so the order stays).
        const fullness = r => !!r.name + !!r.snippet + !!r.age + !!r.avatarURL;
        const old = rows.get(webID);
        if (!old || fullness(entry) > fullness(old)) rows.set(webID, entry);
      }
      window.__mmChatList = { found: all.size };
    };
    collect();
    // The list's scrolling element: inside the list (the tallest one), or else around it.
    const scrolls = el => el.scrollHeight > el.clientHeight + 20 && /(auto|scroll)/.test(getComputedStyle(el).overflowY);
    let scroller = null;
    for (const el of grid.querySelectorAll('*'))
      if (scrolls(el) && (!scroller || el.scrollHeight > scroller.scrollHeight)) scroller = el;
    for (let el = grid; !scroller && el; el = el.parentElement)
      if (scrolls(el)) scroller = el;
    if (scroller && all.size < TARGET) {
      const top = scroller.scrollTop;
      let quiet = 0;
      for (let i = 0; i < 150 && quiet < 4 && all.size < TARGET; i++) {
        const before = all.size, height = scroller.scrollHeight;
        scroller.scrollTop = scroller.scrollHeight;
        await sleep(1200);
        collect();
        // Rows that came in empty fill in a moment later.
        await sleep(300);
        collect();
        quiet = all.size === before && scroller.scrollHeight === height ? quiet + 1 : 0;
      }
      // The rest of the page that brought the target in.
      scroller.scrollTop = scroller.scrollHeight;
      await sleep(1000);
      collect();
      scroller.scrollTop = top;
    }
    return JSON.stringify({ rows: Array.from(rows.values()), total: all.size });
    """
    }
}
