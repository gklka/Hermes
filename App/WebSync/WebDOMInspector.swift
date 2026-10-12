import Foundation
import WebKit

/// Development aid: writes a structural summary of the Messenger web page (roles, aria labels,
/// links, short text) to Application Support/MessengerMac/webdump.json, so the importer's
/// selectors can be written against the real page.
///
/// Enable with: defaults write com.kristofgruber.MessengerMac WebDumpEnabled -bool YES
/// Optionally open a thread first: defaults write com.kristofgruber.MessengerMac WebDumpThread <id>
enum WebDOMInspector {
    private static var dumpedThread = false
    private static var consoleTimer: Timer?

    /// Dev-only (defaults key WebNetLog): records the page's GraphQL request names/variables and
    /// response sizes in window.__mmNet, to learn which requests carry which data.
    static let networkLogScript = WKUserScript(source: """
        (() => {
          const log = window.__mmNet = [];
          const params = body => { try { return Object.fromEntries(new URLSearchParams(body)); } catch (e) { return {}; } };
          const record = (url, body, resp) => {
            const p = typeof body === 'string' ? params(body) : {};
            log.push({ t: Date.now(), url: String(url).slice(0, 120), name: p.fb_api_req_friendly_name, doc: p.doc_id,
                       vars: (p.variables || '').slice(0, 600), size: resp ? resp.length : -1,
                       head: resp ? resp.slice(0, 300) : '' });
          };
          const origFetch = window.fetch;
          window.fetch = async function (input, init) {
            const res = await origFetch.apply(this, arguments);
            try { const c = res.clone(); c.text().then(t => record(input && input.url || input, init && init.body, t)); } catch (e) {}
            return res;
          };
          // WebSocket frames: record the URL and any LightSpeed database IDs / task labels mentioned.
          const wsLog = window.__mmWS = [];
          const decode = data => {
            try {
              if (typeof data === 'string') return data;
              const bytes = data instanceof ArrayBuffer ? new Uint8Array(data) : new Uint8Array(data.buffer || data);
              return new TextDecoder('utf-8', { fatal: false }).decode(bytes);
            } catch (e) { return ''; }
          };
          const summarize = (dir, url, data) => {
            const text = decode(data);
            const dbs = Array.from(new Set((text.match(/database[\\\\"]*:\\s*(\\d+)/g) || []).map(s => s.replace(/\\D/g, ''))));
            const labels = Array.from(new Set((text.match(/label[\\\\"]*:\\s*[\\\\"]*(\\d+)/g) || []).map(s => s.replace(/\\D/g, ''))));
            wsLog.push({ t: Date.now(), dir, url: String(url).slice(0, 80), len: text.length, dbs, labels, head: text.replace(/[^\\x20-\\x7e]/g, '.').slice(0, 200),
                         full: String(url).includes('/ws/lightspeed') ? text : undefined });
          };
          const OrigWS = window.WebSocket;
          window.WebSocket = function (url, protocols) {
            const ws = protocols === undefined ? new OrigWS(url) : new OrigWS(url, protocols);
            const origSend = ws.send.bind(ws);
            ws.send = data => { summarize('out', url, data); return origSend(data); };
            ws.addEventListener('message', e => summarize('in', url, e.data));
            return ws;
          };
          window.WebSocket.prototype = OrigWS.prototype;
          Object.assign(window.WebSocket, { CONNECTING: 0, OPEN: 1, CLOSING: 2, CLOSED: 3 });
          const open = XMLHttpRequest.prototype.open, send = XMLHttpRequest.prototype.send;
          XMLHttpRequest.prototype.open = function (m, u) { this.__mmUrl = u; return open.apply(this, arguments); };
          XMLHttpRequest.prototype.send = function (body) {
            this.addEventListener('load', () => { try { record(this.__mmUrl, body, this.responseType === '' || this.responseType === 'text' ? this.responseText : ''); } catch (e) {} });
            return send.apply(this, arguments);
          };
        })();
        """, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .page)

