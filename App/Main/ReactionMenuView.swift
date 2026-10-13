import AppKit

/// Reaction choices shown in a message's context menu, like Messages' tapback rows.
enum ReactionChoices {
    /// Messenger's standard reactions.
    static let standard = ["❤️", "😆", "😮", "😢", "😠", "👍"]
    private static let fallbackExtras = ["😂", "😍", "🙏", "🔥", "🎉"]
    private static let recentsKey = "RecentReactions"

    /// The second row: recently used reactions outside the standard ones, topped up with extras.
    static var recents: [String] {
        let saved = (UserDefaults.standard.array(forKey: recentsKey) as? [String]) ?? []
        var result = saved.filter { !standard.contains($0) }
        for emoji in fallbackExtras where result.count < 5 && !result.contains(emoji) {
            result.append(emoji)
        }
        return Array(result.prefix(5))
    }

    static func noteUsed(_ emoji: String) {
        guard !standard.contains(emoji) else { return }
        var saved = (UserDefaults.standard.array(forKey: recentsKey) as? [String]) ?? []
        saved.removeAll { $0 == emoji }
        saved.insert(emoji, at: 0)
        UserDefaults.standard.set(Array(saved.prefix(5)), forKey: recentsKey)
    }
}

/// The emoji grid at the top of a message's context menu. Picking closes the menu.
final class ReactionMenuView: NSView {
    private let onPick: (String) -> Void
    private let onMore: () -> Void

    private static let cell: CGFloat = 38
    private static let gap: CGFloat = 4
    private static let inset = NSEdgeInsets(top: 6, left: 14, bottom: 4, right: 14)

    init(current: String?, onPick: @escaping (String) -> Void, onMore: @escaping () -> Void) {
        self.onPick = onPick
        self.onMore = onMore
        let rows: [[String?]] = [ReactionChoices.standard, ReactionChoices.recents + [nil]]
        let columns = CGFloat(rows.map(\.count).max() ?? 6)
        let width = Self.inset.left + Self.inset.right + columns * Self.cell + (columns - 1) * Self.gap
        let height = Self.inset.top + Self.inset.bottom + CGFloat(rows.count) * Self.cell + CGFloat(rows.count - 1) * Self.gap
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: height))

        for (rowIndex, row) in rows.enumerated() {
            for (column, emoji) in row.enumerated() {
                let x = Self.inset.left + CGFloat(column) * (Self.cell + Self.gap)
                let y = height - Self.inset.top - CGFloat(rowIndex + 1) * Self.cell - CGFloat(rowIndex) * Self.gap
                let button = EmojiButton(emoji: emoji, isSelected: emoji != nil && emoji == current)
                button.frame = NSRect(x: x, y: y, width: Self.cell, height: Self.cell)
                button.onClick = { [weak self] in self?.picked(emoji) }
                addSubview(button)
            }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func picked(_ emoji: String?) {
        enclosingMenuItem?.menu?.cancelTracking()
        // Act after the menu has closed.
        DispatchQueue.main.async { [onPick, onMore] in
            if let emoji {
                ReactionChoices.noteUsed(emoji)
                onPick(emoji)
            } else {
                onMore()
            }
        }
    }
}

/// One emoji (or the "more" button when `emoji` is nil) with a hover/selected highlight.
private final class EmojiButton: NSView {
    var onClick: (() -> Void)?
    private let isSelected: Bool
    private var isHovered = false { didSet { needsDisplay = true } }
    private let label = NSTextField(labelWithString: "")

    init(emoji: String?, isSelected: Bool) {
        self.isSelected = isSelected
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 9
        layer?.cornerCurve = .continuous
        let content: NSView
        if let emoji {
            label.stringValue = emoji
            label.font = .systemFont(ofSize: 24)
            label.alignment = .center
            content = label
        } else {
            let icon = NSImageView(image: NSImage(systemSymbolName: "face.smiling", accessibilityDescription: "More Emoji") ?? NSImage())
            icon.symbolConfiguration = .init(pointSize: 22, weight: .regular)
            icon.contentTintColor = .labelColor
            toolTip = "More Emoji"
            content = icon
        }
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            content.centerXAnchor.constraint(equalTo: centerXAnchor),
            content.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }

    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) {
            onClick?()
        }
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        let color: NSColor? = isSelected
            ? NSColor.controlAccentColor.withAlphaComponent(0.3)
            : (isHovered ? NSColor.labelColor.withAlphaComponent(0.1) : nil)
        layer?.backgroundColor = color?.cgColor
    }
}

/// A small popover for reacting with any emoji: type one or pick it from the emoji palette.
final class EmojiInputViewController: NSViewController, NSTextFieldDelegate {
    var onPick: ((String) -> Void)?
    private let field = NSTextField()

    override func loadView() {
        field.placeholderString = "Emoji"
        field.font = .systemFont(ofSize: 20)
        field.alignment = .center
        field.delegate = self
        field.focusRingType = .none
        field.translatesAutoresizingMaskIntoConstraints = false
        let container = NSView()
        container.addSubview(field)
        NSLayoutConstraint.activate([
            field.widthAnchor.constraint(equalToConstant: 120),
            field.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 10),
            field.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -10),
            field.topAnchor.constraint(equalTo: container.topAnchor, constant: 10),
            field.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -10),
        ])
        view = container
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(field)
        NSApp.orderFrontCharacterPalette(nil)
    }

    func controlTextDidChange(_ obj: Notification) {
        // The first emoji typed or picked wins (skipping digits, # and *, which count as emoji).
        let emoji = field.stringValue.first { character in
            character.unicodeScalars.contains { $0.properties.isEmojiPresentation }
                || (character.unicodeScalars.first?.properties.isEmoji == true && character.unicodeScalars.count > 1
                    && !character.isASCII)
        }
        guard let emoji else { return }
        let value = String(emoji)
        ReactionChoices.noteUsed(value)
        onPick?(value)
    }
}
