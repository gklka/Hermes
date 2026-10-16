import AppKit
import WebKit

/// Audio and video calls through Messenger's web app: there's no open implementation of Meta's
/// calling, so the hidden web view (WebSyncController) starts and answers calls, and the call
/// itself runs in the popup it opens, shown in a Hermes window (CallWindowController).
///
/// Outgoing: the web chat's call button is clicked; the page opens a blank popup and fills it in.
/// Incoming: the web app's signaling socket (/ws/rpsignaling, otherwise only keepalives) gets a
/// frame, then the page shows its incoming call dialog; its buttons are mirrored in a panel
/// (IncomingCallPanel), whose clicks click them.
final class CallManager: NSObject, WKUIDelegate, WKScriptMessageHandler {
    static let shared = CallManager()

    private var windows: [CallWindowController] = []
    /// The outgoing call's window, waiting for the page's popup.
    private var pendingWindow: CallWindowController?
    /// An incoming call was answered: its popup gets a new window until then.
    private var answeredUntil = Date.distantPast
    private var answeredName = ""
    private var incomingPanel: IncomingCallPanel?

    private var web: WebSyncController { .shared }

    /// Sets up the hidden web view's configuration (before its page loads).
    static func install(in config: WKWebViewConfiguration) {
        config.userContentController.addUserScript(WKUserScript(source: monitorScript, injectionTime: .atDocumentStart,
                                                                forMainFrameOnly: true, in: .page))
        config.userContentController.add(shared, contentWorld: .page, name: "hermesCall")
        // Popups are only accepted when a call expects one (createWebViewWith).
        config.preferences.javaScriptCanOpenWindowsAutomatically = true
        config.preferences.isElementFullscreenEnabled = true
        config.mediaTypesRequiringUserActionForPlayback = []
    }

    // MARK: - Outgoing calls

    func startCall(threadID: String, video: Bool) {
        if let pendingWindow {
            pendingWindow.showWindow(nil)
            return
        }
        let name = ChatStore.shared.conversation(threadID)?.name ?? "Call"
        let window = CallWindowController(title: name)
        add(window)
        pendingWindow = window
        window.showWindow(nil)
        NSApp.activate()
        CoreBridge.shared.log("Calls: starting \(video ? "video" : "audio") call in \(threadID)")
        Task {
            do {
                guard await web.start(showWindow: false) else { throw CallError.notLoggedIn }
                guard let path = await ChatStore.shared.webPath(for: threadID) else { throw CallError.chatNotOnWeb }
                let web = web
                let clicked = try await web.withExclusiveAccess {
                    // The window may have been closed while waiting for the page.
                    guard self.pendingWindow === window else { return false }
                    await web.navigate(toPath: path)
                    return try await web.evaluate(Self.clickCallButtonScript(video: video), as: Bool.self)
                }
                guard pendingWindow === window else { return }
                guard clicked else { throw CallError.noCallButton }
                try await Task.sleep(for: .seconds(20))
                if pendingWindow === window { throw CallError.didNotStart }
            } catch {
                guard pendingWindow === window else { return }
                pendingWindow = nil
                CoreBridge.shared.log("Calls: couldn't start the call: \(error)")
                window.fail(error.localizedDescription)
            }
        }
    }

    static let audioCallItem = NSToolbarItem.Identifier("audioCall")
    static let videoCallItem = NSToolbarItem.Identifier("videoCall")

    /// The chat toolbars' call buttons; `target` implements startAudioCall(_:) and startVideoCall(_:).
    static func toolbarItem(_ identifier: NSToolbarItem.Identifier, target: AnyObject) -> NSToolbarItem {
        let video = identifier == videoCallItem
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.image = NSImage(systemSymbolName: video ? "video" : "phone", accessibilityDescription: video ? "Video Call" : "Audio Call")
        item.label = video ? "Video Call" : "Audio Call"
        item.toolTip = item.label
        item.target = target
        item.action = video ? NSSelectorFromString("startVideoCall:") : NSSelectorFromString("startAudioCall:")
        return item
    }

    private func add(_ window: CallWindowController) {
        windows.append(window)
        window.onClose = { [weak self, weak window] in
            guard let self, let window else { return }
            self.windows.removeAll { $0 === window }
            if self.pendingWindow === window { self.pendingWindow = nil }
        }
    }

    enum CallError: LocalizedError {
        case notLoggedIn, chatNotOnWeb, noCallButton, didNotStart

        var errorDescription: String? {
            switch self {
            case .notLoggedIn: "Messenger web isn't logged in."
            case .chatNotOnWeb: "This chat wasn't found on Messenger web yet."
            case .noCallButton: "Messenger web didn't offer a call in this chat."
            case .didNotStart: "The call didn't start."
            }
        }
    }

