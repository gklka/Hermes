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

    /// As a bitmap (at 2x): menus are drawn outside the app, which leaves out images that are
    /// only drawing code.
    static func image(_ picture: NSImage?, name: String, size: CGFloat) -> NSImage {
        let drawn = drawing(picture, name: name, size: size)
        let scale: CGFloat = 2
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size * scale), pixelsHigh: Int(size * scale), bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return drawn }
        rep.size = drawn.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        drawn.draw(in: NSRect(origin: .zero, size: drawn.size))
        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(size: drawn.size)
        image.addRepresentation(rep)
        return image
    }

    private static func drawing(_ picture: NSImage?, name: String, size: CGFloat) -> NSImage {
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
