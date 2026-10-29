import AppKit

/// Round avatar: the profile picture if available, otherwise initials on a gray gradient
/// (like Contacts / Messages).
final class AvatarView: NSView {
    private let gradient = CAGradientLayer()
    private let imageLayer = CALayer()
    private let initialsLabel = NSTextField(labelWithString: "")
    private var currentURL: String?
    private var currentName: String?
    /// The picture shown, and the pixel size it was drawn at for the layer.
    private var image: NSImage?
    private var drawnPixels = 0
    /// Pictures drawn at the size they're shown, by size and URL. Setting an NSImage as the
    /// layer's contents redrew the full-size picture on the main thread for every new layer, which
    /// made busy lists (the chat list and the Activity window during the first sync) slow.
    private static let drawn: NSCache<NSString, CGImage> = {
        let cache = NSCache<NSString, CGImage>()
        cache.countLimit = 1000
        return cache
    }()

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
        if image != nil, pixels != drawnPixels { applyImage(animated: false) }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsLayout = true
    }

    /// The picture's size in pixels: the view's, on its screen.
    private var pixels: Int {
        Int((max(bounds.width, bounds.height) * (window?.backingScaleFactor ?? 2)).rounded(.up))
    }

    func configure(name: String, url: String?) {
        initialsLabel.stringValue = RoundAvatar.initials(of: name)
        guard url != currentURL else { return }
        // The same person with a new link (Facebook's change on every sync, and the web app's
        // differ from the sync's): their picture stays until the new one is loaded, instead of
        // blinking to the initials.
        let keepsPicture = name == currentName && image != nil && url != nil
        currentName = name
        currentURL = url
        guard let url, let parsed = URL(string: url) else {
            clear()
            return
        }
        if let stored = ImageCache.shared.stored(parsed) {
            // In memory or on disk (e.g. a reused cell): swap in place with no fade.
            show(stored, animated: false)
            return
        }
        if !keepsPicture { clear() }
        Task { [weak self] in
            let image = await ImageCache.shared.image(for: parsed)
            guard let self, self.currentURL == url, let image else { return }
            // Loaded asynchronously: fade it in (not over the person's previous picture).
            self.show(image, animated: !keepsPicture)
        }
    }

    /// No picture: the initials. No fade: this runs on cell reuse, where the old picture should
    /// vanish at once.
    private func clear() {
        image = nil
        drawnPixels = 0
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.contents = nil
        CATransaction.commit()
        initialsLabel.isHidden = false
    }

    private func show(_ image: NSImage, animated: Bool) {
        self.image = image
        initialsLabel.isHidden = true
        applyImage(animated: animated)
    }

    /// Puts the picture in the layer, drawn at the view's size (again when that changes).
    private func applyImage(animated: Bool) {
        let pixels = pixels
        // Not laid out yet: layout() draws it.
        guard let image, let currentURL, pixels > 0 else { return }
        drawnPixels = pixels
        // Facebook's links change on every sync; ImageCache's key doesn't.
        let key = "\(pixels)|\(URL(string: currentURL).map(ImageCache.key(for:)) ?? currentURL)" as NSString
        let contents: CGImage
        if let drawn = Self.drawn.object(forKey: key) {
            contents = drawn
        } else {
            guard let drawn = Self.draw(image, pixels: pixels) else { return }
            Self.drawn.setObject(drawn, forKey: key)
            contents = drawn
        }
        if animated {
            imageLayer.contents = contents
        } else {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            imageLayer.contents = contents
            CATransaction.commit()
        }
    }

    /// The picture filling a square of the given size, like `.resizeAspectFill`.
    private static func draw(_ image: NSImage, pixels: Int) -> CGImage? {
        guard let source = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        let width = CGFloat(source.width), height = CGFloat(source.height)
        let scale = CGFloat(pixels) / min(width, height)
        let size = CGSize(width: width * scale, height: height * scale)
        context.interpolationQuality = .high
        context.draw(source, in: CGRect(x: (CGFloat(pixels) - size.width) / 2, y: (CGFloat(pixels) - size.height) / 2,
                                        width: size.width, height: size.height))
        return context.makeImage()
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