    /// Clicks the chat header's call button: found by its icon, or else by its place (voice,
    /// video, then chat info), since its label is in the account's language.
    private static func clickCallButtonScript(video: Bool) -> String {
        """
        const sleep = ms => new Promise(r => setTimeout(r, ms));
        const icon = '\(video ? "M6.304 2h-.108" : "M4.776 1.111")';
        for (let i = 0; i < 30; i++) {
          const header = Array.from(document.querySelectorAll('[role="main"] [role="button"][aria-label]')).filter(el => {
            const r = el.getBoundingClientRect();
            return r.width > 0 && r.top >= 0 && r.top < 160 && el.querySelector('svg') && !el.closest('[role="log"], [role="article"]');
          });
          let button = header.find(el => (el.querySelector('svg path')?.getAttribute('d') || '').startsWith(icon));
          if (!button && header.length >= 3) button = header[header.length - 3 + \(video ? 1 : 0)];
          if (button) { button.click(); return JSON.stringify(true); }
          await sleep(500);
        }
        return JSON.stringify(false);
        """
    }

    // MARK: - Incoming calls

    private struct IncomingCall: Decodable {
        let text: String
        let image: String?
        let buttons: [IncomingCallPanel.Button]
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.webView === web.webView, let body = message.body as? [String: Any],
              let kind = body["kind"] as? String else { return }
        switch kind {
        case "signal":
            let length = body["length"] as? Int ?? 0
            let text = (body["text"] as? String ?? "").prefix(300)
            CoreBridge.shared.log("Calls: signaling frame, \(length) bytes: \(text)")
        case "snapshot":
            // No call dialog seen after a signaling frame: what the page showed, to learn from.
            let json = (try? JSONSerialization.data(withJSONObject: body)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
            CoreBridge.shared.log("Calls: no call dialog after signaling; page: \(json.prefix(1500))")
        case "incoming":
            guard let data = try? JSONSerialization.data(withJSONObject: body),
                  let call = try? JSONDecoder().decode(IncomingCall.self, from: data) else { return }
            CoreBridge.shared.log("Calls: incoming call dialog: \(call.text.replacingOccurrences(of: "\n", with: " | ")) "
                                  + "buttons: \(call.buttons.map { "\($0.label) (\($0.tone))" })")
            showIncoming(call)
        case "ended":
            CoreBridge.shared.log("Calls: incoming call dialog gone")
            incomingPanel?.close()
            incomingPanel = nil
        default:
            break
        }
    }

    private func showIncoming(_ call: IncomingCall) {
        let labels = Set(call.buttons.map(\.label))
        let lines = call.text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !labels.contains($0) }
        // The caller's chat: the longest chat name in the dialog (1:1 chats first).
        let conversation = ChatStore.shared.conversations
            .filter { !$0.name.isEmpty && call.text.contains($0.name) }
            .max { ($0.isGroup ? 0 : 1, $0.name.count) < ($1.isGroup ? 0 : 1, $1.name.count) }
        let name = conversation?.name ?? lines.first ?? "Messenger"
        let detail = lines.filter { $0 != name }.joined(separator: " · ")
        incomingPanel?.close()
        let panel = IncomingCallPanel(name: name, detail: detail, conversation: conversation, imageURL: call.image,
                                      buttons: call.buttons) { [weak self] button in
            self?.press(button, caller: name)
        }
        incomingPanel = panel
        panel.present()
        NSApp.requestUserAttention(.criticalRequest)
    }

    private func press(_ button: IncomingCallPanel.Button, caller: String) {
        incomingPanel?.close()
        incomingPanel = nil
        // Any button may answer (the page's labels aren't known): its popup is expected for a while.
        answeredUntil = Date().addingTimeInterval(15)
        answeredName = caller
        CoreBridge.shared.log("Calls: pressing \(button.label) (\(button.tone))")
        let script = """
        const button = document.querySelector('[data-hermes-call-button="\(button.index)"]');
        if (button) button.click();
        return JSON.stringify(!!button);
        """
        Task {
            if (try? await web.evaluate(script, as: Bool.self)) != true {
                CoreBridge.shared.log("Calls: the call dialog's button is gone")
            }
        }
    }

