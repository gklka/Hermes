import AppKit

/// The first row of the chat list while the encrypted chats aren't restored with the PIN (e.g.
/// after a new login): until then, their messages are missing.
final class RestoreBannerView: NSView {
    /// The row's height (the texts don't wrap).
    static let height: CGFloat = 96

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let box = NSBox()
        box.boxType = .custom
        box.borderWidth = 0
        box.cornerRadius = 12
        box.fillColor = .quaternarySystemFill
        box.contentViewMargins = .zero

        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: "lock.fill", accessibilityDescription: nil)
        icon.symbolConfiguration = .init(pointSize: 13, weight: .medium)
        icon.contentTintColor = .secondaryLabelColor

        let title = NSTextField(labelWithString: "Restore Your Encrypted Chats")
        title.font = .systemFont(ofSize: 12, weight: .semibold)
        let detail = NSTextField(labelWithString: "Enter your PIN to see their messages.")
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        let button = NSButton(title: "Restore…", target: nil, action: #selector(AppDelegate.showWebSync(_:)))
        button.bezelStyle = .push
        button.controlSize = .small

        let content = NSView()
        for view in [icon, title, detail, button] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        for label in [title, detail] {
            label.lineBreakMode = .byTruncatingTail
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        box.contentView = content
        box.translatesAutoresizingMaskIntoConstraints = false
        addSubview(box)
        NSLayoutConstraint.activate([
            box.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            box.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            box.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            box.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),

            icon.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            icon.centerYAnchor.constraint(equalTo: title.centerYAnchor),
            title.topAnchor.constraint(equalTo: content.topAnchor, constant: 10),
            title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            title.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -12),
            detail.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 2),
            detail.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            detail.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -12),
            button.topAnchor.constraint(equalTo: detail.bottomAnchor, constant: 8),
            button.leadingAnchor.constraint(equalTo: title.leadingAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}
