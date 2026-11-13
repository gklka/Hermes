import AppKit

/// A person's or chat's picture as a round image, or their initials on gray where there's no
/// picture (for menus and the share sheet; the chat itself uses AvatarView).
enum RoundAvatar {
    /// The first letters of the name's first two words ("?" for none).
    nonisolated static func initials(of name: String) -> String {
        let words = name.split(separator: " ").filter { $0.first?.isLetter == true }
        let letters = words.prefix(2).compactMap(\.first)
        return letters.isEmpty ? "?" : String(letters).uppercased()
    }

    static func image(_ picture: NSImage?, name: String, size: CGFloat) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            NSBezierPath(ovalIn: rect).addClip()
            if let picture {
                picture.draw(in: rect)
                return true
            }
            NSColor(calibratedWhite: 0.6, alpha: 1).setFill()
            rect.fill()
            let initials = initials(of: name)
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: size * 0.4, weight: .medium), .foregroundColor: NSColor.white,
            ]
            let textSize = initials.size(withAttributes: attributes)
            initials.draw(at: NSPoint(x: rect.midX - textSize.width / 2, y: rect.midY - textSize.height / 2), withAttributes: attributes)
            return true
        }
    }
}
