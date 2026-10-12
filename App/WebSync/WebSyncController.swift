import AppKit
import WebKit

/// Runs Messenger's own web app (facebook.com/messages) in a web view that shares the app's
/// session. Its data store is persistent, so once you've restored encrypted chats there with your
/// PIN, the web app keeps them, and we can read the decrypted chats it displays.
final class WebSyncController: NSWindowController, WKNavigationDelegate, NSWindowDelegate {
    static let shared = WebSyncController()

    let webView: WKWebView
    private var didSetUpSession = false
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
        webView = InvisibleWhenTransparentWebView(frame: NSRect(x: 0, y: 0, width: 1100, height: 800), configuration: config)

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

    func windowWillClose(_ notification: Notification) {
        if let host = invisibleHost {
            embedInvisibly(in: host)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Copies the core's session cookies into the web view and loads Messenger.
    func start(showWindow: Bool) async {
        if !didSetUpSession {
            didSetUpSession = true
            // Identify as what this really is (Safari's engine). Pretending to be Chrome makes
            // Messenger serve Chrome-only code, which breaks the encrypted chat restore.
            webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15"
            await resetDataIfNeeded()
            let cookies = (try? await CoreBridge.shared.call("session.cookies", as: [String: String].self)) ?? [:]
            let store = webView.configuration.websiteDataStore.httpCookieStore
            for (name, value) in cookies {
                let properties: [HTTPCookiePropertyKey: Any] = [
                    .domain: ".facebook.com", .path: "/", .name: name, .value: value,
                    .secure: "TRUE", .expires: Date().addingTimeInterval(365 * 24 * 3600),
                ]
                if let cookie = HTTPCookie(properties: properties) {
                    await store.setCookie(cookie)
                }
            }
            webView.load(URLRequest(url: Self.messagesURL))
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
        }
    }

    // MARK: - Exclusive use

    private var isBusy = false
    private var busyWaiters: [CheckedContinuation<Void, Never>] = []

    /// Runs `body` while no other importer is driving the page (they navigate it).
    func withExclusiveAccess<T>(_ body: () async throws -> T) async throws -> T {
        if isBusy {
            await withCheckedContinuation { busyWaiters.append($0) }
        }
        isBusy = true
        defer {
            if busyWaiters.isEmpty {
                isBusy = false
            } else {
                busyWaiters.removeFirst().resume()
            }
        }
        return try await body()
    }

    /// Opens a path in the web app: client-side if a link to it is on the page, otherwise by loading it.
    func navigate(toPath path: String) async {
        let trimmed = { (p: String) in p.trimmingCharacters(in: CharacterSet(charactersIn: "/")) }
        if let current = webView.url?.path, trimmed(current) == trimmed(path) {
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
        await webView.configuration.websiteDataStore.removeData(
            ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast
        )
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

/// While embedded invisibly, the web view must not swallow clicks meant for the chat pane.
private final class InvisibleWhenTransparentWebView: WKWebView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        alphaValue == 0 ? nil : super.hitTest(point)
    }
}
