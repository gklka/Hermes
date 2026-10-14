import AppKit
import CryptoKit
import LinkPresentation

/// Link previews: a picture, title and site name, shown by `LinkCardView`. Web pages' details are
/// fetched once with Apple's LinkPresentation (as in Messages) and cached in memory and on disk;
/// Facebook links use Messenger's own card. Everything already loaded is available synchronously,
/// so a cell scrolled back into view shows its preview right away.
final class LinkPreviews {
    static let shared = LinkPreviews()

    struct Preview {
        var url: URL?
        var title: String
        var site: String?
        var image: NSImage?
        /// The picture's size, known before it's loaded for Messenger's cards.
        var imageSize: CGSize?
    }

    /// Fetched (or failed, as a plain link) web previews.
    private var web: [URL: Preview] = [:]
    private var inFlight: [URL: Task<Preview?, Never>] = [:]

    private let directory = AppData.folder.appendingPathComponent("linkpreviews", isDirectory: true)

    /// What to show now: the loaded preview, or what's known before loading (for cards all but
    /// a not yet loaded picture; for web links the site's name).
    func preview(for source: Source) -> Preview {
        switch source {
        case .web(let url):
            if let preview = cachedWeb(url) { return preview }
            // Room for the picture most pages have, so the card keeps its size when it loads.
            var loading = Self.plainLink(url)
            loading.imageSize = Self.webImageSize
            return loading
        case .card(let card):
            let site = card.url.flatMap { Self.site($0) }
            return Preview(
                url: card.url,
                title: card.title ?? site ?? "Link",
                site: site,
                image: card.imageURL.flatMap { ImageCache.shared.cached($0) },
                imageSize: card.imageSize
            )
        }
    }

    /// Loads what `preview(for:)` is still missing. Nil when there's nothing new.
    func load(_ source: Source) async -> Preview? {
        switch source {
        case .web(let url):
            guard cachedWeb(url) == nil else { return nil }
            return await fetch(url)
        case .card(let card):
            guard let imageURL = card.imageURL, ImageCache.shared.cached(imageURL) == nil,
                  await ImageCache.shared.image(for: imageURL) != nil else { return nil }
            return preview(for: source)
        }
    }

    // MARK: - Web pages

    /// Web pages' pictures are shown in the shape most share pictures have (1.91:1), cropped.
    private static let webImageSize = CGSize(width: 1.91, height: 1)

    private func cachedWeb(_ url: URL) -> Preview? {
        if let preview = web[url] { return preview }
        guard let data = try? Data(contentsOf: file(for: url, extension: "json")),
              let stored = try? JSONDecoder().decode(Stored.self, from: data) else { return nil }
        let image = stored.hasImage ? NSImage(contentsOf: file(for: url, extension: "jpg")) : nil
        let preview = Preview(url: url, title: stored.title, site: stored.site, image: image, imageSize: image == nil ? nil : Self.webImageSize)
        web[url] = preview
        return preview
    }

    /// Fetches the page's details (failures become a plain link, not retried until relaunch).
    private func fetch(_ url: URL) async -> Preview {
        let task: Task<Preview?, Never>
        if let running = inFlight[url] {
            task = running
        } else {
            task = Task { await Self.download(url) }
            inFlight[url] = task
        }
        let fetched = await task.value
        inFlight[url] = nil
        if let existing = web[url] { return existing }
        let preview = fetched ?? Self.plainLink(url)
        web[url] = preview
        if let fetched { save(fetched, for: url) }
        return preview
    }

    private static func download(_ url: URL) async -> Preview? {
        let provider = LPMetadataProvider()
        provider.timeout = 15
        do {
            let metadata = try await provider.startFetchingMetadata(for: url)
            var image: NSImage?
            if let imageProvider = metadata.imageProvider {
                image = await loadImage(imageProvider)
            }
            let site = site(metadata.url ?? url)
            return Preview(url: url, title: metadata.title ?? site ?? url.absoluteString, site: site, image: image, imageSize: image == nil ? nil : Self.webImageSize)
        } catch {
            CoreBridge.shared.log("Link preview for \(url.host() ?? "?") failed: \(error.localizedDescription)")
            return nil
        }
    }

    private nonisolated static func loadImage(_ provider: NSItemProvider) async -> NSImage? {
        await withCheckedContinuation { continuation in
            provider.loadObject(ofClass: NSImage.self) { @Sendable object, _ in
                continuation.resume(returning: object as? NSImage)
            }
        }
    }

