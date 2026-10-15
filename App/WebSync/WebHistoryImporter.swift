import Foundation

/// Imports the history of encrypted 1:1 chats from Messenger's web app (after it has been
/// restored there with your PIN). The web app shows each message with its real message ID,
/// so imported messages line up with ones the live connection delivers.
///
/// Chats wait in a queue, as they take turns with the page: the open chat first, then (after
/// a restore) the recent ones. For a while after a restore the web app is still downloading
/// the history, so a chat is imported again every few minutes until nothing older turns up.
final class WebHistoryImporter {
    static let shared = WebHistoryImporter()

    /// Called on the main thread when a chat's import is queued, starts or ends.
    var onStateChange: ((_ threadID: String) -> Void)?
    /// Chats whose history the web app couldn't show (not restored there with the PIN yet).
    private(set) var needsRestore: Set<String> = []
    /// Chats whose history (as far as the web app has it) is imported.
    private var done: Set<String> = []
    /// Waiting to be imported, the next first.
    private var queue: [String] = []
    /// Being imported now.
    private var current: String?
    private var isRunning = false
    /// Waiting to be imported again (more history may still arrive), and how often each was.
    private var waiting: Set<String> = []
    private var tries: [String: Int] = [:]
    /// The oldest message collected per chat (ms), to tell when an import found nothing older.
    private var oldest: [String: Int64] = [:]
    /// Changes when the account logs out, so the work for it stops.
    private var generation = 0

    private static let retryDelay: Duration = .seconds(120)
    private static let maxTries = 6
    /// How many of the most recent encrypted chats are imported after a restore.
    private static let recentChatCount = 15
    private static let maxMessages = 400
    /// For this long after a restore, the web app may still be downloading the history.
    private static let restoringPeriod: TimeInterval = 30 * 60
    private static let restoredAtKey = "WebRestoredAt"

    /// When the encrypted chats were restored here last (kept across launches).
    private var restoredAt: Date? {
        get { UserDefaults.standard.object(forKey: Self.restoredAtKey) as? Date }
        set { UserDefaults.standard.set(newValue, forKey: Self.restoredAtKey) }
    }

    private var isRestoring: Bool {
        restoredAt.map { Date().timeIntervalSince($0) < Self.restoringPeriod } ?? false
    }

    /// Queued, being imported, or waiting to be imported again: the chat shows it's loading.
    func isPending(_ threadID: String) -> Bool {
        current == threadID || queue.contains(threadID) || waiting.contains(threadID)
    }

    // What the collect script returns (decoded off the main actor).
    nonisolated private struct Result: Decodable {
        let messages: [Message]
        let error: String?
    }

    nonisolated struct Message: Codable {
        let domID: String
        let fromMe: Bool
        let text: String
        let images: [Image]
        /// Shared links' cards (their pictures aren't in `images`).
        let links: [Link]
        let reactions: [Reaction]
    }

    /// A reaction pill: its emoji and how many people reacted (the page doesn't say who).
    nonisolated struct Reaction: Codable {
        let emojis: [String]
        let count: Int
    }

    nonisolated struct Link: Codable {
        let url: String
        let title: String
        let description: String
        let image: Image?
    }

    nonisolated struct Image: Codable {
        let data: String
        let mimeType: String
        let width: Int
        let height: Int
    }

    /// Forgets everything (the account logged out). An import still reading the page may never
    /// finish (the page is closed), so it doesn't block the next account's.
    func reset() {
        generation += 1
        needsRestore = []
        done = []
        queue = []
        current = nil
        isRunning = false
        waiting = []
        tries = [:]
        oldest = [:]
        restoredAt = nil
    }

    /// The chat was opened: it's imported next.
    func importHistory(threadID: String) {
        guard !done.contains(threadID), current != threadID else { return }
        queue.removeAll { $0 == threadID }
        queue.insert(threadID, at: 0)
        waiting.remove(threadID)
        onStateChange?(threadID)
        runQueue()
    }

    /// The encrypted chats were just restored with the PIN: everything is worth importing again,
    /// and the recent chats are imported in the background.
    func restoreFinished() {
        CoreBridge.shared.log("WebHistoryImporter: restore finished")
        restoredAt = Date()
        needsRestore = []
        done = []
        tries = [:]
        oldest = [:]
        importRecentChats()
    }

    /// The chats are loaded (at launch): soon after a restore, the recent chats' import goes on.
    func chatsLoaded() {
        if isRestoring { importRecentChats() }
    }

    private func importRecentChats() {
        let generation = self.generation
        Task {
            // The chat list maps the chats to the web app's.
            await WebChatImporter.shared.runOnce()
            guard generation == self.generation else { return }
            let recent = ChatStore.shared.conversations.filter { $0.isEncrypted && !$0.isGroup }.prefix(Self.recentChatCount)
            for conversation in recent where !isPending(conversation.id) {
                queue.append(conversation.id)
                onStateChange?(conversation.id)
            }
            runQueue()
        }
    }

