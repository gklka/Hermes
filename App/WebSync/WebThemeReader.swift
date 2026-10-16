import Foundation

/// Reads an encrypted chat's custom Messenger theme (outgoing bubble color or gradient) and quick
/// reaction from Messenger's web app. The core gets other chats' themes from the sync, but an
/// encrypted chat's theme changed while the app wasn't running only shows in the web app.
final class WebThemeReader {
    static let shared = WebThemeReader()

    private var readThisSession: Set<String> = []

    /// Forgets which chats were read (the account logged out).
    func reset() {
        readThisSession = []
    }

    /// Reads the theme once per session per chat, returning when done. The colors are stored with
    /// the chat in the core, so they show right away next time.
    func refresh(threadID: String) async {
        // The user may be entering the PIN there; don't navigate away.
        guard !readThisSession.contains(threadID), WebSyncController.shared.window?.isVisible != true else { return }
        readThisSession.insert(threadID)
        let account = ChatStore.shared.account?.id
        do {
            struct Params: Encodable { let threadID: String }
            struct PathResult: Decodable { let path: String }
            let path = try await CoreBridge.shared.call("web.threadPath", Params(threadID: threadID), as: PathResult.self).path
            guard !path.isEmpty else {
                // Encrypted chat not matched to the web chat list yet; try again next time.
                readThisSession.remove(threadID)
                return
            }
            let web = WebSyncController.shared
            guard await web.start(showWindow: false) else {
                readThisSession.remove(threadID)
                return
            }
            struct Theme: Decodable { let colors: [String]; let emoji: String }
            let theme = try await web.withExclusiveAccess {
                // Closed while it waited for the page (clicking through chats): not needed now,
                // it's read when the chat is opened again.
                guard web.isChatShown?(threadID) ?? true else { throw CancellationError() }
                await web.navigate(toPath: path)
                return try await web.evaluate(Self.readScript(path: path), as: Theme?.self)
            }
            guard let theme else {
                CoreBridge.shared.log("WebThemeReader: no theme found for \(threadID) at \(path)")
                readThisSession.remove(threadID)
                return
            }
            // Logged out (or in as someone else) while the page was read.
            guard ChatStore.shared.account?.id == account else { return }
            CoreBridge.shared.log("WebThemeReader: \(threadID) colors \(theme.colors), emoji '\(theme.emoji)'")
            struct ThemeParams: Encodable { let threadID: String; let colors: [String]; let emoji: String }
            try await CoreBridge.shared.call(
                "web.setThreadTheme", ThemeParams(threadID: threadID, colors: theme.colors, emoji: theme.emoji)
            )
        } catch {
            CoreBridge.shared.log("WebThemeReader: \(threadID) \(error)")
            readThisSession.remove(threadID)
        }
    }

    /// Waits for the chat at `path` to show, then returns `{colors, emoji}`. Colors are the outgoing
    /// bubble colors as "#rrggbb": one for a solid theme, several for a gradient, none for the
    /// default theme. Emoji is the composer's quick reaction, "" for the default like. Null if not found.
    private static func readScript(path: String) -> String {
        #"""
        const sleep = ms => new Promise(r => setTimeout(r, ms));
        const trim = p => p.replace(/^\/+|\/+$/g, '');
        const want = trim('\#(path)');
        for (let i = 0; i < 40 && trim(location.pathname) !== want; i++) await sleep(250);
        if (trim(location.pathname) !== want) return JSON.stringify(null);
        // Give the new chat time to replace the previous one, which has its own colors.
        await sleep(1500);
        const selector = '[role="main"] [style*="--chat-outgoing-message-bubble-background-color"]';
        let el = null;
        for (let i = 0; i < 20 && !(el = document.querySelector(selector)); i++) await sleep(500);
        if (!el) return JSON.stringify(null);

        const toHex = color => {
          const probe = document.createElement('div');
          probe.style.color = color;
          document.body.appendChild(probe);
          const value = getComputedStyle(probe).color;
          probe.remove();
          const m = value.match(/rgba?\(([^)]+)\)/);
          if (!m) return null;
          const parts = m[1].split(/[\s,/]+/).filter(Boolean).map(Number);
          if (parts.length < 3 || (parts.length >= 4 && parts[3] === 0)) return null;
          return '#' + parts.slice(0, 3).map(n => Math.round(n).toString(16).padStart(2, '0')).join('');
        };

        // The quick reaction is the rightmost button on the text box's line: an emoji image for a
        // custom one, the thumbs-up icon for the default like. (The same line only: the area also
        // holds the message list, whose outgoing rows are further right.) A custom emoji gets a
        // moment to appear, in case the chat's settings load after it renders.
        const quickEmoji = () => {
          const textbox = document.querySelector('[role="main"] [role="textbox"]');
          if (!textbox) return '';
          const box = textbox.getBoundingClientRect();
          let area = textbox;
          for (let i = 0; i < 8 && area.parentElement; i++) area = area.parentElement;
          const buttons = Array.from(area.querySelectorAll('[role="button"]')).filter(b => {
            const r = b.getBoundingClientRect();
            const middle = r.top + r.height / 2;
            return r.width > 0 && r.left >= box.right - 5 && middle >= box.top - 10 && middle <= box.bottom + 10;
          }).sort((a, b) => a.getBoundingClientRect().left - b.getBoundingClientRect().left);
          const img = buttons.length ? buttons[buttons.length - 1].querySelector('img[alt]') : null;
          return img ? img.getAttribute('alt') : '';
        };
        let emoji = quickEmoji();
        for (let i = 0; i < 4 && !emoji; i++) {
          await sleep(500);
          emoji = quickEmoji();
        }

        const colors = (() => {
          const style = getComputedStyle(el);
          const gradient = style.getPropertyValue('--chat-outgoing-message-background-gradient').trim();
          if (gradient.includes('gradient(')) {
            const stops = (gradient.match(/#[0-9a-fA-F]{3,8}\b|rgba?\([^)]*\)/g) || []).map(toHex).filter(Boolean);
            // Messenger's default theme is this purple-blue gradient; keep the app's own color for it.
            if (stops.join(',') === '#aa00ff,#0070f6') return [];
            if (stops.length > 1) return stops;
          }
          const solid = toHex(style.getPropertyValue('--chat-outgoing-message-bubble-background-color').trim());
          return solid ? [solid] : [];
        })();
        return JSON.stringify({ colors, emoji });
        """#
    }
}
