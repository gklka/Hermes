import AppKit
import WebKit

/// A call: Messenger web's call page (the popup the web app opens) in its own window. Until the
/// page arrives, it says the call is starting.
final class CallWindowController: NSWindowController, NSWindowDelegate {
    private(set) var webView: WKWebView?
    var onClose: (() -> Void)?

    private let spinner = NSProgressIndicator()
    private let statusLabel = NSTextField(labelWithString: "Starting call…")
    private var titleObservation: NSKeyValueObservation?

    init(title: String) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.minSize = NSSize(width: 420, height: 320)
        window.isReleasedWhenClosed = false
        window.backgroundColor = .black
        window.appearance = NSAppearance(named: .darkAqua)
        super.init(window: window)
        window.delegate = self

        let content = NSView()
        spinner.style = .spinning
        spinner.controlSize = .regular
        spinner.startAnimation(nil)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.alignment = .center
        let stack = NSStackView(views: [spinner, statusLabel])
        stack.orientation = .vertical
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            stack.widthAnchor.constraint(lessThanOrEqualTo: content.widthAnchor, constant: -40),
        ])
        window.contentView = content
        window.center()
        window.setFrameAutosaveName("CallWindow")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Shows the call page; the window takes its title once it has one.
    func attach(_ webView: WKWebView) {
        self.webView = webView
        guard let content = window?.contentView else { return }
        content.subviews.forEach { $0.removeFromSuperview() }
        webView.frame = content.bounds
        webView.autoresizingMask = [.width, .height]
        content.addSubview(webView)
        titleObservation = webView.observe(\.title) { [weak self] webView, _ in
            MainActor.assumeIsolated {
                if let title = webView.title, !title.isEmpty { self?.window?.title = title }
            }
        }
    }

    func fail(_ message: String) {
        spinner.stopAnimation(nil)
        spinner.isHidden = true
        statusLabel.stringValue = message
    }

    func windowWillClose(_ notification: Notification) {
        titleObservation = nil
        // Leaving the page hangs up.
        webView?.load(URLRequest(url: URL(string: "about:blank")!))
        onClose?()
    }
}