    /// A preview with just the link's site as its title.
    private static func plainLink(_ url: URL) -> Preview {
        let site = site(url)
        return Preview(url: url, title: site ?? url.absoluteString, site: site)
    }

    private static func site(_ url: URL) -> String? {
        url.host().map { $0.hasPrefix("www.") ? String($0.dropFirst(4)) : $0 }
    }

    private struct Stored: Codable {
        let title: String
        let site: String?
        let hasImage: Bool
    }

    private func save(_ preview: Preview, for url: URL) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var hasImage = false
            if let tiff = preview.image?.tiffRepresentation,
               let jpeg = NSBitmapImageRep(data: tiff)?.representation(using: .jpeg, properties: [.compressionFactor: 0.85]) {
                try jpeg.write(to: file(for: url, extension: "jpg"))
                hasImage = true
            }
            let stored = Stored(title: preview.title, site: preview.site, hasImage: hasImage)
            try JSONEncoder().encode(stored).write(to: file(for: url, extension: "json"))
        } catch {
            CoreBridge.shared.log("Couldn't cache the link preview for \(url.host() ?? "?"): \(error.localizedDescription)")
        }
    }

    private func file(for url: URL, extension pathExtension: String) -> URL {
        let hash = SHA256.hash(data: Data(url.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(hash).appendingPathExtension(pathExtension)
    }

    // MARK: - Finding the link in a message

    /// Messenger's card for a link: Facebook's own pages need a login, so fetched previews of
    /// them come out empty; the card has their title and picture. Cards don't carry the link
    /// itself (it's in the message text), and some (shared events, posts) have none at all.
    struct Card {
        let url: URL?
        let title: String?
        let imageURL: URL?
        let imageSize: CGSize?
    }

    enum Source {
        /// Fetched by Apple's LinkPresentation.
        case web(URL)
        /// Built from Messenger's card.
        case card(Card)
    }

    private static let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    /// What a message's link preview shows: the first web link in its text (or the card's
    /// link), or for Facebook and Instagram links (and cards without a link), Messenger's card.
    /// A Facebook link without a card gets no preview.
    static func source(text: String, attachments: [Attachment]) -> Source? {
        let range = NSRange(text.startIndex..., in: text)
        let textURL = detector?.firstMatch(in: text, range: range)?.url.flatMap { isWeb($0) ? $0 : nil }
        if let textURL, !isFacebook(textURL) {
            return .web(textURL)
        }
        guard let attachment = attachments.first(where: { $0.kind == .link }) else { return nil }
        let cardURL = attachment.url.flatMap(URL.init(string:)).map { unwrapRedirect($0) }.flatMap { isWeb($0) ? $0 : nil } ?? textURL
        if let cardURL, !isFacebook(cardURL) {
            return .web(cardURL)
        }
        let title = attachment.title.flatMap { $0.isEmpty ? nil : $0 }
        let imageURL = attachment.previewURL.flatMap(URL.init(string:))
        guard title != nil || imageURL != nil else { return nil }
        var imageSize: CGSize?
        if let width = attachment.width, let height = attachment.height, width > 0, height > 0 {
            imageSize = CGSize(width: width, height: height)
        }
        return .card(Card(url: cardURL, title: title, imageURL: imageURL, imageSize: imageSize))
    }

    private static let facebookDomains = [
        "facebook.com", "fb.com", "fb.watch", "fb.me", "messenger.com", "m.me", "instagram.com", "instagr.am",
    ]

    private static func isFacebook(_ url: URL) -> Bool {
        guard let host = url.host()?.lowercased() else { return false }
        return facebookDomains.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    /// True when the message's text is just a link (then only the preview is shown).
    static func isOnlyLink(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        let range = NSRange(trimmed.startIndex..., in: trimmed)
        guard let match = detector?.firstMatch(in: trimmed, range: range) else { return false }
        return match.range == range && match.url.map { isWeb($0) } == true
    }

    private static func isWeb(_ url: URL) -> Bool {
        ["http", "https"].contains(url.scheme?.lowercased() ?? "")
    }

    /// l.facebook.com/l.php?u=<real URL> → the real URL.
    private static func unwrapRedirect(_ url: URL) -> URL {
        guard let host = url.host(), host.hasPrefix("l.facebook.com") || host.hasPrefix("lm.facebook.com"),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let target = components.queryItems?.first(where: { $0.name == "u" })?.value,
              let real = URL(string: target) else { return url }
        return real
    }
}
