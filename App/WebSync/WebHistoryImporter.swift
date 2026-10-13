import Foundation

/// Imports the history of an encrypted 1:1 chat from Messenger's web app (after it has been
/// restored there with your PIN). The web app shows each message with its real message ID,
/// so imported messages line up with ones the live connection delivers.
final class WebHistoryImporter {
    static let shared = WebHistoryImporter()

    /// Called on the main thread when an import starts/finishes for a thread.
    var onStateChange: ((_ threadID: String, _ isImporting: Bool) -> Void)?
    private(set) var importing: Set<String> = []
    /// Threads whose history the web app couldn't show (not restored there with the PIN yet).
    private(set) var needsRestore: Set<String> = []
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
        /// Shared links' cards (their pictures aren't in `images`).
        let links: [Link]
        let reactions: [Reaction]
    }

    /// A reaction pill: its emoji and how many people reacted (the page doesn't say who).
    struct Reaction: Codable {
        let emojis: [String]
        let count: Int
    }

    struct Link: Codable {
        let url: String
        let title: String
        let description: String
        let image: Image?
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
                    needsRestore.insert(threadID)
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
                let empty = result.messages.filter { $0.text.isEmpty && $0.images.isEmpty && $0.links.isEmpty }.map(\.domID)
                CoreBridge.shared.log("WebHistoryImporter: \(empty.count) came back empty: \(empty.prefix(12).joined(separator: ", "))")
                if let error = result.error {
                    CoreBridge.shared.log("WebHistoryImporter: \(error)")
                }
                struct ImportParams: Encodable { let threadID: String; let messages: [Message] }
                struct ImportResult: Decodable { let imported: Int; let unrestored: Int }
                let imported = try await CoreBridge.shared.call(
                    "web.importMessages", ImportParams(threadID: threadID, messages: result.messages), as: ImportResult.self
                )
                CoreBridge.shared.log("WebHistoryImporter: imported \(imported.imported), not restored \(imported.unrestored)")
                // The core emits each stored message as an event, so open chats update by themselves.
                if result.messages.isEmpty || imported.unrestored > 0 {
                    // Not marked as imported, so it's tried again after a restore.
                    needsRestore.insert(threadID)
                    return
                }
                needsRestore.remove(threadID)
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
        // Pictures are read as soon as they're seen: blob: URLs can be revoked once a message
        // scrolls out of the (virtualized) list.
        const toBase64 = async src => {
          // data: URLs already hold the picture (and Facebook's content security policy blocks
          // fetching them).
          const comma = src.indexOf(',');
          if (src.startsWith('data:') && comma > 0 && src.slice(0, comma).endsWith(';base64')) {
            const data = src.slice(comma + 1);
            return { data, size: Math.floor(data.length * 3 / 4) };
          }
          const bytes = new Uint8Array(await (await fetch(src)).arrayBuffer());
          let bin = '';
          for (let i = 0; i < bytes.length; i += 0x8000) bin += String.fromCharCode.apply(null, bytes.subarray(i, i + 0x8000));
          return { data: btoa(bin), size: bytes.length };
        };
        const encode = async img => {
          try {
            const { data, size } = await toBase64(img.src);
            const mimeType = img.src.startsWith('data:') ? img.src.slice(5, img.src.indexOf(';')) : 'image/jpeg';
            return size < 15 * 1024 * 1024 ? { data, mimeType, width: img.width, height: img.height } : null;
          } catch (e) { return null; }
        };
        // Text with emoji, which the page draws as <img alt="😆">.
        const textOf = node => {
          let s = '';
          for (const n of node.childNodes) {
            if (n.nodeType === Node.TEXT_NODE) s += n.nodeValue;
            else if (n.nodeName === 'IMG') s += n.getAttribute('alt') || '';
            else if (n.nodeName === 'BR') s += '\\n';
            else s += textOf(n);
          }
          return s;
        };
        const isPicture = i => {
          const r = i.getBoundingClientRect();
          return r.width >= 60 && r.height >= 60 && !i.closest('[role="toolbar"]');
        };

        const seen = new Map();
        const richness = m => m.text.length + 1000 * (m.images.length + m.links.length) + 10 * m.reactions.length;
        const collect = () => {
          const logRect = log.getBoundingClientRect();
          const mid = logRect.left + logRect.width / 2;
          for (const el of log.querySelectorAll('[data-message-id^="\(userID)@"]')) {
            const domID = el.getAttribute('data-message-id');
            // Shared links' cards: <a href> with a title (and description, picture) inside. Links
            // in the message text sit in its div[dir=auto]; links around a bare photo are photos.
            const cards = Array.from(el.querySelectorAll('a[href^="http"]')).filter(a =>
              !a.closest('[role="toolbar"]') && !a.closest('div[dir="auto"]') && a.querySelector('span[dir="auto"]'));
            const inCard = node => cards.some(a => a.contains(node));
            // The text (big single emoji included): each outermost div[dir=auto].
            const texts = Array.from(el.querySelectorAll('div[dir="auto"]'))
              .filter(t => !t.closest('[role="toolbar"]') && !inCard(t) && !t.parentElement.closest('div[dir="auto"]'))
              .map(t => textOf(t).trim()).filter(Boolean);
            const links = cards.map(a => {
              const spans = Array.from(a.querySelectorAll('span[dir="auto"]')).map(s => s.innerText.trim()).filter(Boolean);
              const img = Array.from(a.querySelectorAll('img')).find(isPicture);
              return { url: a.href, title: spans[0] || '', description: spans[1] || '',
                       image: img ? { src: img.src, width: img.naturalWidth, height: img.naturalHeight } : null };
            });
            const images = Array.from(el.querySelectorAll('img')).filter(i => isPicture(i) && !inCard(i))
              .map(i => ({ src: i.src, width: i.naturalWidth, height: i.naturalHeight }));
            // Reactions: a button labelled "<count> <emoji> …" with the emoji as images.
            const reactions = [];
            for (const button of el.querySelectorAll('[role="button"][aria-label]')) {
              const count = parseInt(button.getAttribute('aria-label'), 10);
              if (!(count > 0) || button.closest('[role="toolbar"]')) continue;
              const emojis = Array.from(button.querySelectorAll('img[alt]')).map(i => i.getAttribute('alt')).filter(Boolean);
              if (emojis.length) reactions.push({ emojis, count });
            }
            const entry = { domID, text: texts.join('\\n'), images, links, reactions };
            const old = seen.get(domID);
            // Keep the fullest version: pictures decrypt and cards render after the message appears.
            if (old && richness(old) >= richness(entry)) continue;
            const bubble = el.querySelector('div[dir="auto"]') || el.querySelector('img') || el;
            const r = bubble.getBoundingClientRect();
            entry.fromMe = old ? old.fromMe : r.width > 0 && (r.left + r.width / 2) > mid;
            entry.imagesReady = Promise.all(images.slice(0, 6).map(encode));
            entry.linksReady = Promise.all(links.slice(0, 3).map(async l => ({ ...l, image: l.image ? await encode(l.image) : null })));
            seen.set(domID, entry);
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
        // Second pass, forward through the chat, so every message gets time to render fully.
        if (scroller) {
          scroller.scrollTop = 0;
          await sleep(1000);
          for (let i = 0; i < 400 && scroller.scrollTop + scroller.clientHeight < scroller.scrollHeight - 5; i++) {
            scroller.scrollTop += scroller.clientHeight * 0.7;
            await sleep(700);
            collect();
          }
          await sleep(1000);
          collect();
        }
        const messages = [];
        for (const m of seen.values()) {
          const images = (await m.imagesReady).filter(Boolean);
          const links = await m.linksReady;
          messages.push({ domID: m.domID, fromMe: m.fromMe, text: m.text, images, links, reactions: m.reactions });
        }
        return JSON.stringify({ messages });
        """
    }
}