    private static var supportDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MessengerMac")
    }

    /// Dev console: if webeval.js appears in the data folder, run it in the page (as an async
    /// function body) and write the returned value to webeval.out.
    private static func startConsole(_ controller: WebSyncController) {
        guard consoleTimer == nil else { return }
        consoleTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            MainActor.assumeIsolated {
                // importthread.txt containing a thread ID triggers a history import for it.
                let importFile = supportDir.appendingPathComponent("importthread.txt")
                if let threadID = try? String(contentsOf: importFile, encoding: .utf8) {
                    try? FileManager.default.removeItem(at: importFile)
                    WebHistoryImporter.shared.importHistory(threadID: threadID.trimmingCharacters(in: .whitespacesAndNewlines))
                }
                // dumpviews.txt lists the views registered as drop targets (to views.out).
                let dumpViewsFile = supportDir.appendingPathComponent("dumpviews.txt")
                if FileManager.default.fileExists(atPath: dumpViewsFile.path) {
                    try? FileManager.default.removeItem(at: dumpViewsFile)
                    try? dropTargetDump().write(to: supportDir.appendingPathComponent("views.out"), atomically: true, encoding: .utf8)
                }
                // resizetest.txt times resizing the main window (to resize.out).
                let resizeTestFile = supportDir.appendingPathComponent("resizetest.txt")
                if FileManager.default.fileExists(atPath: resizeTestFile.path) {
                    try? FileManager.default.removeItem(at: resizeTestFile)
                    try? resizeBenchmark().write(to: supportDir.appendingPathComponent("resize.out"), atomically: true, encoding: .utf8)
                }
                // testnotify.txt posts test notifications in two fake chats.
                let testNotifyFile = supportDir.appendingPathComponent("testnotify.txt")
                if FileManager.default.fileExists(atPath: testNotifyFile.path) {
                    try? FileManager.default.removeItem(at: testNotifyFile)
                    Notifier.shared.postTest()
                }
                let input = supportDir.appendingPathComponent("webeval.js")
                guard let script = try? String(contentsOf: input, encoding: .utf8) else { return }
                try? FileManager.default.removeItem(at: input)
                Task {
                    let output: String
                    do {
                        let result = try await controller.webView.callAsyncJavaScript(script, contentWorld: .page)
                        output = (result as? String) ?? String(describing: result ?? "null")
                    } catch {
                        output = "ERROR: \(error)"
                    }
                    try? output.write(to: supportDir.appendingPathComponent("webeval.out"), atomically: true, encoding: .utf8)
                }
            }
        }
    }

    /// Resizes the main window in steps (drawing each) and reports the time per step, with
    /// everything shown and with each suspect part hidden.
    private static func resizeBenchmark() -> String {
        guard let window = NSApp.windows.first(where: { $0.contentViewController is NSSplitViewController && $0.isVisible }),
              let content = window.contentView else { return "no main window" }
        func all(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(all) }
        let views = all(content)
        let chat = views.first { String(describing: type(of: $0)) == "DropTargetView" }
        let chatViews = chat.map(all) ?? []
        let messageList = chatViews.first { ($0 as? NSScrollView)?.documentView is NSTableView }
        let webView = chatViews.first { $0 is WKWebView }
        let sidebarList = views.first { ($0 as? NSScrollView)?.documentView is NSTableView && !chatViews.contains($0) }

        let original = window.frame
        func measure(_ label: String, hiding view: NSView?) -> String {
            view?.isHidden = true
            defer { view?.isHidden = false }
            let steps = 40
            let start = CACurrentMediaTime()
            for step in 0..<steps {
                var frame = original
                frame.size.width = original.width - CGFloat(step % 20) * 6
                window.setFrame(frame, display: true)
            }
            window.setFrame(original, display: true)
            let ms = (CACurrentMediaTime() - start) * 1000 / Double(steps)
            return String(format: "%@: %.1f ms per step", label, ms)
        }
        return [
            "window \(Int(original.width))x\(Int(original.height))",
            measure("everything", hiding: nil),
            measure("without message list", hiding: messageList),
            measure("without hidden web view", hiding: webView),
            measure("without sidebar list", hiding: sidebarList),
            measure("everything again", hiding: nil),
        ].joined(separator: "\n")
    }

    private static func dropTargetDump() -> String {
        var lines: [String] = []
        func visit(_ view: NSView, depth: Int) {
            let types = view.registeredDraggedTypes
            if !types.isEmpty {
                let frame = view.convert(view.bounds, to: nil)
                lines.append("\(String(repeating: "  ", count: depth))\(type(of: view)) hidden=\(view.isHiddenOrHasHiddenAncestor) alpha=\(view.alphaValue) frame=\(frame) types=\(types.count)")
            }
            for subview in view.subviews { visit(subview, depth: depth + 1) }
        }
        for window in NSApp.windows where window.isVisible {
            lines.append("WINDOW \(window.title)")
            if let content = window.contentView?.superview ?? window.contentView { visit(content, depth: 1) }
        }
        return lines.joined(separator: "\n")
    }

    static func pageDidLoad(_ controller: WebSyncController) {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: "WebDumpEnabled") else { return }
        startConsole(controller)
        if let thread = defaults.string(forKey: "WebDumpThread"), !thread.isEmpty, !dumpedThread {
            dumpedThread = true
            controller.load(URL(string: "https://www.facebook.com/messages/e2ee/t/\(thread)/")!)
            return
        }
        Task {
            // The web app renders asynchronously after the load event.
            try? await Task.sleep(for: .seconds(15))
            await dump(controller)
        }
    }

    static func dump(_ controller: WebSyncController) async {
        let script = """
        const out = [];
        const clip = (s, n) => (s || '').replace(/\\s+/g, ' ').trim().slice(0, n);
        const walk = (el, depth) => {
            if (out.length > 3000) return;
            const role = el.getAttribute('role');
            const aria = el.getAttribute('aria-label');
            const href = el.tagName === 'A' ? el.getAttribute('href') : null;
            const testid = el.getAttribute('data-testid');
            const dir = el.getAttribute('dir');
            const own = Array.from(el.childNodes).filter(n => n.nodeType === 3).map(n => n.textContent).join(' ');
            if (role || aria || href || testid || clip(own, 1)) {
                out.push({ d: depth, t: el.tagName.toLowerCase(), role, aria: clip(aria, 80), href, testid, dir,
                           text: clip(own, 60), img: el.tagName === 'IMG' ? clip(el.getAttribute('alt'), 40) : undefined });
            }
            for (const child of el.children) walk(child, depth + 1);
        };
        walk(document.body, 0);
        return JSON.stringify({ url: location.href, title: document.title, nodes: out });
        """
        do {
            let result = try await controller.webView.callAsyncJavaScript(script, contentWorld: .defaultClient)
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            let url = support.appendingPathComponent("MessengerMac/webdump.json")
            try (result as? String ?? "null").write(to: url, atomically: true, encoding: .utf8)
            NSLog("WebDOMInspector: wrote \(url.path)")
        } catch {
            NSLog("WebDOMInspector: dump failed: \(error)")
        }
    }
}
