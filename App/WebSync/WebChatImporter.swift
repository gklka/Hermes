import Foundation

/// Reads the encrypted chats from Messenger's web chat list (names, avatars, relative times, and
/// snippets once restored with your PIN) and merges them into the core's chat list. Encrypted
/// chats aren't in the regular sync, so this is how they get their place in the sidebar.
final class WebChatImporter {
    static let shared = WebChatImporter()

    private var isRunning = false
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

    /// Imports now and then every 10 minutes.
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

    func runOnce() async {
        guard !isRunning else { return }
        isRunning = true
        defer { isRunning = false }

        let web = WebSyncController.shared
        CoreBridge.shared.log("WebChatImporter:starting")
        await web.start(showWindow: false)
        try? await web.withExclusiveAccess { await importList(web) }
    }

    private func importList(_ web: WebSyncController) async {
        do {
            // The web app sometimes redirects/re-renders right after loading; retry a few times.
            var rows: [Row] = []
            for attempt in 1...3 {
                do {
                    rows = try await web.evaluate(Self.collectScript, as: [Row].self)
                    break
                } catch where attempt < 3 {
                    try? await Task.sleep(for: .seconds(5))
                }
            }
            CoreBridge.shared.log("WebChatImporter:found \(rows.count) encrypted chats in web list")
            guard !rows.isEmpty else { return }
            struct Params: Encodable { let rows: [Row] }
            var result = try await CoreBridge.shared.call("web.importThreads", Params(rows: rows), as: ImportResult.self)

            // Chats whose person couldn't be matched by avatar: open each once in the web app and
            // read the profile link from the chat header (the core caches the mapping).
            if !result.unresolved.isEmpty {
                var resolved = rows
                for webID in result.unresolved.prefix(10) {
                    let userID = try? await web.evaluate(Self.resolveScript(webID: webID), as: String.self)
                    if let userID, !userID.isEmpty, let index = resolved.firstIndex(where: { $0.webID == webID }) {
                        resolved[index].userID = userID
                    }
                }
                _ = try? await web.evaluate(Self.backToListScript, as: String.self)
                result = try await CoreBridge.shared.call("web.importThreads", Params(rows: resolved), as: ImportResult.self)
            }
            CoreBridge.shared.log("WebChatImporter:imported \(result.imported), unresolved \(result.unresolved.count)")
        } catch {
            CoreBridge.shared.log("WebChatImporter:\(error)")
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

    /// Waits for the chat list, then returns its encrypted rows in display order (newest first).
    private static let collectScript = """
    const sleep = ms => new Promise(r => setTimeout(r, ms));
    let grid = null;
    for (let i = 0; i < 60 && !grid; i++) {
      grid = document.querySelector('[role="grid"]');
      if (!grid || !grid.querySelector('a[href^="/messages/"]')) { grid = null; await sleep(1000); }
    }
    if (!grid) return '[]';
    await sleep(1500); // let avatars and times fill in
    const rows = [];
    for (const row of grid.querySelectorAll('[role="row"]')) {
      const a = row.querySelector('a[href^="/messages/e2ee/t/"]');
      if (!a) continue;
      const webID = (a.getAttribute('href').match(/\\/e2ee\\/t\\/(\\d+)/) || [])[1];
      if (!webID) continue;
      const spans = Array.from(a.querySelectorAll('span[dir="auto"]')).map(s => s.textContent.trim()).filter(Boolean);
      const abbr = a.querySelector('abbr');
      const img = a.querySelector('img');
      rows.push({
        webID,
        name: spans[0] || '',
        snippet: spans[1] || '',
        age: abbr ? (abbr.getAttribute('aria-label') || abbr.textContent || '') : '',
        avatarURL: img ? img.src : '',
      });
    }
    return JSON.stringify(rows);
    """
}
