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
        initialsLabel.stringValue = Self.initials(of: name)
        guard url != currentURL else { return }
        currentURL = url
        imageLayer.contents = nil
        initialsLabel.isHidden = false
        guard let url, let parsed = URL(string: url) else { return }
        if let cached = ImageCache.shared.cached(parsed.absoluteString) {
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

    static func initials(of name: String) -> String {
        let words = name.split(separator: " ").filter { $0.first?.isLetter == true }
        let letters = words.prefix(2).compactMap(\.first)
        return letters.isEmpty ? "?" : String(letters).uppercased()
    }
}
