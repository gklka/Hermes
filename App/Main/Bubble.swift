import AppKit

enum BubbleColors {
    static let outgoing = NSColor.systemBlue
    static let incoming = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.23, green: 0.23, blue: 0.24, alpha: 1)
            : NSColor(srgbRed: 0.91, green: 0.91, blue: 0.92, alpha: 1)
    }

    /// A chat's custom Messenger theme colors ("#rrggbb"); empty for the default theme.
    static func theme(_ hexColors: [String]?) -> [NSColor] {
        (hexColors ?? []).compactMap { hex in
            guard hex.count == 7, hex.hasPrefix("#"), let value = UInt32(hex.dropFirst(), radix: 16) else { return nil }
            return NSColor(
                srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
                green: CGFloat((value >> 8) & 0xFF) / 255,
                blue: CGFloat(value & 0xFF) / 255,
                alpha: 1
            )
        }
    }
}

/// The chat's measurements, shared by its bubbles and rows.
enum BubbleMetrics {
    static let cornerRadius: CGFloat = 17
    /// Around a bubble's text.
    static let textInsets = NSEdgeInsets(top: 7, left: 12, bottom: 7, right: 12)
    /// From the chat's sides to the bubbles.
    static let sideInset: CGFloat = 14
    /// Incoming bubbles in group chats, which leave room for the sender's picture.
    static let avatarSideInset: CGFloat = 44
    /// From the chat's sides to captions under bubbles ("Sent", "Edited").
    static let captionSideInset: CGFloat = 18
    static let font = NSFont.systemFont(ofSize: 14)
}

/// An image view that's never a drop target (NSImageView registers for image drags and then
/// refuses them when not editable), so files dropped on a photo reach the chat's drop target.
final class DisplayImageView: NSImageView {
    override func registerForDraggedTypes(_ newTypes: [NSPasteboard.PasteboardType]) {}
}

/// A rounded rectangle whose color resolves with the current appearance.
final class BubbleView: NSView {
    var color: NSColor = BubbleColors.incoming {
        didSet { needsDisplay = true }
    }

    /// Gradient themes: like Messenger, the gradient spans the visible chat, so a bubble's color
    /// depends on where it is on screen. See `alignGradient(to:)`.
    var gradientColors: [NSColor]? {
        didSet { needsDisplay = true }
    }

    private var gradientLayer: CAGradientLayer?
    private var gradientArea: NSRect = .zero

    /// Shown over the whole bubble when set.
    var cursor: NSCursor? {
        didSet { window?.invalidateCursorRects(for: self) }
    }

    override func resetCursorRects() {
        if let cursor { addCursorRect(bounds, cursor: cursor) }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = BubbleMetrics.cornerRadius
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// The corner radius for a bubble this tall: one-line bubbles are capsules (a radius over
    /// half the height would distort the continuous corners).
    static func cornerRadius(forHeight height: CGFloat) -> CGFloat {
        min(BubbleMetrics.cornerRadius, height / 2)
    }

    override func layout() {
        super.layout()
        layer?.cornerRadius = Self.cornerRadius(forHeight: bounds.height)
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        guard let gradientColors, gradientColors.count > 1 else {
            gradientLayer?.isHidden = true
            layer?.backgroundColor = color.cgColor
            return
        }
        let gradient = gradientLayer ?? CAGradientLayer()
        if gradientLayer == nil {
            // The view isn't flipped, so y = 1 is the top.
            gradient.startPoint = CGPoint(x: 0.5, y: 1)
            gradient.endPoint = CGPoint(x: 0.5, y: 0)
            layer?.insertSublayer(gradient, at: 0)
            gradientLayer = gradient
        }
        gradient.colors = gradientColors.map(\.cgColor)
        gradient.isHidden = false
        layer?.backgroundColor = nil
        alignGradient(to: gradientArea)
    }

    /// Stretches the gradient over `area` (the visible chat, in this view's coordinates).
    func alignGradient(to area: NSRect) {
        gradientArea = area
        guard let gradientLayer, !gradientLayer.isHidden else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        gradientLayer.frame = area
        CATransaction.commit()
    }
}
