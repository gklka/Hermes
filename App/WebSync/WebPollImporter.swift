import Foundation

/// Reads a group chat's polls from Messenger's web app (its inline poll cards) and stores them,
/// so polls show in Hermes even when the core can't rebuild them from history. The web app
/// delivers a poll's full card (question, options, vote counts) only live or in its own thread
/// view, never in the history the core fetches, so this fills the gap for restored chats.
///
/// Regular (non-encrypted) chats only; polls there are XMA cards the web page renders inline.
final class WebPollImporter {
    static let shared = WebPollImporter()

    /// Threads imported this session (once each; a new poll or vote arrives live anyway).
    private var done: Set<String> = []
    /// Serializes imports: the web view holds one thread at a time.
    private var inFlight: Task<Void, Never>?

    struct Option: Codable {
        let text: String
        let voteCount: Int
        let percent: Int
        var voted: Bool = false
    }

    struct Poll: Codable {
        let messageID: String
        let question: String
        let options: [Option]
        var moreCount: Int = 0
    }

    private struct Params: Encodable { let threadID: String; let polls: [Poll] }

    /// Imports a chat's polls once per session (does nothing if already done or not a group).
    /// Imports run one at a time; a new request waits for the current one.
    func importOnce(threadID: String) {
        guard done.insert(threadID).inserted else { return }
        let previous = inFlight
        inFlight = Task {
            await previous?.value
            await importPolls(threadID: threadID)
        }
    }

    /// Lets a chat be re-imported (after a resync forgot its messages).
    func reset(threadID: String) { done.remove(threadID) }

    private func importPolls(threadID: String) async {
        let web = WebSyncController.shared
        CoreBridge.shared.log("WebPollImporter: starting for \(threadID)")
        guard await web.start(showWindow: false) else {
            CoreBridge.shared.log("WebPollImporter: web app not available")
            return
        }
        do {
            try await web.withExclusiveAccess {
                await web.navigate(toPath: "/messages/t/\(threadID)/")
                // The thread, then its poll card, render asynchronously; wait for the card. A poll
                // card is only built once its message list row is in view, so scroll to the end.
                var result: [Poll] = []
                for _ in 1...12 {
                    try? await Task.sleep(for: .seconds(2))
                    let diag = try? await web.evaluate(Self.prepareScript(threadID: threadID), as: Diag.self)
                    guard diag?.onThread == true else { continue }
                    result = (try? await web.evaluate(Self.collectScript, as: [Poll].self)) ?? []
                    if !result.isEmpty { break }
                }
                CoreBridge.shared.log("WebPollImporter: scraped \(result.count) poll(s) for \(threadID)")
                guard !result.isEmpty else { return }
                try await CoreBridge.shared.call("polls.importScraped", Params(threadID: threadID, polls: result))
            }
        } catch {
            CoreBridge.shared.log("WebPollImporter: \(threadID) failed: \(error)")
        }
    }

    private struct Diag: Decodable { let onThread: Bool }

    /// Checks the page is on the thread and nudges the message list to the end so a poll card
    /// (rendered only when its row is in view) appears.
    private static func prepareScript(threadID: String) -> String {
        """
        if (!location.href.includes("\(threadID)")) return JSON.stringify({ onThread: false });
        const sc = document.querySelector('[role="main"]');
        if (sc) { const g = sc.querySelector('[role="grid"]') || sc; g.scrollTop = g.scrollHeight; }
        return JSON.stringify({ onThread: true });
        """
    }

    /// Reads every inline poll card in the open thread: its message, question, options and votes.
    ///
    /// Language-independent: a poll card is found by its structure — a message holding option rows,
    /// where an option is a short text with its own vote-bar (a `width:…%` element). The question
    /// is the text just before the first option; vote counts come from the options' numeric aria
    /// labels and the bar widths, none of which depend on the UI language.
    private static let collectScript = """
    const num = s => { const m = (s || '').match(/\\d+/); return m ? parseInt(m[0], 10) : 0; };
    const isBar = el => { const st = el.getAttribute && el.getAttribute('style'); return st ? /width:\\s*[\\d.]+%/.test(st) : false; };
    // Messages that contain option bars are candidate poll cards.
    const byMid = {};
    document.querySelectorAll('[role="main"] [style*="width"]').forEach(el => {
      if (!isBar(el)) return;
      const h = el.closest('[data-message-id]');
      if (h && !byMid[h.getAttribute('data-message-id')]) byMid[h.getAttribute('data-message-id')] = h;
    });
    const polls = [];
    for (const mid of Object.keys(byMid)) {
      const card = byMid[mid];
      // Linearize the card: text lines, numeric aria labels (vote counts) and bar widths, in order.
      const lines = [];
      const walk = (el, d) => {
        if (d > 18) return;
        const own = Array.from(el.childNodes).filter(n => n.nodeType === 3).map(n => n.textContent.trim()).filter(Boolean).join(' ');
        if (own) lines.push({ t: 'text', v: own });
        const al = el.getAttribute && el.getAttribute('aria-label');
        if (al && /\\d/.test(al) && al.length < 80) lines.push({ t: 'aria', v: num(al) });
        if (isBar(el)) lines.push({ t: 'bar', v: Math.round(parseFloat(el.getAttribute('style').match(/width:\\s*([\\d.]+)%/)[1])) });
        for (const c of el.children) walk(c, d + 1);
      };
      walk(card, 0);
      // For each text, an option if a bar follows it before the next text; carry its vote/percent.
      const textIdx = [];
      for (let k = 0; k < lines.length; k++) if (lines[k].t === 'text') textIdx.push(k);
      const rows = [];
      for (let t = 0; t < textIdx.length; t++) {
        const start = textIdx[t], end = t + 1 < textIdx.length ? textIdx[t + 1] : lines.length;
        let bar = -1, votes = -1;
        for (let k = start + 1; k < end; k++) {
          if (lines[k].t === 'bar' && bar < 0) bar = lines[k].v;
          if (lines[k].t === 'aria' && votes < 0) votes = lines[k].v;
        }
        rows.push({ text: lines[start].v, isOption: bar >= 0, voteCount: votes < 0 ? 0 : votes, percent: bar < 0 ? 0 : bar });
      }
      const firstOpt = rows.findIndex(r => r.isOption);
      if (firstOpt < 1) continue; // need a question (a text before the first option)
      const question = rows[firstOpt - 1].text;
      const options = rows.filter(r => r.isOption).map(r => ({ text: r.text, voteCount: r.voteCount, percent: r.percent, voted: false }));
      if (question && options.length >= 2) polls.push({ messageID: mid, question, options, moreCount: 0 });
    }
    return JSON.stringify(polls);
    """
}
