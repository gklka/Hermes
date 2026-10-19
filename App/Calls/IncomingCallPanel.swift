import AppKit

/// An incoming call, in the top-right corner of the screen like FaceTime's: the caller, and the
/// buttons of the web app's call dialog (red ones decline, green ones answer).
final class IncomingCallPanel: NSPanel {
    struct Button: Decodable {
        /// Its position among the dialog's buttons (marked in the page).
        let index: Int
        /// In the account's language.
        let label: String
        /// "decline", "accept" or "" (unknown).
        let tone: String
    }

    private let buttons: [Button]
    private let onButton: (Button) -> Void

    init(name: String, detail: String, conversation: Conversation?, imageURL: String?,
         buttons: [Button], onButton: @escaping (Button) -> Void) {
        self.buttons = buttons
        self.onButton = onButton
        let margin = Self.shadowMargin
        super.init(contentRect: NSRect(x: 0, y: 0, width: Self.size.width + 2 * margin, height: Self.size.height + 2 * margin),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        backgroundColor = .clear
        isOpaque = false
        // Like a notification banner: no window shadow (it outlines the window with a dark
        // line), a soft one of its own around the glass instead.
        hasShadow = false
        isReleasedWhenClosed = false

        let root = NSView()
        let shadow = PanelShadow()
        let glass = NSGlassEffectView()
        glass.cornerRadius = Self.cornerRadius
        let background = NSView()
        glass.contentView = background
        for view in [shadow, glass] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: margin),
                view.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -margin),
                view.topAnchor.constraint(equalTo: root.topAnchor, constant: margin),
                view.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -margin),
            ])
        }

        let avatar: NSView
        if let conversation {
            let view = ConversationAvatarView()
            view.configure(conversation, selfID: ChatStore.shared.account?.id)
            avatar = view
        } else {
            let view = AvatarView()
            view.configure(name: name, url: imageURL)
            avatar = view
        }
        avatar.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            avatar.widthAnchor.constraint(equalToConstant: 40),
            avatar.heightAnchor.constraint(equalToConstant: 40),
        ])

        // Like a notification's title and body.
        let nameLabel = NSTextField(labelWithString: name)
        nameLabel.font = .systemFont(ofSize: 13, weight: .bold)
        let detailLabel = NSTextField(labelWithString: detail)
        detailLabel.font = .systemFont(ofSize: 13)
        detailLabel.textColor = .labelColor
        detailLabel.isHidden = detail.isEmpty
        for label in [nameLabel, detailLabel] {
            label.lineBreakMode = .byTruncatingTail
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        let labels = NSStackView(views: [nameLabel, detailLabel])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 2

        let buttonViews = buttons.map(makeButton)
        let row = NSStackView(views: [avatar, labels] + buttonViews)
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        row.setCustomSpacing(12, after: avatar)
        row.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 14),
            row.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -14),
            row.centerYAnchor.constraint(equalTo: background.centerYAnchor),
        ])
        contentView = root
    }

    /// The banner itself (the window is larger by the room for its shadow).
    private static let size = NSSize(width: 360, height: 72)
    private static let shadowMargin: CGFloat = 24
    static let cornerRadius: CGFloat = 24

    /// Top right of the screen with the menu bar, where notification banners show.
    func present() {
        if let screen = NSScreen.screens.first {
            let visible = screen.visibleFrame
            let margin = Self.shadowMargin
            setFrameOrigin(NSPoint(x: visible.maxX - Self.size.width - 12 - margin,
                                   y: visible.maxY - Self.size.height - 12 - margin))
        }
        orderFrontRegardless()
    }

    override var canBecomeKey: Bool { true }

    /// A round button: red declines, green answers; the dialog's other button (closing it, in the
    /// account's language) is a gray ✕.
    private func makeButton(_ button: Button) -> NSView {
        let accepts = buttons.filter { $0.tone == "accept" }
        let symbol: String
        let color: NSColor
        let symbolColor: NSColor
        switch button.tone {
        case "decline":
            (symbol, color, symbolColor) = ("phone.down.fill", .systemRed, .white)
        case "accept":
            // A second answer button is answering with video.
            let video = accepts.count > 1 && accepts.last?.index == button.index
            (symbol, color, symbolColor) = (video ? "video.fill" : "phone.fill", .systemGreen, .white)
        default:
            // Darker than the glass in light mode, lighter in dark mode.
            let gray = NSColor(name: nil) { appearance in
                appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                    ? NSColor.white.withAlphaComponent(0.18) : NSColor.black.withAlphaComponent(0.12)
            }
            (symbol, color, symbolColor) = ("xmark", gray, .labelColor)
        }
        let view = RoundCallButton(symbol: symbol, label: button.label, color: color, symbolColor: symbolColor)
        view.target = self
        view.action = #selector(pressed(_:))
        view.tag = button.index
        view.toolTip = button.label
        view.translatesAutoresizingMaskIntoConstraints = false
        let size: CGFloat = 36
        NSLayoutConstraint.activate([
            view.widthAnchor.constraint(equalToConstant: size),
            view.heightAnchor.constraint(equalToConstant: size),
        ])
        return view
    }

    @objc private func pressed(_ sender: NSButton) {
        guard let button = buttons.first(where: { $0.index == sender.tag }) else { return }
        onButton(button)
    }
}

/// The banner's soft shadow, under the glass, like a notification's. Clicks go through.
private final class PanelShadow: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.18
        layer?.shadowRadius = 14
        layer?.shadowOffset = CGSize(width: 0, height: -4)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let radius = IncomingCallPanel.cornerRadius
        layer?.shadowPath = CGPath(roundedRect: bounds, cornerWidth: radius, cornerHeight: radius, transform: nil)
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// A filled circle with a symbol, darker while pressed.
private final class RoundCallButton: NSButton {
    private let fill: NSColor
    private let symbolImage: NSImage?

    init(symbol: String, label: String, color: NSColor, symbolColor: NSColor) {
        fill = color
        let configuration = NSImage.SymbolConfiguration(pointSize: 15, weight: .semibold)
            .applying(.init(paletteColors: [symbolColor]))
        symbolImage = NSImage(systemSymbolName: symbol, accessibilityDescription: label)?.withSymbolConfiguration(configuration)
        super.init(frame: .zero)
        title = ""
        isBordered = false
        setAccessibilityLabel(label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let color = isHighlighted ? fill.blended(withFraction: 0.25, of: .black) ?? fill : fill
        color.setFill()
        NSBezierPath(ovalIn: bounds).fill()
        guard let symbolImage else { return }
        let size = symbolImage.size
        let rect = NSRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2, width: size.width, height: size.height)
        symbolImage.draw(in: rect)
    }
}
