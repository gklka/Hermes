import Foundation

/// Imports the history of an encrypted 1:1 chat from Messenger's web app (after it has been
/// restored there with your PIN). The web app shows each message with its real message ID,
/// so imported messages line up with ones the live connection delivers.
final class WebHistoryImporter {
    static let shared = WebHistoryImporter()

    /// Called on the main thread when an import starts/finishes for a thread.
    var onStateChange: ((_ threadID: String, _ isImporting: Bool) -> Void)?
    private(set) var importing: Set<String> = []
    private var importedThisSession: Set<String> = []

    private struct Result: Decodable {
        let messages: [Message]
        let error: String?
    }

    struct Message: Codable {
        let domID: String
        let fromMe: Bool
        let text: String
        let images: [Image]
    }

    struct Image: Codable {
        let data: String
        let mimeType: String
        let width: Int
        let height: Int
    }

    func importHistory(threadID: String) {
        guard !importing.contains(threadID), !importedThisSession.contains(threadID) else {
            CoreBridge.shared.log("WebHistoryImporter: \(threadID) skipped (importing: \(importing.contains(threadID)), done: \(importedThisSession.contains(threadID)))")
            return
        }
        CoreBridge.shared.log("WebHistoryImporter: \(threadID) requested")
        importing.insert(threadID)
        onStateChange?(threadID, true)
        Task {
            defer {
                importing.remove(threadID)
                onStateChange?(threadID, false)
            }
            do {
                struct WebIDResult: Decodable { let webID: String }
                struct Params: Encodable { let threadID: String }
                let webID = try await CoreBridge.shared.call("web.threadWebID", Params(threadID: threadID), as: WebIDResult.self).webID
                CoreBridge.shared.log("WebHistoryImporter: web ID for \(threadID) is '\(webID)'")
                guard !webID.isEmpty else {
                    CoreBridge.shared.log("WebHistoryImporter: no web chat known for \(threadID)")
                    return
                }
                let web = WebSyncController.shared
                CoreBridge.shared.log("WebHistoryImporter: \(threadID) → web chat \(webID), starting")
                await web.start(showWindow: false)
                let result = try await web.withExclusiveAccess {
                    CoreBridge.shared.log("WebHistoryImporter: navigating")
                    await web.navigate(toPath: "/messages/e2ee/t/\(webID)/")
                    CoreBridge.shared.log("WebHistoryImporter: collecting from \(web.webView.url?.path ?? "?")")
                    return try await web.evaluate(Self.collectScript(userID: threadID), as: Result.self)
                }
                CoreBridge.shared.log("WebHistoryImporter: collected \(result.messages.count) messages")
                if let error = result.error {
                    CoreBridge.shared.log("WebHistoryImporter: \(error)")
                }
                struct ImportParams: Encodable { let threadID: String; let messages: [Message] }
                try await CoreBridge.shared.call("web.importMessages", ImportParams(threadID: threadID, messages: result.messages))
                // The core emits each stored message as an event, so open chats update by themselves.
                importedThisSession.insert(threadID)
            } catch {
                CoreBridge.shared.log("WebHistoryImporter: \(error)")
            }
        }
    }

    /// Scrolls the open chat back (up to `max` messages) and returns every message's ID,
    /// direction, text and inline images (as base64; the page already shows them decrypted).
    private static func collectScript(userID: String, max: Int = 400) -> String {
        """
        const sleep = ms => new Promise(r => setTimeout(r, ms));
        let log = null;
        for (let i = 0; i < 40; i++) {
          log = document.querySelector('[role="main"] [role="log"]');
          if (log && log.querySelector('[data-message-id^="\(userID)@"]')) break;
          await sleep(500);
        }
        if (!log || !log.querySelector('[data-message-id^="\(userID)@"]')) return JSON.stringify({ messages: [], error: 'no messages shown for this chat' });
        await sleep(1000);
        const scroller = (() => {
          for (let el = log; el; el = el.parentElement)
            if (el.scrollHeight > el.clientHeight + 20 && /(auto|scroll)/.test(getComputedStyle(el).overflowY)) return el;
          let best = null;
          for (const el of log.querySelectorAll('*'))
            if (el.scrollHeight > el.clientHeight + 20 && /(auto|scroll)/.test(getComputedStyle(el).overflowY) && (!best || el.scrollHeight > best.scrollHeight)) best = el;
          return best;
        })();
        const seen = new Map();
        const collect = () => {
          const logRect = log.getBoundingClientRect();
          const mid = logRect.left + logRect.width / 2;
          for (const el of log.querySelectorAll('[data-message-id^="\(userID)@"]')) {
            const domID = el.getAttribute('data-message-id');
            if (seen.has(domID)) continue;
            const texts = Array.from(el.querySelectorAll('span[dir="auto"] div[dir="auto"]'))
              .filter(t => !t.closest('[role="toolbar"]')).map(t => t.innerText.trim()).filter(Boolean);
            const images = Array.from(el.querySelectorAll('img')).filter(i => {
              const r = i.getBoundingClientRect();
              return r.width >= 60 && r.height >= 60 && !i.closest('[role="toolbar"]');
            }).map(i => ({ src: i.src, width: i.naturalWidth, height: i.naturalHeight }));
            const bubble = el.querySelector('span[dir="auto"]') || el.querySelector('img') || el;
            const r = bubble.getBoundingClientRect();
            seen.set(domID, { domID, fromMe: r.width > 0 && (r.left + r.width / 2) > mid, text: texts.join('\\n'), images });
          }
        };
        collect();
        let stable = 0;
        for (let i = 0; i < 80 && scroller && stable < 3 && seen.size < \(max); i++) {
          const before = seen.size;
          scroller.scrollTop = 0;
          await sleep(1500);
          collect();
          stable = seen.size === before ? stable + 1 : 0;
        }
        const toBase64 = async src => {
          const bytes = new Uint8Array(await (await fetch(src)).arrayBuffer());
          let bin = '';
          for (let i = 0; i < bytes.length; i += 0x8000) bin += String.fromCharCode.apply(null, bytes.subarray(i, i + 0x8000));
          return { data: btoa(bin), size: bytes.length };
        };
        const messages = [];
        for (const m of seen.values()) {
          const images = [];
          for (const img of m.images.slice(0, 6)) {
            try {
              const { data, size } = await toBase64(img.src);
              const mimeType = img.src.startsWith('data:') ? img.src.slice(5, img.src.indexOf(';')) : 'image/jpeg';
              if (size < 15 * 1024 * 1024) images.push({ data, mimeType, width: img.width, height: img.height });
            } catch (e) {}
          }
          messages.push({ domID: m.domID, fromMe: m.fromMe, text: m.text, images });
        }
        return JSON.stringify({ messages });
        """
    }
}
