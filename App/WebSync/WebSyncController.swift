import AppKit
import WebKit

/// Runs Messenger's own web app (facebook.com/messages) in a web view that shares the app's
/// session. Its data store is persistent, so once you've restored encrypted chats there with your
/// PIN, the web app keeps them, and we can read the decrypted chats it displays.
final class WebSyncController: NSWindowController, WKNavigationDelegate, NSWindowDelegate {
    static let shared = WebSyncController()

    let webView: WKWebView
    /// Where the web view lives while its own window is closed. WebKit pauses lazy loading and
    /// animation frames for pages that aren't in a visible window, so it's kept (invisibly) in
    /// the main window instead of an offscreen one.
    private weak var invisibleHost: NSView?
    private var hasLoaded = false
    private var loadWaiters: [CheckedContinuation<Void, Never>] = []

    /// Fixed so the restored web app state survives relaunches.
    private static let storeID = UUID(uuidString: "6F1C2B7E-4E1A-4C55-9B7A-2D0E7F9A1C31")!
    static let messagesURL = URL(string: "https://www.facebook.com/messages/")!

    private init() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = WKWebsiteDataStore(forIdentifier: Self.storeID)
        if UserDefaults.standard.bool(forKey: "WebNetLog") {
            config.userContentController.addUserScript(WebDOMInspector.networkLogScript)
        }
        CallManager.install(in: config)
        webView = InvisibleWhenTransparentWebView(frame: NSRect(x: 0, y: 0, width: 1100, height: 800), configuration: config)
        // Calls open in popups, shown in call windows.
        webView.uiDelegate = CallManager.shared

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Messenger Web (encrypted chat restore)"
        window.isReleasedWhenClosed = false
        window.contentView = NSView()
        super.init(window: window)
        window.delegate = self
        webView.navigationDelegate = self
    }

    /// Keeps the web view rendering inside a visible window without showing it.
    func embedInvisibly(in host: NSView) {
        invisibleHost = host
        guard window?.isVisible != true else { return }
        webView.removeFromSuperview()
        webView.alphaValue = 0
        // A fixed desktop size keeps Messenger's full two-column layout regardless of the host.
        // Tall, so the (virtualized) chat list renders as many rows as possible at once.
        webView.frame = NSRect(x: 0, y: 0, width: 1200, height: 3000)
        webView.autoresizingMask = []
        host.addSubview(webView, positioned: .below, relativeTo: nil)
    }

    /// While the main window is being resized, the hidden web view leaves it: WebKit syncs every
    /// step of a window resize with the page's rendering process (Core Animation fences), which
    /// made resizing lag. It comes back when the resize ends.
    func leaveWindowForLiveResize() {
        guard window?.isVisible != true, let host = invisibleHost, webView.superview === host else { return }
        isAwayForLiveResize = true
        webView.removeFromSuperview()
    }

    func returnAfterLiveResize() {
        guard isAwayForLiveResize else { return }
        isAwayForLiveResize = false
        if let host = invisibleHost, window?.isVisible != true {
            embedInvisibly(in: host)
        }
    }

    private var isAwayForLiveResize = false

    func windowWillClose(_ notification: Notification) {
        restoreWatchTimer?.invalidate()
        restoreWatchTimer = nil
        if let host = invisibleHost {
            embedInvisibly(in: host)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Copies the core's session cookies into the web view and loads Messenger. Returns false
    /// (without loading anything) when the app isn't logged in.
    @discardableResult
    func start(showWindow: Bool) async -> Bool {
        if sessionSetup == nil {
            sessionSetup = Task { await setUpSession() }
        }
        guard await sessionSetup?.value == true else {
            sessionSetup = nil
            return false
        }
        if !hasLoaded {
            await withCheckedContinuation { loadWaiters.append($0) }
        }
        if showWindow, let contentView = window?.contentView {
            webView.removeFromSuperview()
            webView.alphaValue = 1
            webView.frame = contentView.bounds
            webView.autoresizingMask = [.width, .height]
            contentView.addSubview(webView)
            self.showWindow(nil)
            window?.center()
            NSApp.activate()
            watchForFinishedRestore()
            // Opening an encrypted chat is what brings up the restore (PIN) prompt.
            if (try? await evaluate(Self.openFirstChatScript, as: Bool.self)) != true {
                CoreBridge.shared.log("WebSync: no chat to open for the restore")
            }
        }
        return true
    }

    /// The first start's setup (later ones wait for the same one); false if not logged in.
    private var sessionSetup: Task<Bool, Never>?

    private func setUpSession() async -> Bool {
        // Identify as what this really is (Safari's engine). Pretending to be Chrome makes
        // Messenger serve Chrome-only code, which breaks the encrypted chat restore.
        webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15"
        await resetDataIfNeeded()
        guard let cookies = try? await CoreBridge.shared.call("session.cookies", as: [String: String].self),
              let userID = cookies["c_user"] else { return false }
        let store = webView.configuration.websiteDataStore.httpCookieStore
        // What's stored belongs to the account that used the web app last: another account's
        // session and restored chats must not show up in this one.
        if let previous = await store.allCookies().first(where: { $0.name == "c_user" })?.value, previous != userID {
            CoreBridge.shared.log("WebSync: the web app had another account's data; deleting it")
            await deleteData()
        }
        for (name, value) in cookies {
            let properties: [HTTPCookiePropertyKey: Any] = [
                .domain: ".facebook.com", .path: "/", .name: name, .value: value,
                .secure: "TRUE", .expires: Date().addingTimeInterval(365 * 24 * 3600),
            ]
            if let cookie = HTTPCookie(properties: properties) {
                await store.setCookie(cookie)
            }
        }
        hasLoaded = false
        webView.load(URLRequest(url: Self.messagesURL))
        return true
    }

    /// The account is gone (logged out, or its session expired): the page is closed, so nothing
    /// reads it any more. `deletingData`: also forget its session and restored chats (logging out).
    func endSession(deletingData: Bool) async {
        close()
        sessionSetup = nil
        // Work for the account (an import reading the page) may never finish now that the page
        // is gone: it no longer holds the page, and work waiting for it is cancelled.
        session += 1
        isBusy = false
        let waiting = busyWaiters
        busyWaiters = []
        waiting.forEach { $0.resume(throwing: CancellationError()) }
        hasLoaded = false
        webView.load(URLRequest(url: URL(string: "about:blank")!))
        if deletingData {
            await deleteData()
        }
    }

    private func deleteData() async {
        await webView.configuration.websiteDataStore.removeData(
            ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast
        )
    }

    /// Clicks the first encrypted chat in the web app's chat list (or the first chat if none).
    private static let openFirstChatScript = """
    const sleep = ms => new Promise(r => setTimeout(r, ms));
    const listLinks = selector => Array.from(document.querySelectorAll(selector)).filter(a => !a.closest('[role="main"]'));
    for (let i = 0; i < 20; i++) {
      const link = listLinks('a[href^="/messages/e2ee/t/"]')[0] || listLinks('a[href^="/messages/t/"]')[0];
      if (link) { link.click(); return JSON.stringify(true); }
      await sleep(500);
    }
    return JSON.stringify(false);
    """

    // MARK: - Closing when the restore is done

    private var restoreWatchTimer: Timer?

    /// Called when the PIN was entered and its prompt went away (before the window closes).
    var onRestoreFinished: (() -> Void)?

    /// Closes the window once the PIN prompt has been shown and then went away (restore finished).
    /// If the prompt never shows (already restored), the window stays until the user closes it.
    private func watchForFinishedRestore() {
        guard restoreWatchTimer == nil else { return }
        var sawPrompt = false
        var goneCount = 0
        var isChecking = false
        restoreWatchTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !isChecking else { return }
                isChecking = true
                Task {
                    defer { isChecking = false }
                    guard let showing = try? await self.evaluate(Self.pinPromptScript, as: Bool.self) else { return }
                    if showing {
                        if !sawPrompt { CoreBridge.shared.log("WebSync: PIN prompt shown") }
                        sawPrompt = true
                        goneCount = 0
                    } else if sawPrompt {
                        goneCount += 1
                        // Twice in a row, so a re-render between steps doesn't count.
                        if goneCount >= 2 {
                            CoreBridge.shared.log("WebSync: PIN prompt gone, closing restore window")
                            self.onRestoreFinished?()
                            self.close()
                        }
                    }
                }
            }
        }
    }

    /// True while the page shows the PIN flow: a code/password field, or a dialog about the PIN.
    /// Creating a PIN takes several steps, some without a field (an explanation, confirming,
    /// "done"); the window must stay open through all of them.
    private static let pinPromptScript = """
    const visible = el => { const r = el.getBoundingClientRect(); return r.width > 0 && r.height > 0; };
    const fields = document.querySelectorAll('[role="dialog"] input, input[type="password"], input[autocomplete="one-time-code"], input[inputmode="numeric"]');
    const field = Array.from(fields).some(el => visible(el) && (el.closest('[role="dialog"]') || el.type === 'password' || el.inputMode === 'numeric' || el.autocomplete === 'one-time-code'));
    // "PIN" in every language the web app uses ("PIN-kód", "code PIN", …).
    const dialog = Array.from(document.querySelectorAll('[role="dialog"]')).some(el => visible(el) && /\\bPIN\\b/.test(el.innerText));
    return JSON.stringify(field || dialog);
    """

    // MARK: - Exclusive use

    private var isBusy = false
    private var busyWaiters: [CheckedContinuation<Void, Error>] = []
    /// Counts the sessions ended (endSession): work from an earlier one no longer holds the page.
    private var session = 0

    /// Runs `body` while no other importer is driving the page (they navigate it). Throws if
    /// the session ends while waiting.
    func withExclusiveAccess<T>(_ body: () async throws -> T) async throws -> T {
        if isBusy {
            try await withCheckedThrowingContinuation { busyWaiters.append($0) }
        }
        let session = self.session
        isBusy = true
        defer {
            if session == self.session {
                if busyWaiters.isEmpty {
                    isBusy = false
                } else {
                    busyWaiters.removeFirst().resume()
                }
            }
        }
        return try await body()
    }

    /// Opens a path in the web app: client-side if a link to it is on the page, otherwise by loading it.
    /// `fresh`: if the page is already there, it's loaded again (a chat scrolled through by an
    /// earlier reader can stop loading older messages).
    func navigate(toPath path: String, fresh: Bool = false) async {
        let trimmed = { (p: String) in p.trimmingCharacters(in: CharacterSet(charactersIn: "/")) }
        if let current = webView.url?.path, trimmed(current) == trimmed(path) {
            guard fresh else { return }
            hasLoaded = false
            webView.load(URLRequest(url: URL(string: "https://www.facebook.com\(path)")!))
            await withCheckedContinuation { loadWaiters.append($0) }
            return
        }
        let script = """
        const link = document.querySelector('a[href="\(path)"]');
        if (link) { link.click(); return JSON.stringify(true); }
        return JSON.stringify(false);
        """
        if (try? await evaluate(script, as: Bool.self)) == true {
            return
        }
        hasLoaded = false
        webView.load(URLRequest(url: URL(string: "https://www.facebook.com\(path)")!))
        await withCheckedContinuation { loadWaiters.append($0) }
    }

    /// Bump to wipe the web view's stored data once (e.g. after changing how it identifies itself).
    private static let dataVersion = 2

    private func resetDataIfNeeded() async {
        let defaults = UserDefaults.standard
        guard defaults.integer(forKey: "WebDataVersion") < Self.dataVersion else { return }
        await deleteData()
        defaults.set(Self.dataVersion, forKey: "WebDataVersion")
    }

    func load(_ url: URL) {
        webView.load(URLRequest(url: url))
    }

    /// Runs JavaScript that returns a JSON string and decodes it.
    func evaluate<T: Decodable>(_ script: String, as type: T.Type) async throws -> T {
        let result = try await webView.callAsyncJavaScript(script, contentWorld: .page)
        guard let json = result as? String else { throw CoreBridge.CoreError(message: "Script returned no JSON") }
        return try JSONDecoder().decode(T.self, from: Data(json.utf8))
    }

    /// Like evaluate, but gives up (throws) once `giveUp` says so (checked every second). A
    /// script whose page was replaced while it ran never returns.
    func evaluate<T: Decodable>(_ script: String, as type: T.Type, giveUpWhen giveUp: @escaping () -> Bool) async throws -> T {
        let once = ResumeOnce<T>()
        return try await withCheckedThrowingContinuation { continuation in
            once.continuation = continuation
            Task {
                do { once.finish(.success(try await self.evaluate(script, as: type))) } catch { once.finish(.failure(error)) }
            }
            Task {
                while once.continuation != nil {
                    try? await Task.sleep(for: .seconds(1))
                    if once.continuation != nil, giveUp() {
                        once.finish(.failure(CoreBridge.CoreError(message: "Messenger web stopped answering")))
                    }
                }
            }
        }
    }

    /// Loads Messenger again (after a script got stuck), waiting until it's loaded.
    func reloadPage() async {
        hasLoaded = false
        webView.load(URLRequest(url: Self.messagesURL))
        await withCheckedContinuation { loadWaiters.append($0) }
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if !hasLoaded {
            hasLoaded = true
            let waiters = loadWaiters
            loadWaiters = []
            waiters.forEach { $0.resume() }
        }
        WebDOMInspector.pageDidLoad(self)
    }
}

