import AppKit
import CryptoKit

/// Memory cache + request de-duplication for avatars and attachment images, with a disk cache for
/// remote pictures (link/rich-share previews from Facebook and Instagram) so they survive relaunch.
final class ImageCache {
    static let shared = ImageCache()

    private let cache = NSCache<NSString, NSImage>()
    private var inflight: [String: Task<NSImage?, Never>] = [:]
    private let directory = AppData.folder.appendingPathComponent("imagecache", isDirectory: true)

    private init() {
        cache.countLimit = 500
    }

    /// Forgets the cached pictures (logging out).
    func clear() {
        cache.removeAllObjects()
        inflight.values.forEach { $0.cancel() }
        inflight = [:]
        try? FileManager.default.removeItem(at: directory)
    }

    func cached(_ key: String) -> NSImage? {
        cache.object(forKey: key as NSString)
    }

    func cached(_ url: URL) -> NSImage? {
        cached(Self.key(for: url))
    }

    /// Facebook's CDN links carry signing tokens in the query that change on every sync, so the
    /// same picture gets a new link each time; it's cached by its path.
    static func key(for url: URL) -> String {
        guard let host = url.host(), host.contains("fbcdn") || host.contains("fbsbx"),
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url.absoluteString }
        components.query = nil
        return components.string ?? url.absoluteString
    }

    /// Loads a remote (http/https) or local file URL. Remote pictures are cached on disk.
    func image(for url: URL) async -> NSImage? {
        let key = Self.key(for: url)
        return await load(key: key) { [directory] in
            if url.isFileURL {
                return NSImage(contentsOf: url)
            }
            let file = Self.file(in: directory, for: key)
            if let data = try? Data(contentsOf: file), let image = NSImage(data: data) {
                return image
            }
            guard let (data, _) = try? await URLSession.shared.data(from: url), let image = NSImage(data: data) else {
                return nil
            }
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? data.write(to: file)
            return image
        }
    }

    private static func file(in directory: URL, for key: String) -> URL {
        let hash = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(hash)
    }

    /// Loads an attachment through the core (which downloads and decrypts it as needed).
    func image(for attachment: Attachment, in message: ChatMessage) async -> NSImage? {
        await load(key: Self.key(for: attachment, in: message)) {
            guard let url = try? await ChatStore.shared.localFile(for: attachment, in: message) else { return nil }
            return NSImage(contentsOf: url)
        }
    }

    static func key(for attachment: Attachment, in message: ChatMessage) -> String {
        "\(message.id)/\(attachment.id)"
    }

    private func load(key: String, _ loader: @escaping () async -> NSImage?) async -> NSImage? {
        if let image = cached(key) { return image }
        if let task = inflight[key] { return await task.value }
        let task = Task { await loader() }
        inflight[key] = task
        let image = await task.value
        inflight[key] = nil
        if let image { cache.setObject(image, forKey: key as NSString) }
        return image
    }
}
