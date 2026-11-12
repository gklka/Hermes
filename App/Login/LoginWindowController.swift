import AppKit
import WebKit

/// Shows facebook.com's own login page in a web view. Once the session cookies
/// appear, they're handed to the Go core, which takes over from there.
final class LoginWindowController: NSWindowController, WKNavigationDelegate, WKUIDelegate {
    private let onCookies: ([String: String]) -> Void
    private let webView: WKWebView
    /// The user agent the core uses (Facebook's pages get it).
    private var coreUserAgent: String?
    private let statusLabel = NSTextField(labelWithString: "")
    private var didSubmit = false

    private static let loginURL = URL(string: "https://www.facebook.com/login/")!

    init(onCookies: @escaping ([String: String]) -> Void) {
        self.onCookies = onCookies

        let config = WKWebViewConfiguration()
        // Start clean every time; the core keeps its own copy of the cookies.
        config.websiteDataStore = .nonPersistent()
        webView = WKWebView(frame: .zero, configuration: config)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Log in to Messenger"
        window.isReleasedWhenClosed = false
        super.init(window: window)

        webView.navigationDelegate = self
        webView.uiDelegate = self

        statusLabel.textColor = .secondaryLabelColor
        statusLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        statusLabel.alignment = .center
        statusLabel.lineBreakMode = .byTruncatingTail

        let container = NSView()
        for view in [webView, statusLabel] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(view)
        }
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: container.topAnchor),
            webView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            statusLabel.topAnchor.constraint(equalTo: webView.bottomAnchor, constant: 6),
            statusLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            statusLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            statusLabel.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -8),
        ])
        window.contentView = container

        Task {
            // Use the same user agent the core will use, so Meta sees one consistent "browser".
            if let userAgent = await ChatStore.shared.userAgent() {
                coreUserAgent = userAgent
                webView.customUserAgent = userAgent
            }
            webView.load(URLRequest(url: Self.loginURL))
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func showError(_ message: String) {
        didSubmit = false
        statusLabel.stringValue = "Login failed: \(message)"
        statusLabel.textColor = .systemRed
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard navigationAction.targetFrame?.isMainFrame != false, let url = navigationAction.request.url else { return .allow }
        let host = url.host?.lowercased() ?? ""
        let isGoogle = host == "google.com" || host.hasSuffix(".google.com")
        // Google turned the sign-in down after all: finish the check in a real browser.
        if isGoogle, url.path.contains("/signin/rejected") {
            showGoogleSignInAlert()
            return .cancel
        }
        // Facebook's "Verify with Google" check signs in to Google, which refuses web views
        // ("This browser or app may not be secure") and browsers that don't add up (a Chrome
        // user agent on WebKit): Google's pages get Safari's, Facebook's the core's again.
        let userAgent = isGoogle ? Self.safariUserAgent : coreUserAgent
        guard let userAgent, webView.customUserAgent != userAgent else { return .allow }
        webView.customUserAgent = userAgent
        // This request already has the old one: load it again with the new one.
        if isGoogle, navigationAction.request.httpMethod ?? "GET" == "GET" {
            webView.load(navigationAction.request)
            return .cancel
        }
        return .allow
    }

    /// The installed Safari's user agent: WebKit's own (this is WebKit), as Safari sends it.
    private static let safariUserAgent: String? = {
        let info = NSDictionary(contentsOfFile: "/Applications/Safari.app/Contents/Info.plist")
        let version = info?["CFBundleShortVersionString"] as? String ?? "26.0"
        return "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/\(version) Safari/605.1.15"
    }()

    // MARK: - WKUIDelegate

    /// Links and pop-ups for a new window (Google's sign-in can use one) open here instead.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        webView.load(navigationAction.request)
        return nil
    }

    private func showGoogleSignInAlert() {
        guard let window, window.attachedSheet == nil else { return }
        let alert = NSAlert()
        alert.messageText = "Finish this check in your browser"
        alert.informativeText = "Facebook wants you to confirm it's you with Google, but Google doesn't allow signing in inside apps. Log in on facebook.com in your browser and finish the check there, then try again here."
        alert.addButton(withTitle: "Open in Browser")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            if response == .alertFirstButtonReturn, let url = URL(string: "https://www.facebook.com/") {
                NSWorkspace.shared.open(url)
            }
            // Back to the start, for the next try.
            self?.webView.load(URLRequest(url: Self.loginURL))
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        checkCookies()
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        checkCookies()
    }

    private func checkCookies() {
        guard !didSubmit else { return }
        webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
            guard let self else { return }
            let facebookCookies = cookies.filter { $0.domain.hasSuffix("facebook.com") }
            var values: [String: String] = [:]
            for cookie in facebookCookies {
                values[cookie.name] = cookie.value
            }
            // `c_user` (user ID) and `xs` (session) only exist once fully logged in,
            // including after any 2FA / checkpoint pages.
            guard values["c_user"] != nil, values["xs"] != nil, !self.didSubmit else { return }
            self.didSubmit = true
            self.statusLabel.textColor = .secondaryLabelColor
            self.statusLabel.stringValue = "Logged in, connecting…"
            self.onCookies(values)
        }
    }
}
