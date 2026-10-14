import AppKit
import ImageIO
import UniformTypeIdentifiers

extension NSPasteboard.PasteboardType {
    static let jpeg = NSPasteboard.PasteboardType(UTType.jpeg.identifier)
    static let heic = NSPasteboard.PasteboardType(UTType.heic.identifier)
}

/// Files staged in the compose field and prepared for upload.
enum OutgoingMedia {
    /// Pasted/dropped images and copies of every sent file live here, so sent messages keep
    /// showing their local copy even if the original is moved or deleted.
    nonisolated static let directory: URL = {
        let url = AppData.folder.appendingPathComponent("outgoing", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    /// A fresh folder for one file, so its original name can be kept (it's shown for documents).
    nonisolated static func newSlot() -> URL {
        let url = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Raw image types read from the pasteboard (Continuity Camera photos are JPEG or HEIC).
    static let imagePasteboardTypes: [NSPasteboard.PasteboardType] = [.png, .jpeg, .heic, .tiff]

    /// Saves raw image data from the pasteboard (screenshots, images copied in a browser,
    /// Continuity Camera photos).
    static func save(imageData data: Data, type: NSPasteboard.PasteboardType) -> URL? {
        let slot = newSlot()
        // Kept as they are (HEIC is converted when it's sent).
        let extensions: [NSPasteboard.PasteboardType: String] = [.png: "png", .jpeg: "jpg", .heic: "heic"]
        if let pathExtension = extensions[type] {
            let url = slot.appendingPathComponent("Image").appendingPathExtension(pathExtension)
            return (try? data.write(to: url)) != nil ? url : nil
        }
        // TIFF and anything else: re-encode as PNG (lossless, widely supported).
        guard let rep = NSBitmapImageRep(data: data), let png = rep.representation(using: .png, properties: [:]) else {
            return nil
        }
        let url = slot.appendingPathComponent("Image.png")
        return (try? png.write(to: url)) != nil ? url : nil
    }

    static func isImage(_ url: URL) -> Bool {
        UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) ?? false
    }

    /// Copies the file into the outgoing folder, converting images Messenger can't show
    /// (HEIC, TIFF, …) to JPEG. Runs off the main thread.
    nonisolated static func prepare(_ url: URL) throws -> URL {
        let type = UTType(filenameExtension: url.pathExtension)
        let passThrough: [UTType] = [.jpeg, .png, .gif, .webP]
        let slot = newSlot()
        if let type, type.conforms(to: .image), !passThrough.contains(where: { type.conforms(to: $0) }) {
            let out = slot.appendingPathComponent(url.deletingPathExtension().lastPathComponent + ".jpg")
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let destination = CGImageDestinationCreateWithURL(out as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            CGImageDestinationAddImageFromSource(destination, source, 0, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
            guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
            return out
        }
        if url.path.hasPrefix(directory.path) {
            return url
        }
        let out = slot.appendingPathComponent(url.lastPathComponent)
        try FileManager.default.copyItem(at: url, to: out)
        return out
    }

    /// A small preview for the compose field: the image itself with rounded corners, or the
    /// file's icon and name.
    static func thumbnail(for url: URL, maxHeight: CGFloat = 90, maxWidth: CGFloat = 180) -> NSImage {
        if isImage(url), let source = CGImageSourceCreateWithURL(url as CFURL, nil),
           let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, [
               kCGImageSourceCreateThumbnailFromImageAlways: true,
               kCGImageSourceCreateThumbnailWithTransform: true,
               kCGImageSourceThumbnailMaxPixelSize: Int(maxWidth * 2),
           ] as CFDictionary) {
            let aspect = CGFloat(cgImage.width) / CGFloat(max(cgImage.height, 1))
            var size = NSSize(width: maxHeight * aspect, height: maxHeight)
            if size.width > maxWidth {
                size = NSSize(width: maxWidth, height: maxWidth / aspect)
            }
            return NSImage(size: size, flipped: false) { rect in
                NSBezierPath(roundedRect: rect, xRadius: 10, yRadius: 10).addClip()
                NSGraphicsContext.current?.cgContext.draw(cgImage, in: rect)
                return true
            }
        }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        let name = url.lastPathComponent as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.labelColor,
        ]
        let size = NSSize(width: maxWidth, height: 52)
        return NSImage(size: size, flipped: false) { rect in
            NSColor.quaternaryLabelColor.setFill()
            NSBezierPath(roundedRect: rect, xRadius: 10, yRadius: 10).fill()
            icon.draw(in: NSRect(x: 8, y: 8, width: 36, height: 36))
            let textRect = NSRect(x: 50, y: 0, width: rect.width - 58, height: rect.height)
            let textSize = name.size(withAttributes: attributes)
            name.draw(with: NSRect(x: textRect.minX, y: (rect.height - textSize.height) / 2, width: textRect.width, height: textSize.height),
                      options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: attributes)
            return true
        }
    }
}

/// A file staged in the compose field, shown inline as a thumbnail like in Messages.
final class ComposeAttachment: NSTextAttachment {
    let fileURL: URL

    init(fileURL: URL) {
        self.fileURL = fileURL
        super.init(data: nil, ofType: nil)
        attachmentCell = NSTextAttachmentCell(imageCell: OutgoingMedia.thumbnail(for: fileURL))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}
