import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Reading a picture's size without decoding it, and the stand-in Quick Look shows while the
/// full picture downloads.
enum ImageSize {
    /// A downloaded picture's pixel size (reading just its header).
    static func ofFile(_ url: URL) -> CGSize? {
        CGImageSourceCreateWithURL(url as CFURL, nil).flatMap(ofSource)
    }

    /// Reads an image's pixel size from the start of its file (the header), without downloading it all.
    @concurrent nonisolated static func probe(_ url: URL) async -> CGSize? {
        var request = URLRequest(url: url, timeoutInterval: 1.5)
        request.setValue("bytes=0-65535", forHTTPHeaderField: "Range")
        guard let (data, _) = try? await URLSession.shared.data(for: request) else { return nil }
        if let size = fromHeader(data) {
            return size
        }
        // Other formats: ImageIO, which needs the whole file (small files come back whole).
        return CGImageSourceCreateWithData(data as CFData, nil).flatMap(ofSource)
    }

    /// The size ImageIO reports, as shown: EXIF orientations 5–8 are rotated by 90°, which
    /// swaps the width and height.
    nonisolated private static func ofSource(_ source: CGImageSource) -> CGSize? {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int, width > 0, height > 0 else { return nil }
        let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
        return orientation >= 5 ? CGSize(width: height, height: width) : CGSize(width: width, height: height)
    }

    /// Pixel size from the first bytes of a JPEG, PNG or WebP file (Facebook serves full-size
    /// photos as WebP). ImageIO wants much more of the file than the header to tell the size.
    nonisolated static func fromHeader(_ data: Data) -> CGSize? {
        let b = [UInt8](data.prefix(65536))
        func be16(_ i: Int) -> Int { Int(b[i]) << 8 | Int(b[i + 1]) }
        func le16(_ i: Int) -> Int { Int(b[i]) | Int(b[i + 1]) << 8 }
        func le24(_ i: Int) -> Int { Int(b[i]) | Int(b[i + 1]) << 8 | Int(b[i + 2]) << 16 }
        func size(_ w: Int, _ h: Int) -> CGSize? { w > 0 && h > 0 ? CGSize(width: w, height: h) : nil }
        // PNG: the IHDR chunk.
        if b.count >= 24, b[0] == 0x89, b[1] == 0x50, b[2] == 0x4E, b[3] == 0x47 {
            return size(be16(16) << 16 | be16(18), be16(20) << 16 | be16(22))
        }
        // WebP: "RIFF....WEBP", then a VP8 / VP8L / VP8X chunk.
        if b.count >= 30, b[0] == 0x52, b[1] == 0x49, b[2] == 0x46, b[3] == 0x46,
           b[8] == 0x57, b[9] == 0x45, b[10] == 0x42, b[11] == 0x50 {
            switch (b[12], b[13], b[14], b[15]) {
            case (0x56, 0x50, 0x38, 0x20): // "VP8 " (lossy)
                return size(le16(26) & 0x3FFF, le16(28) & 0x3FFF)
            case (0x56, 0x50, 0x38, 0x4C): // "VP8L" (lossless)
                let bits = Int(b[21]) | Int(b[22]) << 8 | Int(b[23]) << 16 | Int(b[24]) << 24
                return size((bits & 0x3FFF) + 1, ((bits >> 14) & 0x3FFF) + 1)
            case (0x56, 0x50, 0x38, 0x58): // "VP8X" (extended)
                return size(le24(24) + 1, le24(27) + 1)
            default:
                return nil
            }
        }
        // JPEG: the first start-of-frame marker.
        guard b.count > 4, b[0] == 0xFF, b[1] == 0xD8 else { return nil }
        var i = 2
        while i + 9 < b.count {
            guard b[i] == 0xFF else { return nil }
            let marker = b[i + 1]
            if marker == 0xFF { i += 1; continue }
            if marker == 0x01 || (0xD0...0xD8).contains(marker) { i += 2; continue }
            if (0xC0...0xCF).contains(marker), ![0xC4, 0xC8, 0xCC].contains(marker) {
                return size(be16(i + 7), be16(i + 5))
            }
            i += 2 + be16(i + 2)
        }
        return nil
    }

    /// Writes the chat's low-res picture, scaled up to the full picture's size, to a temporary
    /// file Quick Look can show. At the final size, Quick Look opens its window at the size it
    /// keeps when the full picture replaces it.
    @concurrent nonisolated static func writeQuickLookPreview(_ image: CGImage, finalSize: CGSize, attachmentID: String) async -> URL? {
        // Large enough for any screen while keeping the aspect ratio exact.
        let scale = min(1, 6000 / max(finalSize.width, finalSize.height))
        let width = max(1, Int((finalSize.width * scale).rounded()))
        let height = max(1, Int((finalSize.height * scale).rounded()))
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let scaled = context.makeImage() else { return nil }

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("QuickLookPreviews", isDirectory: true)
        let name = attachmentID.replacingOccurrences(of: "/", with: "_")
        let url = directory.appendingPathComponent("\(name)-preview.jpg")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            return nil
        }
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        let properties: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: 0.8,
            kCGImagePropertyDPIWidth: 72,
            kCGImagePropertyDPIHeight: 72,
        ]
        CGImageDestinationAddImage(destination, scaled, properties as CFDictionary)
        return CGImageDestinationFinalize(destination) ? url : nil
    }
}
