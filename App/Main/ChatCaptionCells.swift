import AppKit

/// Small gray text between messages: times, system notices, and the status under your last
/// message ("Sending…", "Sent", "Not Delivered").
final class CaptionCellView: NSTableCellView {
    enum Placement {
        case center
        /// On the outgoing side, under your messages.
        case trailing
    }

    /// Makes the text clickable (e.g. "Not Delivered").
    var onClick: (() -> Void)?
    private let label = NSTextField(wrappingLabelWithString: "")
    private var alignmentConstraints: [NSLayoutConstraint] = []

    init() {
        super.init(frame: .zero)
        label.font = .systemFont(ofSize: 11, weight: .medium)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard onClick != nil else { return super.hitTest(point) }
        return label.frame.contains(convert(point, from: superview)) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        if onClick == nil { super.mouseDown(with: event) }
    }

    override func mouseUp(with event: NSEvent) {
        guard let onClick else { return super.mouseUp(with: event) }
        if label.frame.contains(convert(event.locationInWindow, from: nil)) {
            onClick()
        }
    }

    func configure(_ text: String, placement: Placement = .center, color: NSColor = .secondaryLabelColor, maxWidth: CGFloat) {
        label.stringValue = text
        label.textColor = color
        label.preferredMaxLayoutWidth = maxWidth
        NSLayoutConstraint.deactivate(alignmentConstraints)
        switch placement {
        case .center:
            label.alignment = .center
            alignmentConstraints = [
                label.centerXAnchor.constraint(equalTo: centerXAnchor),
                label.widthAnchor.constraint(lessThanOrEqualToConstant: maxWidth),
            ]
        case .trailing:
            label.alignment = .right
            alignmentConstraints = [label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -BubbleMetrics.captionSideInset)]
        }
        NSLayoutConstraint.activate(alignmentConstraints)
    }
}

/// Shown in encrypted chats whose history hasn't been restored in Messenger web yet.
final class RestoreCellView: NSTableCellView {
    private let label = NSTextField(wrappingLabelWithString: "🔒 End-to-end encrypted. Restore your encrypted chats with your PIN to see earlier messages.")
    private let button = NSButton(title: "Restore Encrypted Chats…", target: nil, action: #selector(AppDelegate.showWebSync(_:)))
    private var widthConstraint: NSLayoutConstraint?

    init() {
        super.init(frame: .zero)
        label.font = .systemFont(ofSize: 11, weight: .medium)
        label.textColor = .secondaryLabelColor
        label.alignment = .center
        button.bezelStyle = .push
        button.controlSize = .regular
        for view in [label, button] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        let width = label.widthAnchor.constraint(lessThanOrEqualToConstant: 400)
        widthConstraint = width
        NSLayoutConstraint.activate([
            width,
            label.topAnchor.constraint(equalTo: topAnchor, constant: 16),
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            button.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 8),
            button.centerXAnchor.constraint(equalTo: centerXAnchor),
            button.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(maxWidth: CGFloat) {
        label.preferredMaxLayoutWidth = maxWidth
        widthConstraint?.constant = maxWidth
    }
}

/// At the top of an encrypted chat while its history is loaded from Messenger web: a spinner.
final class LoadingCellView: NSTableCellView {
    private let spinner = NSProgressIndicator()

    init() {
        super.init(frame: .zero)
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isIndeterminate = true
        spinner.setAccessibilityLabel("Loading earlier messages")
        spinner.toolTip = "Loading earlier messages from Messenger web"
        spinner.translatesAutoresizingMaskIntoConstraints = false
        addSubview(spinner)
        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: centerXAnchor),
            spinner.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            spinner.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // Animations stop when a cell leaves the window; it spins again when it's back.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            spinner.startAnimation(nil)
        } else {
            spinner.stopAnimation(nil)
        }
    }
}

/// Under the last message someone has seen: their small pictures on the right, like Messenger's
/// read heads ("Seen by …" on hover).
final class ReadersCellView: NSTableCellView {
    private let stack = NSStackView()
    private static let maxShown = 8
    private static let pictureSize: CGFloat = 14
    /// The pictures shown, with whose they are (for animating a move to another message).
    private(set) var avatars: [(reader: Participant, view: AvatarView)] = []

    init() {
        super.init(frame: .zero)
        stack.orientation = .horizontal
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
            stack.heightAnchor.constraint(equalToConstant: Self.pictureSize),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// `hiding`: people whose picture is still flying here (shown once it lands).
    func configure(_ readers: [Participant], hiding: Set<String> = []) {
        for view in stack.arrangedSubviews { view.removeFromSuperview() }
        avatars = []
        for reader in readers.prefix(Self.maxShown) {
            let avatar = AvatarView()
            avatar.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                avatar.widthAnchor.constraint(equalToConstant: Self.pictureSize),
                avatar.heightAnchor.constraint(equalToConstant: Self.pictureSize),
            ])
            avatar.configure(name: reader.name, url: reader.avatarURL)
            avatar.toolTip = reader.name
            avatar.alphaValue = hiding.contains(reader.id) ? 0 : 1
            stack.addArrangedSubview(avatar)
            avatars.append((reader, avatar))
        }
        if readers.count > Self.maxShown {
            let more = NSTextField(labelWithString: "+\(readers.count - Self.maxShown)")
            more.font = .systemFont(ofSize: 10)
            more.textColor = .secondaryLabelColor
            stack.addArrangedSubview(more)
        }
        toolTip = "Seen by " + readers.map(\.name).filter { !$0.isEmpty }.joined(separator: ", ")
    }
}