/// A continuation resumed by whichever finishes first (evaluate(_:as:giveUpWhen:)).
private final class ResumeOnce<T> {
    var continuation: CheckedContinuation<T, Error>?

    func finish(_ result: Result<T, Error>) {
        continuation?.resume(with: result)
        continuation = nil
    }
}

/// While embedded invisibly, the web view must not swallow clicks meant for the chat pane.
private final class InvisibleWhenTransparentWebView: WKWebView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        alphaValue == 0 ? nil : super.hitTest(point)
    }

    // While invisible, the page focusing its own fields mustn't take the keyboard (⌘V would
    // paste into the hidden page instead of the message field).
    override var acceptsFirstResponder: Bool {
        alphaValue == 0 ? false : super.acceptsFirstResponder
    }

    override func becomeFirstResponder() -> Bool {
        alphaValue == 0 ? false : super.becomeFirstResponder()
    }

    // While invisible behind the chat it still receives drags dropped there; hand them to the
    // chat (its superview), so files can be dropped anywhere on the chat.
    private var dropTarget: NSView? { alphaValue == 0 ? superview : nil }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        dropTarget?.draggingEntered(sender) ?? super.draggingEntered(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        dropTarget?.draggingUpdated(sender) ?? super.draggingUpdated(sender)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        if let dropTarget { dropTarget.draggingExited(sender) } else { super.draggingExited(sender) }
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        dropTarget?.prepareForDragOperation(sender) ?? super.prepareForDragOperation(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        dropTarget?.performDragOperation(sender) ?? super.performDragOperation(sender)
    }

    override func concludeDragOperation(_ sender: NSDraggingInfo?) {
        if let dropTarget { dropTarget.concludeDragOperation(sender) } else { super.concludeDragOperation(sender) }
    }
}