    // MARK: - WKUIDelegate

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        let window: CallWindowController
        if webView === web.webView, let pendingWindow {
            window = pendingWindow
            self.pendingWindow = nil
        } else if webView === web.webView, answeredUntil > Date() {
            answeredUntil = .distantPast
            window = CallWindowController(title: answeredName)
            add(window)
            window.showWindow(nil)
            NSApp.activate()
        } else {
            // Not a call (a link from a call page, or the hidden page on its own): the browser gets it.
            CoreBridge.shared.log("Calls: popup not expected: \(navigationAction.request.url?.absoluteString ?? "")")
            if let url = navigationAction.request.url, url.scheme?.hasPrefix("http") == true {
                NSWorkspace.shared.open(url)
            }
            return nil
        }
        CoreBridge.shared.log("Calls: call window opened")
        let callView = WKWebView(frame: .zero, configuration: configuration)
        callView.uiDelegate = self
        callView.customUserAgent = webView.customUserAgent
        window.attach(callView)
        return callView
    }

    /// The call page closed itself (the call ended).
    func webViewDidClose(_ webView: WKWebView) {
        windows.first { $0.webView === webView }?.close()
    }

    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                 decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        let isCall = windows.contains { $0.webView === webView }
        let host = origin.host
        let isMeta = host == "facebook.com" || host.hasSuffix(".facebook.com") || host == "messenger.com" || host.hasSuffix(".messenger.com")
        decisionHandler(isCall && isMeta ? .grant : .deny)
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo) async {
        guard let window = windows.first(where: { $0.webView === webView })?.window else { return }
        let alert = NSAlert()
        alert.messageText = message
        await alert.beginSheetModal(for: window)
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo) async -> Bool {
        guard let window = windows.first(where: { $0.webView === webView })?.window else { return false }
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        return await alert.beginSheetModal(for: window) == .alertFirstButtonReturn
    }

    // MARK: - The page script

    /// In the hidden web app's page (not in call popups): reports signaling frames, then looks
    /// for a dialog that appears after one (the incoming call), marks its buttons and reports
    /// them, and reports when it goes away.
    private static let monitorScript = """
    (() => {
      if (window.top !== window || window.opener || window.__hermesCalls) return;
      window.__hermesCalls = true;
      const post = msg => { try { window.webkit.messageHandlers.hermesCall.postMessage(msg); } catch (e) {} };
      const printable = bytes => {
        let s = '';
        for (let i = 0; i < bytes.length && s.length < 1500; i++) { const c = bytes[i]; s += c >= 32 && c < 127 ? String.fromCharCode(c) : '.'; }
        return s;
      };
      const visible = el => { const r = el.getBoundingClientRect(); return r.width > 0 && r.height > 0; };
      const label = el => (el.getAttribute('aria-label') || el.innerText || '').replace(/\\s+/g, ' ').trim().slice(0, 40);
      // Decline buttons are red and answer buttons green; the first colored element decides.
      const tone = el => {
        for (const node of [el, ...el.querySelectorAll('*')]) {
          const m = (getComputedStyle(node).backgroundColor.match(/[\\d.]+/g) || []).map(Number);
          if (m.length < 3 || (m.length > 3 && m[3] === 0)) continue;
          const [r, g, b] = m;
          if (r > g + 60 && r > b + 60) return 'decline';
          if (g > r + 40 && g > b) return 'accept';
          return '';
        }
        return '';
      };
      const dialogs = () => Array.from(document.querySelectorAll('[role="dialog"], [role="alertdialog"]')).filter(visible);
      const buttonsIn = el => Array.from(el.querySelectorAll('[role="button"], button')).filter(b => visible(b) && label(b));

      let baseline = null, current = null, timer = null, deadline = 0;
      const scan = () => {
        if (current) {
          if (current.isConnected && visible(current)) return;
          current = null;
          post({ kind: 'ended' });
        }
        if (Date.now() > deadline) { clearInterval(timer); timer = null; baseline = null; return; }
        const found = dialogs().find(d => !baseline.has(d) && buttonsIn(d).length >= 2);
        if (!found) return;
        current = found;
        const buttons = buttonsIn(found);
        buttons.forEach((b, i) => b.setAttribute('data-hermes-call-button', String(i)));
        const img = found.querySelector('img, image');
        post({ kind: 'incoming', text: found.innerText.slice(0, 400),
               image: img ? (img.getAttribute('src') || img.getAttribute('xlink:href') || img.getAttribute('href')) : null,
               buttons: buttons.map((b, i) => ({ index: i, label: label(b), tone: tone(b) })) });
      };
      const watch = () => {
        deadline = Date.now() + 60000;
        if (timer) return;
        baseline = new Set(dialogs());
        timer = setInterval(scan, 500);
        setTimeout(() => {
          if (current) return;
          const outside = Array.from(document.querySelectorAll('[role="button"][aria-label]')).filter(b => visible(b) && !b.closest('[role="main"], [role="navigation"]'));
          post({ kind: 'snapshot', dialogs: dialogs().map(d => d.innerText.slice(0, 200)), buttons: outside.map(label).slice(0, 40) });
        }, 6000);
      };
      const onFrame = bytes => {
        if (bytes.length < 24) return;  // keepalives and acknowledgements
        post({ kind: 'signal', length: bytes.length, text: printable(bytes) });
        watch();
      };

      const OrigWS = window.WebSocket;
      const HermesWS = function (url, protocols) {
        const ws = protocols === undefined ? new OrigWS(url) : new OrigWS(url, protocols);
        if (String(url).includes('/ws/rpsignaling')) {
          ws.addEventListener('message', e => {
            const d = e.data;
            if (typeof d === 'string') onFrame(new TextEncoder().encode(d));
            else if (d instanceof ArrayBuffer) onFrame(new Uint8Array(d));
            else if (d && d.arrayBuffer) d.arrayBuffer().then(b => onFrame(new Uint8Array(b)));
          });
        }
        return ws;
      };
      HermesWS.prototype = OrigWS.prototype;
      Object.assign(HermesWS, { CONNECTING: 0, OPEN: 1, CLOSING: 2, CLOSED: 3 });
      window.WebSocket = HermesWS;
    })();
    """
}
