import AppKit

// The parts around a message's bubble: the quote it replies to, the line from the quote to
// it, and its tapbacks.

/// The replied-to message above a reply, like Messages: an outlined bubble with gray text.
final class ReplyQuoteView: NSView {
    private let textLabel = NSTextField(wrappingLabelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = BubbleMetrics.cornerRadius
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1
        textLabel.font = .systemFont(ofSize: 13)
        textLabel.textColor = .secondaryLabelColor
        textLabel.maximumNumberOfLines = 3
        textLabel.lineBreakMode = .byWordWrapping
        textLabel.cell?.truncatesLastVisibleLine = true
        textLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(textLabel)
        let insets = BubbleMetrics.textInsets
        NSLayoutConstraint.activate([
            textLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: insets.left),
            textLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -insets.right),
            textLabel.topAnchor.constraint(equalTo: topAnchor, constant: insets.top),
            textLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -insets.bottom),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(text: String, maxWidth: CGFloat) {
        textLabel.stringValue = text
        textLabel.preferredMaxLayoutWidth = maxWidth - BubbleMetrics.textInsets.left - BubbleMetrics.textInsets.right
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.borderColor = NSColor.tertiaryLabelColor.cgColor
    }
}

/// The thread line from a reply's quote down to the reply, ending in a curve towards it.
final class ReplyConnectorView: NSView {
    private let shape = CAShapeLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        shape.fillColor = nil
        shape.lineWidth = 2
        shape.lineCap = .round
        layer?.addSublayer(shape)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        shape.strokeColor = NSColor.quaternaryLabelColor.cgColor
    }

    /// `quote` and `target` (the reply's bubble) are in this view's coordinates (y up).
    /// The line runs down the quote's outer side and curves inward at the target's middle.
    func update(quote: NSRect, target: NSRect, onLeft: Bool) {
        let radius: CGFloat = 10
        let direction: CGFloat = onLeft ? 1 : -1
        let x = onLeft ? quote.minX + 12 : quote.maxX - 12
        let endY = target.midY
        let endX = onLeft ? min(target.minX - 4, x + 44) : max(target.maxX + 4, x - 44)
        let path = CGMutablePath()
        path.move(to: CGPoint(x: x, y: quote.minY - 3))
        if quote.minY - 3 - endY > radius {
            path.addLine(to: CGPoint(x: x, y: endY + radius))
            path.addQuadCurve(to: CGPoint(x: x + direction * radius, y: endY), control: CGPoint(x: x, y: endY))
            if (endX - x) * direction > radius {
                path.addLine(to: CGPoint(x: endX, y: endY))
            }
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shape.frame = bounds
        shape.path = path
        CATransaction.commit()
    }
}

/// Tapback-style bubble with reaction emojis.
final class ReactionsBadge: NSView {
    /// Clicking shows who reacted.
    var onClick: (() -> Void)?
    private let label = NSTextField(labelWithString: "")
    private let background = BubbleView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        toolTip = "Show Reactions"
        background.layer?.cornerRadius = 12
        background.layer?.borderWidth = 2
        for view in [background, label] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        label.font = .systemFont(ofSize: 13)
        NSLayoutConstraint.activate([
            background.leadingAnchor.constraint(equalTo: leadingAnchor),
            background.trailingAnchor.constraint(equalTo: trailingAnchor),
            background.topAnchor.constraint(equalTo: topAnchor),
            background.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(equalToConstant: 24),
            widthAnchor.constraint(greaterThanOrEqualToConstant: 24),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 5),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -5),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? {
        frame.contains(point) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) {
            onClick?()
        }
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func accessibilityLabel() -> String? { "Reactions: \(label.stringValue)" }

    override func accessibilityPerformPress() -> Bool {
        onClick?()
        return true
    }

    /// Up to three different emoji, and the count when more than one person reacted.
    func configure(emojis: [String], highlighted: Bool) {
        var unique: [String] = []
        for emoji in emojis where !unique.contains(emoji) {
            unique.append(emoji)
        }
        let countSuffix = emojis.count > 1 ? " \(emojis.count)" : ""
        label.stringValue = unique.prefix(3).joined() + countSuffix
        background.color = highlighted ? BubbleColors.outgoing : BubbleColors.incoming
        background.layer?.borderColor = NSColor.windowBackgroundColor.cgColor
        label.textColor = highlighted ? .white : .labelColor
    }
}
