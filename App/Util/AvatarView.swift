import AppKit

/// Round avatar: the profile picture if available, otherwise initials on a gray gradient
/// (like Contacts / Messages).
final class AvatarView: NSView {
    private let gradient = CAGradientLayer()
    private let imageLayer = CALayer()
    private let initialsLabel = NSTextField(labelWithString: "")
    private var currentURL: String?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true

        gradient.colors = [
            NSColor(calibratedWhite: 0.66, alpha: 1).cgColor,
            NSColor(calibratedWhite: 0.52, alpha: 1).cgColor,
        ]
        layer?.addSublayer(gradient)

        imageLayer.contentsGravity = .resizeAspectFill
        layer?.addSublayer(imageLayer)

        initialsLabel.textColor = .white
        initialsLabel.alignment = .center
        initialsLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(initialsLabel)
        NSLayoutConstraint.activate([
            initialsLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            initialsLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        layer?.cornerRadius = bounds.width / 2
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        gradient.frame = bounds
        imageLayer.frame = bounds
        CATransaction.commit()
        initialsLabel.font = .systemFont(ofSize: max(9, bounds.height * 0.4), weight: .medium)
    }

    func configure(name: String, url: String?) {
        initialsLabel.stringValue = RoundAvatar.initials(of: name)
        guard url != currentURL else { return }
        currentURL = url
        imageLayer.contents = nil
        initialsLabel.isHidden = false
        guard let url, let parsed = URL(string: url) else { return }
        if let cached = ImageCache.shared.cached(parsed) {
            show(cached)
            return
        }
        Task { [weak self] in
            let image = await ImageCache.shared.image(for: parsed)
            guard let self, self.currentURL == url, let image else { return }
            self.show(image)
        }
    }

    private func show(_ image: NSImage) {
        imageLayer.contents = image.layerContents(forContentsScale: window?.backingScaleFactor ?? 2)
        initialsLabel.isHidden = true
    }
}

/// A conversation's avatar. 1:1 chats and groups with a photo show it; other groups show up
/// to three members' avatars clustered in a gray circle, like Messages.
final class ConversationAvatarView: NSView {
    private let single = AvatarView()
    private let members = (0..<3).map { _ in AvatarView() }
    private var memberCount = 0

    private static let background = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(calibratedWhite: 0.32, alpha: 1)
            : NSColor(calibratedWhite: 0.86, alpha: 1)
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        for view in [single] + members {
            addSubview(view)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(_ conversation: Conversation, selfID: String?) {
        let groupPhoto = conversation.avatarURL.map { !$0.isEmpty } ?? false
        guard conversation.isGroup, !groupPhoto else {
            memberCount = 0
            single.configure(name: conversation.name, url: conversation.avatarURL)
            needsLayout = true
            needsDisplay = true
            return
        }
        // The latest sender first, then members with a photo.
        let others = conversation.participants.filter { $0.id != selfID }
        let picked = others.sorted { a, b in
            if (a.id == conversation.snippetSenderID) != (b.id == conversation.snippetSenderID) {
                return a.id == conversation.snippetSenderID
            }
            return (a.avatarURL?.isEmpty == false) && (b.avatarURL?.isEmpty != false)
        }.prefix(3)
        memberCount = picked.isEmpty ? 0 : max(2, picked.count)
        if picked.isEmpty {
            single.configure(name: conversation.name, url: nil)
        }
        for (index, view) in members.enumerated() {
            if index < picked.count {
                let member = picked[picked.index(picked.startIndex, offsetBy: index)]
                view.configure(name: member.name, url: member.avatarURL)
            } else if index < memberCount {
                // Only one other member known: pair it with a placeholder.
                view.configure(name: conversation.name, url: nil)
            }
        }
        needsLayout = true
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        let d = min(bounds.width, bounds.height)
        let center = NSPoint(x: bounds.midX, y: bounds.midY)
        single.isHidden = memberCount > 0
        single.frame = bounds
        // Member circles sit on a ring around the center, kept inside the outer circle.
        let size: CGFloat
        let distance: CGFloat
        let angles: [CGFloat]
        switch memberCount {
        case 2:
            size = d * 0.56
            distance = d * 0.2
            angles = [135, -45]
        default:
            size = d * 0.52
            distance = d * 0.24
            angles = [90, 210, 330]
        }
        for (index, view) in members.enumerated() {
            view.isHidden = index >= memberCount
            guard index < memberCount else { continue }
            let angle = angles[index] * .pi / 180
            let c = NSPoint(x: center.x + cos(angle) * distance, y: center.y + sin(angle) * distance)
            view.frame = NSRect(x: c.x - size / 2, y: c.y - size / 2, width: size, height: size)
            // A ring in the background color separates overlapping circles.
            view.layer?.borderWidth = 1.5
        }
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.cornerRadius = min(bounds.width, bounds.height) / 2
        let color = Self.background.cgColor(for: effectiveAppearance)
        layer?.backgroundColor = memberCount > 0 ? color : nil
        for view in members {
            view.layer?.borderColor = color
        }
    }
}

private extension NSColor {
    func cgColor(for appearance: NSAppearance) -> CGColor {
        var result = cgColor
        appearance.performAsCurrentDrawingAppearance { result = self.cgColor }
        return result
    }
}
