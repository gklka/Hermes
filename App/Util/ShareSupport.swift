import AppKit
import Combine
import WidgetKit

/// The app's side of the share extension (ShareHandoff): keeps the most recent chats and their
/// pictures in the app group for the extension's picker, and sends what the extension leaves in
/// the Outbox.
final class ShareSupport {
    static let shared = ShareSupport()

    /// How many chats the extension's picker offers, most recent first.
    private static let chatCount = 50

    private let store = ChatStore.shared
    private var cancellable: AnyCancellable?
    private let updates = Debouncer(delay: .seconds(3))
    /// The chats as last written ("<id>|<name>|<has picture>"), to only write changes.
    private var written: [String] = []

    func start() {
        guard cancellable == nil else { return }
        cancellable = store.changes.sink { [weak self] change in
            if case .conversations = change { self?.scheduleUpdate() }
        }
        scheduleUpdate()
        // Shares that arrived while the app wasn't running (or couldn't send yet).
        Task { await sendOutbox() }
    }

    /// After logging out: none of the account's chats stay in the app group.
    func clear() {
        updates.cancel()
        written = []
        if let file = ShareHandoff.recentChatsFile {
            try? FileManager.default.removeItem(at: file)
        }
        if let avatars = ShareHandoff.avatarsFolder {
            try? FileManager.default.removeItem(at: avatars)
        }
        WidgetCenter.shared.reloadAllTimelines()
    }

    private func scheduleUpdate() {
        updates.schedule { [weak self] in self?.update() }
    }

    /// Pictures already requested for the share sheet's most recent chats.
    private var requestedPictures: Set<URL> = []

    private func update() {
        guard let file = ShareHandoff.recentChatsFile, let avatars = ShareHandoff.avatarsFolder else { return }
        let recent = Array(store.conversations.filter { !$0.name.isEmpty }.prefix(Self.chatCount))
        // The top chats' pictures, even if the chat list hasn't shown them yet; written once loaded.
        // For a group without its own photo, its members' pictures (for the composite icon).
        let missing = recent.prefix(10).flatMap(pictureURLs)
            .filter { ImageCache.shared.cached($0) == nil && requestedPictures.insert($0).inserted }
        if !missing.isEmpty {
            Task { [weak self] in
                for url in missing { _ = await ImageCache.shared.image(for: url) }
                self?.scheduleUpdate()
            }
        }
        let pictures = recent.map(picture)
        let signature = zip(recent, pictures).map { "\($0.id)|\($0.name)|\($1 != nil)" }
        guard signature != written else { return }
        written = signature

        let fileManager = FileManager.default
        try? fileManager.removeItem(at: avatars)
        try? fileManager.createDirectory(at: avatars, withIntermediateDirectories: true)
        var chats: [ShareHandoff.Chat] = []
        for (conversation, picture) in zip(recent, pictures) {
            let saved = picture.map {
                (try? $0.write(to: avatars.appendingPathComponent("\(conversation.id).png"))) != nil
            } ?? false
            chats.append(ShareHandoff.Chat(id: conversation.id, name: conversation.name, hasAvatar: saved))
        }
        if let data = try? JSONEncoder().encode(chats) {
            try? data.write(to: file, options: .atomic)
            WidgetCenter.shared.reloadAllTimelines()
        }
    }

    /// Whether the group has no picture of its own, so it's shown as its members (like the app).
    private func isMemberGroup(_ conversation: Conversation) -> Bool {
        conversation.isGroup && (conversation.avatarURL?.isEmpty ?? true)
    }

    /// Up to three members shown in a group's composite icon (latest sender first, then photos).
    private func groupMembers(_ conversation: Conversation) -> [Participant] {
        let selfID = store.account?.id
        return Array(conversation.participants.filter { $0.id != selfID }.sorted { a, b in
            if (a.id == conversation.snippetSenderID) != (b.id == conversation.snippetSenderID) {
                return a.id == conversation.snippetSenderID
            }
            return (a.avatarURL?.isEmpty == false) && (b.avatarURL?.isEmpty != false)
        }.prefix(3))
    }