    /// Imports the queued chats one after the other.
    private func runQueue() {
        guard !isRunning else { return }
        isRunning = true
        let generation = self.generation
        Task {
            while generation == self.generation, !queue.isEmpty {
                let threadID = queue.removeFirst()
                current = threadID
                onStateChange?(threadID)
                let outcome = await importOnce(threadID)
                guard generation == self.generation else { return }
                current = nil
                finish(threadID, outcome)
                onStateChange?(threadID)
            }
            if generation == self.generation { isRunning = false }
        }
    }

    private enum Outcome {
        /// Everything the web app has is imported.
        case complete
        /// The web app may still be downloading older messages: import it again later.
        case moreMayCome
        /// The web app doesn't show the chat's history (it isn't restored with the PIN).
        case needsRestore
        /// Something went wrong; it's tried again when the chat is opened.
        case failed
    }

    private func finish(_ threadID: String, _ outcome: Outcome) {
        switch outcome {
        case .complete:
            needsRestore.remove(threadID)
            done.insert(threadID)
        case .needsRestore:
            needsRestore.insert(threadID)
        case .moreMayCome:
            needsRestore.remove(threadID)
            let tried = tries[threadID, default: 0] + 1
            tries[threadID] = tried
            if tried < Self.maxTries {
                retryLater(threadID)
            } else {
                done.insert(threadID)
            }
        case .failed:
            break
        }
    }

    private func retryLater(_ threadID: String) {
        waiting.insert(threadID)
        let generation = self.generation
        Task {
            try? await Task.sleep(for: Self.retryDelay)
            // Opened meanwhile (imported then), or logged out.
            guard generation == self.generation, waiting.remove(threadID) != nil else { return }
            if !queue.contains(threadID) { queue.append(threadID) }
            runQueue()
        }
    }

    /// Reads the chat from the web app and stores what's new.
    private func importOnce(_ threadID: String) async -> Outcome {
        let account = ChatStore.shared.account?.id
        do {
            struct WebIDResult: Decodable { let webID: String }
            struct Params: Encodable { let threadID: String }
            let webID = try await CoreBridge.shared.call("web.threadWebID", Params(threadID: threadID), as: WebIDResult.self).webID
            guard !webID.isEmpty else {
                CoreBridge.shared.log("WebHistoryImporter: no web chat known for \(threadID)")
                return .needsRestore
            }
            let web = WebSyncController.shared
            guard await web.start(showWindow: false) else { return .failed }
            CoreBridge.shared.log("WebHistoryImporter: \(threadID) → web chat \(webID), collecting")
            let result = try await web.withExclusiveAccess {
                await web.navigate(toPath: "/messages/e2ee/t/\(webID)/")
                return try await web.evaluate(Self.collectScript(userID: threadID, max: Self.maxMessages), as: Result.self)
            }
            if let error = result.error {
                CoreBridge.shared.log("WebHistoryImporter: \(threadID): \(error)")
            }
            // Logged out (or in as someone else) while the page was read.
            guard ChatStore.shared.account?.id == account else { return .failed }
            struct ImportParams: Encodable { let threadID: String; let messages: [Message] }
            struct ImportResult: Decodable { let imported: Int; let unrestored: Int }
            let imported = try await CoreBridge.shared.call(
                "web.importMessages", ImportParams(threadID: threadID, messages: result.messages), as: ImportResult.self
            )
            CoreBridge.shared.log("WebHistoryImporter: \(threadID): collected \(result.messages.count), imported \(imported.imported), not restored \(imported.unrestored)")
            // The core emits each stored message as an event, so open chats update by themselves.

            // Nothing readable (no messages, placeholders, or only the "now encrypted" notice).
            let readable = result.messages.contains { !$0.text.isEmpty || !$0.images.isEmpty || !$0.links.isEmpty }
            if !readable || imported.unrestored > 0 {
                return isRestoring ? .moreMayCome : .needsRestore
            }
            if result.messages.count >= Self.maxMessages { return .complete }
            // Nothing older than last time: that's all there is.
            let oldestNow = result.messages.compactMap { Self.timestamp(ofDOMID: $0.domID) }.min()
            defer { oldest[threadID] = oldestNow }
            if let oldestNow, oldestNow == oldest[threadID] { return .complete }
            return isRestoring ? .moreMayCome : .complete
        } catch {
            CoreBridge.shared.log("WebHistoryImporter: \(threadID): \(error)")
            return .failed
        }
    }

    /// The time of a message from its web ID ("<user>@msgr.<message ID>"): Messenger message IDs
    /// are milliseconds << 22 | random (as in the core's webMessageID).
    private static func timestamp(ofDOMID domID: String) -> Int64? {
        guard let dot = domID.lastIndex(of: "."), let id = UInt64(domID[domID.index(after: dot)...]) else { return nil }
        return Int64(id >> 22)
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
        // Older messages can take a moment to load (longer while the web app is still restoring).
        let stable = 0;
        for (let i = 0; i < 80 && scroller && stable < 4 && seen.size < \(max); i++) {
          const before = seen.size;
          scroller.scrollTop = 0;
          await sleep(2000);
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
