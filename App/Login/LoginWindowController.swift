import AppKit
import WebKit

/// Shows facebook.com's own login page in a web view. Once the session cookies
/// appear, they're handed to the Go core, which takes over from there.
final class LoginWindowController: NSWindowController, WKNavigationDelegate {
    private let onCookies: ([String: String]) -> Void
    private let webView: WKWebView
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
