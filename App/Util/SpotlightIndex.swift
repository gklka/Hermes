import AppKit
import Combine
import CoreSpotlight
import UniformTypeIdentifiers

/// Puts the chats (names and pictures, not messages) in Spotlight: type the app's name, Tab,
/// then a chat's name. Choosing one opens the app on that chat (AppDelegate's
/// `application(_:continue:restorationHandler:)`).
final class SpotlightIndex {
    static let shared = SpotlightIndex()

    private static let domain = "chats"
    private let store = ChatStore.shared
    private var cancellable: AnyCancellable?
    private var pending: Task<Void, Never>?
    /// What's indexed per chat (name, and whether it has a picture), to only re-index changes.
    private var indexed: [String: String] = [:]
    private var didClearOldItems = false

    func start() {
        guard cancellable == nil else { return }
        cancellable = store.changes.sink { [weak self] change in
            if case .conversations = change { self?.scheduleUpdate() }
        }
        scheduleUpdate()
    }

    /// After logging out, nothing of the account stays searchable.
    func clear() {
        pending?.cancel()
        indexed = [:]
        CSSearchableIndex.default().deleteSearchableItems(withDomainIdentifiers: [Self.domain]) { error in
            if let error { CoreBridge.shared.log("Spotlight: couldn't clear the index: \(error.localizedDescription)") }
        }
    }

    /// Chat updates come in bursts while syncing; index once they settle.
    private func scheduleUpdate() {
        pending?.cancel()
        pending = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            await self?.update()
        }
    }

    private func update() async {
        let index = CSSearchableIndex.default()
        do {
            // Chats deleted while the app wasn't running would otherwise stay findable.
            if !didClearOldItems {
                didClearOldItems = true
                try await index.deleteSearchableItems(withDomainIdentifiers: [Self.domain])
            }
            var items: [CSSearchableItem] = []
            var current: [String: String] = [:]
            for conversation in store.conversations where !conversation.name.isEmpty {
                // Pictures already loaded for the chat list (a chat gets its picture once it's been shown).
                let picture = conversation.avatarURL.flatMap(URL.init(string:)).flatMap { ImageCache.shared.cached($0) }
                let signature = "\(conversation.name)|\(picture != nil)"
                current[conversation.id] = signature
                if indexed[conversation.id] != signature {
                    items.append(Self.item(for: conversation, picture: picture))
                }
            }
            let removed = indexed.keys.filter { current[$0] == nil }
            indexed = current
            if !items.isEmpty {
                try await index.indexSearchableItems(items)
            }
            if !removed.isEmpty {
                try await index.deleteSearchableItems(withIdentifiers: removed)
            }
        } catch {
            CoreBridge.shared.log("Spotlight: indexing failed: \(error.localizedDescription)")
        }
    }

    private static func item(for conversation: Conversation, picture: NSImage?) -> CSSearchableItem {
        let attributes = CSSearchableItemAttributeSet(contentType: .content)
        attributes.title = conversation.name
        attributes.displayName = conversation.name
        attributes.thumbnailData = picture.flatMap(thumbnail)
        return CSSearchableItem(uniqueIdentifier: conversation.id, domainIdentifier: domain, attributeSet: attributes)
    }

    /// A small PNG of the chat's picture.
    private static func thumbnail(_ image: NSImage) -> Data? {
        let size = 128
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }
}