    /// The picture URLs a chat needs loaded: its own, or its members' (for a group composite).
    private func pictureURLs(_ conversation: Conversation) -> [URL] {
        if isMemberGroup(conversation) {
            return groupMembers(conversation).compactMap { $0.avatarURL.flatMap(URL.init(string:)) }
        }
        return conversation.avatarURL.flatMap(URL.init(string:)).map { [$0] } ?? []
    }

    /// The chat's picture as already loaded for the chat list, as a small PNG. A group with no
    /// picture of its own is drawn from its members, like the app's avatar.
    private func picture(of conversation: Conversation) -> Data? {
        if isMemberGroup(conversation) {
            return groupPicture(of: conversation)
        }
        return conversation.avatarURL.flatMap(URL.init(string:)).flatMap { ImageCache.shared.cached($0) }
            .flatMap { SpotlightIndex.thumbnail($0) }
    }

    /// A group's composite icon: up to three members clustered in a circle, like `ConversationAvatarView`.
    private func groupPicture(of conversation: Conversation) -> Data? {
        let picked = groupMembers(conversation)
        guard !picked.isEmpty else { return nil }
        let count = max(2, picked.count)
        let size: CGFloat = 128
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            // No background fill: the widget tints the gaps between members (5% of the text color).
            NSBezierPath(ovalIn: rect).addClip()
            let center = NSPoint(x: rect.midX, y: rect.midY)
            let memberSize: CGFloat, distance: CGFloat, angles: [CGFloat]
            if count == 2 {
                memberSize = size * 0.56; distance = size * 0.2; angles = [135, -45]
            } else {
                memberSize = size * 0.52; distance = size * 0.24; angles = [90, 210, 330]
            }
            for index in 0..<count {
                let member = index < picked.count ? picked[index] : nil
                let photo = member?.avatarURL.flatMap(URL.init(string:)).flatMap { ImageCache.shared.cached($0) }
                let avatar = RoundAvatar.image(photo, name: member?.name ?? conversation.name, size: memberSize)
                let angle = angles[index] * .pi / 180
                let point = NSPoint(x: center.x + cos(angle) * distance, y: center.y + sin(angle) * distance)
                avatar.draw(in: NSRect(x: point.x - memberSize / 2, y: point.y - memberSize / 2, width: memberSize, height: memberSize))
            }
            return true
        }
        return SpotlightIndex.thumbnail(image)
    }

    // MARK: - Sending

    /// `hermes://share?id=<folder>`, from the share extension.
    func handle(_ url: URL) {
        guard url.scheme == ShareHandoff.urlScheme, url.host() == ShareHandoff.shareHost else { return }
        Task { await sendOutbox() }
    }

    private var isSending = false

    /// Sends every request in the Outbox, once the app is logged in with its chats loaded.
    private func sendOutbox() async {
        guard !isSending, let outbox = ShareHandoff.outbox else { return }
        isSending = true
        defer { isSending = false }
        guard await store.waitUntilReady() else { return }
        let folders = (try? FileManager.default.contentsOfDirectory(at: outbox, includingPropertiesForKeys: nil)) ?? []
        for folder in folders {
            send(folder)
        }
    }

    private func send(_ folder: URL) {
        defer { try? FileManager.default.removeItem(at: folder) }
        guard let data = try? Data(contentsOf: folder.appendingPathComponent(ShareHandoff.requestFileName)),
              let request = try? JSONDecoder().decode(ShareHandoff.Request.self, from: data),
              store.conversation(request.threadID) != nil else {
            CoreBridge.shared.log("ShareSupport: dropped an unreadable share \(folder.lastPathComponent)")
            return
        }
        // Into the outgoing folder, like a pasted file, before the share's folder goes.
        let files = request.files.compactMap { name -> URL? in
            let source = folder.appendingPathComponent(name)
            let target = OutgoingMedia.newSlot().appendingPathComponent(source.lastPathComponent)
            return (try? FileManager.default.moveItem(at: source, to: target)) == nil ? nil : target
        }
        store.send(text: request.text, attachments: files, in: request.threadID)
        CoreBridge.shared.log("ShareSupport: sent a share to \(request.threadID) (\(files.count) files)")
    }
}
