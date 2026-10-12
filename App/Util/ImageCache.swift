import AppKit

/// Memory cache + request de-duplication for avatars and attachment images.
final class ImageCache {
    static let shared = ImageCache()

    private let cache = NSCache<NSString, NSImage>()
    private var inflight: [String: Task<NSImage?, Never>] = [:]

    private init() {
        cache.countLimit = 500
    }

    func cached(_ key: String) -> NSImage? {
        cache.object(forKey: key as NSString)
    }

    /// Loads a remote (http/https) or local file URL.
    func image(for url: URL) async -> NSImage? {
        await load(key: url.absoluteString) {
            if url.isFileURL {
                return NSImage(contentsOf: url)
            }
            guard let (data, _) = try? await URLSession.shared.data(from: url) else { return nil }
            return NSImage(data: data)
        }
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
