import AppKit
import Combine

/// The app's side of the share extension (ShareHandoff): keeps the most recent chats and their
/// pictures in the app group for the extension's picker, and sends what the extension leaves in
/// the Outbox.
final class ShareSupport {
    static let shared = ShareSupport()

    /// How many chats the extension's picker offers, most recent first.
    private static let chatCount = 50

    private let store = ChatStore.shared
    private var cancellable: AnyCancellable?
    private var pending: Task<Void, Never>?
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
        pending?.cancel()
        written = []
        if let file = ShareHandoff.recentChatsFile {
            try? FileManager.default.removeItem(at: file)
        }
        if let avatars = ShareHandoff.avatarsFolder {
            try? FileManager.default.removeItem(at: avatars)
        }
    }

    /// Chat updates come in bursts while syncing; update once they settle.
    private func scheduleUpdate() {
        pending?.cancel()
        pending = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            self?.update()
        }
    }

    /// Pictures already requested for the share sheet's most recent chats.
    private var requestedPictures: Set<URL> = []

    private func update() {
        guard let file = ShareHandoff.recentChatsFile, let avatars = ShareHandoff.avatarsFolder else { return }
        let recent = Array(store.conversations.filter { !$0.name.isEmpty }.prefix(Self.chatCount))
        // The top chats' pictures, even if the chat list hasn't shown them yet; written once loaded.
        let missing = recent.prefix(10).compactMap { $0.avatarURL.flatMap(URL.init(string:)) }
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
            chats.append(ShareHandoff.Chat(id: conversation.id, name: conversation.name, isGroup: conversation.isGroup, hasAvatar: saved))
        }
        if let data = try? JSONEncoder().encode(chats) {
            try? data.write(to: file, options: .atomic)
        }
    }

    /// The chat's picture as already loaded for the chat list, as a small PNG.
    private func picture(of conversation: Conversation) -> Data? {
        conversation.avatarURL.flatMap(URL.init(string:)).flatMap { ImageCache.shared.cached($0) }
            .flatMap(SpotlightIndex.thumbnail)
    }

    // MARK: - Sending

    /// `messengermac://share?id=<folder>`, from the share extension.
    func handle(_ url: URL) -> Bool {
        guard url.scheme == ShareHandoff.urlScheme, url.host() == ShareHandoff.shareHost else { return false }
        Task { await sendOutbox() }
        return true
    }

    private var isSending = false

    /// Sends every request in the Outbox, once the app is logged in with its chats loaded.
    private func sendOutbox() async {
        guard !isSending, let outbox = ShareHandoff.outbox else { return }
        isSending = true
        defer { isSending = false }
        for _ in 0..<120 where store.account == nil || store.conversations.isEmpty {
            try? await Task.sleep(for: .milliseconds(500))
        }
        guard store.account != nil else { return }
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
