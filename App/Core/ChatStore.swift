import Combine
import Foundation

/// In-memory view model shared by all windows. The Go core is the source of truth
/// (it persists everything); this store mirrors what the UI currently needs.
final class ChatStore {
    static let shared = ChatStore()

    enum Change: Hashable {
        case connection
        case conversations
        case messages(threadID: String)
        case typing(threadID: String)
        case presence(userID: String)
    }

    let changes = PassthroughSubject<Change, Never>()
    /// Every message event from the core (new, edited or backfilled), for all threads.
    let messageEvents = PassthroughSubject<ChatMessage, Never>()
    /// Others' reactions to your messages (for notifications).
    let reactionEvents = PassthroughSubject<ReactionEvent, Never>()
    /// Chats read here or on another device (for notifications).
    let threadReadEvents = PassthroughSubject<ThreadReadEvent, Never>()

    private(set) var connectionState: ConnectionState = .disconnected
    private(set) var account: Account?

    /// The chats, sorted by most recent activity. Not message requests: they're in `requests`
    /// (shown under the Requests filter, not counted in the Dock or offered in Shortcuts and
    /// the Share menu). `conversation(_:)` finds both.
    private(set) var conversations: [Conversation] = []
    /// Message requests (someone you're not connected with wrote), most recent first.
    private(set) var requests: [Conversation] = []
    private var conversationsByID: [String: Conversation] = [:]

    /// Messages per thread, sorted oldest → newest. Only populated for opened threads.
    private var messagesByThread: [String: [ChatMessage]] = [:]
    private var hasMoreHistory: [String: Bool] = [:]
    private var loadingHistory: Set<String> = []

    /// threadID → set of userIDs currently typing.
    private(set) var typing: [String: Set<String>] = [:]
    private var typingTimers: [String: Timer] = [:]

    /// userID → latest online status / last-seen time (only for 1:1 chats that were opened).
    private(set) var presence: [String: PresenceEvent] = [:]

    private let core = CoreBridge.shared
    private var queuedChanges: [Change] = []
    private var conversationsDirty = false

    private init() {
        core.onEvent = { [weak self] name, payload in
            self?.handleEvent(name, payload)
        }
    }

    // MARK: - Queries

    /// Waits until the app is logged in with its chats loaded: a Shortcuts action, a
    /// notification's button or a share can launch it. False if it isn't logged in by then.
    func waitUntilReady(seconds: Int = 60) async -> Bool {
        for _ in 0..<(seconds * 2) where account == nil || conversations.isEmpty {
            do {
                try await Task.sleep(for: .milliseconds(500))
            } catch {
                // Cancelled.
                return false
            }
        }
        return account != nil
    }

    func conversation(_ id: String) -> Conversation? { conversationsByID[id] }

    func messages(in threadID: String) -> [ChatMessage] { messagesByThread[threadID] ?? [] }

    func participantName(_ userID: String, in threadID: String) -> String {
        if userID == account?.id { return "You" }
        return conversationsByID[threadID]?.participants.first { $0.id == userID }?.name ?? "Unknown"
    }

    func participant(_ userID: String, in threadID: String) -> Participant? {
        conversationsByID[threadID]?.participants.first { $0.id == userID }
    }

    // MARK: - Commands

    func start() {
        core.start(dataDirectory: AppData.folder)
    }

    func login(cookies: [String: String]) async throws {
        struct Params: Encodable { let cookies: [String: String] }
        try await core.call("login", Params(cookies: cookies))
    }

    func logout() async {
        try? await core.call("logout")
        forgetAccount()
    }

    /// Drops everything of the account that was logged in (logged out, or its session ended).
    private func forgetAccount() {
        account = nil
        conversations = []
        requests = []
        conversationsByID = [:]
        messagesByThread = [:]
        hasMoreHistory = [:]
        typing = [:]
        typingTimers.values.forEach { $0.invalidate() }
        typingTimers = [:]
        presence = [:]
        themesRefreshed = []
        markedUnread = []
        downloadedFiles = [:]
        unseenReactions = [:]
        notify(.conversations)
    }

    func userAgent() async -> String? {
        struct Result: Decodable { let userAgent: String }
        return try? await core.call("userAgent", as: Result.self).userAgent
    }

    func loadConversations() async {
        do {
            let list = try await core.call("threads.list", as: [Conversation].self)
            conversationsByID = Dictionary(list.map { ($0.id, $0) }, uniquingKeysWith: { $1 })
            resortConversations()
        } catch {
            core.log("threads.list failed: \(error)")
        }
    }

    func searchContacts(_ query: String) async -> [Participant] {
        struct Params: Encodable { let text: String }
        return (try? await core.call("contacts.search", Params(text: query), as: [Participant].self)) ?? []
    }

    /// Everyone Messenger finds by the name who can be messaged, not only people you've chatted with.
    func searchPeople(_ query: String) async -> [Participant] {
        struct Params: Encodable { let text: String }
        return (try? await core.call("contacts.searchPeople", Params(text: query), as: [Participant].self)) ?? []
    }

    /// Opens (creating if needed) the 1:1 chat with a contact.
    func openDirectChat(with userID: String) async throws -> Conversation {
        struct Params: Encodable { let userID: String }
        let conversation = try await core.call("threads.open", Params(userID: userID), as: Conversation.self)
        conversationsByID[conversation.id] = conversation
        resortConversations()
        return conversation
    }

    func loadMoreConversations() async {
        try? await core.call("threads.loadMore")
    }

    /// Loads the newest page for a thread (from the local database; the core
    /// fetches from the server in the background if it has nothing yet).
    func openThread(_ threadID: String) async {
        guard messagesByThread[threadID] == nil else { return }
        await loadPage(threadID, before: nil)
    }

    /// Conversation › Refresh: throws away the chat's stored messages and loads them again from
    /// Messenger (an encrypted chat's history from Messenger web).
    func resync(_ threadID: String) async {
        do {
            try await core.call("threads.resync", ThreadParams(threadID: threadID))
        } catch {
            core.log("threads.resync failed: \(error)")
            return
        }
        messagesByThread[threadID] = []
        hasMoreHistory[threadID] = nil
        notify(.messages(threadID: threadID))
        await loadPage(threadID, before: nil)
        if conversationsByID[threadID]?.isEncrypted == true {
            WebHistoryImporter.shared.reimport(threadID: threadID)
        }
    }

    private var themesRefreshed: Set<String> = []

    /// Fetches the chat's theme colors and quick reaction once per session; the core stores
    /// them with the chat (a conversations change follows if they changed).
    func refreshTheme(_ threadID: String) {
        guard themesRefreshed.insert(threadID).inserted else { return }
        Task {
            do {
                try await core.call("threads.refreshTheme", ThreadParams(threadID: threadID))
            } catch {
                themesRefreshed.remove(threadID)
            }
        }
    }

    /// Lets loadOlderMessages try again after it found the start (more history may have been
    /// fetched into the database since, e.g. by a search).
    func resetHistoryEnd(_ threadID: String) {
        hasMoreHistory[threadID] = nil
    }

    /// Whether the chat has older messages to load (stored, or on Messenger).
    func hasOlderMessages(_ threadID: String) -> Bool {
        hasMoreHistory[threadID] == true
    }

    /// Whether everything stored (and on Messenger's servers) is loaded.
    func reachedHistoryStart(_ threadID: String) -> Bool {
        hasMoreHistory[threadID] == false
    }

    /// Loads an older page. Returns false when there is nothing more to load.
    @discardableResult
    func loadOlderMessages(_ threadID: String) async -> Bool {
        guard hasMoreHistory[threadID] != false, !loadingHistory.contains(threadID) else { return false }
        let oldest = messagesByThread[threadID]?.first?.timestamp
        await loadPage(threadID, before: oldest)
        return true
    }

    /// The chat on facebook.com; Messenger's inbox for an encrypted chat whose web ID isn't known yet.
    func webURL(for threadID: String) async -> URL? {
        Facebook.url(await webPath(for: threadID) ?? "/messages/")
    }

    /// The chat's path on facebook.com ("/messages/t/123/"); nil for an encrypted chat whose web ID isn't known yet.
    func webPath(for threadID: String) async -> String? {
        struct Result: Decodable { let path: String }
        let path = (try? await core.call("web.threadPath", ThreadParams(threadID: threadID), as: Result.self).path) ?? ""
        return path.isEmpty ? nil : path
    }

    // MARK: - Search

    /// The chat's stored messages containing the text (ignoring case and accents), oldest
    /// first; `hasMore` if Messenger has older history to fetch (fetchOlderForSearch).
    func searchMessages(in threadID: String, text: String) async -> MessagesPage? {
        struct Params: Encodable { let threadID: String; let text: String; let limit: Int }
        return try? await core.call("messages.search", Params(threadID: threadID, text: text, limit: 500), as: MessagesPage.self)
    }

    /// Fetches one page of older history from Messenger into the database (not into the
    /// loaded messages), so a search can find it.
    func fetchOlderForSearch(_ threadID: String) async -> FetchOlderResult? {
        try? await core.call("messages.fetchOlder", ThreadParams(threadID: threadID), as: FetchOlderResult.self)
    }

    /// The chat's newest stored messages, without fetching history or touching what the UI shows.
    func storedMessages(in threadID: String, limit: Int) async -> [ChatMessage] {
        struct Params: Encodable { let threadID: String; let limit: Int }
        let page = try? await core.call("messages.stored", Params(threadID: threadID, limit: limit), as: MessagesPage.self)
        return page?.messages ?? []
    }

    private func loadPage(_ threadID: String, before: Int64?) async {
        struct Params: Encodable { let threadID: String; let before: Int64?; let limit: Int }
        loadingHistory.insert(threadID)
        defer { loadingHistory.remove(threadID) }
        do {
            let page = try await core.call(
                "messages.list", Params(threadID: threadID, before: before, limit: 50), as: MessagesPage.self
            )
            hasMoreHistory[threadID] = page.hasMore
            var existing = messagesByThread[threadID] ?? []
            let known = Set(existing.map(\.id))
            existing.append(contentsOf: page.messages.filter { !known.contains($0.id) })
            existing.sort { $0.timestamp < $1.timestamp }
            messagesByThread[threadID] = existing
            notify(.messages(threadID: threadID))
        } catch {
            core.log("messages.list failed: \(error)")
        }
    }

    /// Sends each attachment as its own message, then the text (like Messages). The reply
    /// target and the tagged people apply to the text.
    func send(text: String, mentions: [Mention] = [], attachments: [URL] = [], in threadID: String, replyTo: String? = nil) {
        struct TextParams: Encodable { let threadID: String; let text: String; let replyTo: String?; let mentions: [Mention] }
        struct MediaParams: Encodable { let threadID: String; let path: String }
        Task {
            for url in attachments {
                do {
                    let prepared = try await Task.detached { try OutgoingMedia.prepare(url) }.value
                    try await core.call("messages.sendMedia", MediaParams(threadID: threadID, path: prepared.path))
                } catch {
                    core.log("messages.sendMedia failed for \(url.lastPathComponent): \(error)")
                }
            }
            guard !text.isEmpty else { return }
            do {
                try await core.call("messages.send", TextParams(threadID: threadID, text: text, replyTo: replyTo, mentions: mentions))
            } catch {
                core.log("messages.send failed: \(error)")
            }
        }
    }

    /// Removes a message that failed to send (it only exists in this view model).
    func discard(_ message: ChatMessage) {
        messagesByThread[message.threadID]?.removeAll { $0.id == message.id }
        notify(.messages(threadID: message.threadID))
    }

    /// Sends a failed message again, with its text, files and reply target.
    func resend(_ message: ChatMessage) {
        discard(message)
        let files = message.attachments.compactMap { $0.localPath.map { URL(fileURLWithPath: $0) } }
        send(text: message.text, mentions: message.mentions ?? [], attachments: files, in: message.threadID,
             replyTo: message.replyTo?.messageID)
    }

    /// Pass an empty emoji to remove your reaction.
    func react(to message: ChatMessage, with emoji: String) {
        post("messages.react", MessageParams(message, emoji: emoji))
    }

    func edit(_ message: ChatMessage, text: String) async throws {
        try await core.call("messages.edit", MessageParams(message, text: text))
    }

    func unsend(_ message: ChatMessage) {
        post("messages.unsend", MessageParams(message))
    }

    /// A request about one message.
    private struct MessageParams: Encodable {
        let threadID: String
        let messageID: String
        var emoji: String?
        var text: String?

        init(_ message: ChatMessage, emoji: String? = nil, text: String? = nil) {
            threadID = message.threadID
            messageID = message.id
            self.emoji = emoji
            self.text = text
        }
    }

    /// Sends a request the UI doesn't wait for (its result arrives as events). A failure is in
    /// the core's log.
    private func post(_ method: String, _ params: some Encodable) {
        Task { try? await core.call(method, params) }
    }

    // MARK: - Unseen reactions

    private static let unseenReactionsKey = "UnseenReactions"

    /// Chats with reactions to your messages you haven't seen, with the newest one's time (ms).
    /// Messenger doesn't count reactions as unread and doesn't sync seeing them; the Dock badge
    /// counts them (DockBadge). Kept across launches.
    private(set) var unseenReactions: [String: Int64] =
        (UserDefaults.standard.dictionary(forKey: unseenReactionsKey) as? [String: Int64]) ?? [:] {
        didSet { UserDefaults.standard.set(unseenReactions, forKey: Self.unseenReactionsKey) }
    }

    /// Reactions older than this aren't new (e.g. they came with backfilled messages).
    private static let unseenReactionMaxAge: Int64 = 24 * 60 * 60 * 1000

    private func noteUnseenReaction(_ event: ReactionEvent) {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        guard now - event.timestamp < Self.unseenReactionMaxAge else { return }
        unseenReactions[event.threadID] = max(unseenReactions[event.threadID] ?? 0, event.timestamp)
        notify(.conversations)
    }

    /// Seen: the chat was viewed here (no `upTo`), or read anywhere at or after the reactions.
    func clearUnseenReactions(_ threadID: String, upTo timestamp: Int64 = .max) {
        guard let newest = unseenReactions[threadID], newest <= timestamp else { return }
        unseenReactions[threadID] = nil
        notify(.conversations)
    }

    func markRead(_ threadID: String) {
        markedUnread.remove(threadID)
        guard var conversation = conversationsByID[threadID], conversation.unreadCount > 0 else { return }
        conversation.unreadCount = 0
        conversationsByID[threadID] = conversation
        resortConversations()
        post("threads.markRead", ThreadParams(threadID: threadID))
    }

    func setTyping(_ isTyping: Bool, in threadID: String) {
        struct Params: Encodable { let threadID: String; let isTyping: Bool }
        post("threads.typing", Params(threadID: threadID, isTyping: isTyping))
    }

    // MARK: - Chat list actions

    private struct ToggleParams: Encodable { let threadID: String; let enabled: Bool }
    private struct ThreadParams: Encodable { let threadID: String }

    /// Chats the user marked unread: the open chat isn't marked read again until it's reopened
    /// or answered.
    private(set) var markedUnread: Set<String> = []

    func clearMarkedUnread(_ threadID: String) {
        markedUnread.remove(threadID)
    }

    /// Mark as Read / Mark as Unread (the menus).
    func toggleRead(_ conversation: Conversation) {
        if conversation.unreadCount > 0 {
            markRead(conversation.id)
        } else {
            setUnread(true, threadID: conversation.id)
        }
    }

    func setUnread(_ unread: Bool, threadID: String) {
        if unread {
            markedUnread.insert(threadID)
        } else {
            markedUnread.remove(threadID)
        }
        post("threads.setUnread", ToggleParams(threadID: threadID, enabled: unread))
    }

    func setMuted(_ muted: Bool, threadID: String) {
        post("threads.mute", ToggleParams(threadID: threadID, enabled: muted))
    }

    /// Fetches a page of a request list from Messenger (the newest, or `more`: the next one);
    /// its chats arrive as updates.
    func loadRequests(_ list: RequestList, more: Bool = false) async {
        struct Params: Encodable { let requestList: String; let more: Bool }
        try? await core.call("requests.load", Params(requestList: list.rawValue, more: more))
    }

    /// Accepts a message request: the chat moves to your chats.
    func acceptRequest(_ threadID: String) async throws {
        try await core.call("requests.accept", ThreadParams(threadID: threadID))
        // One of your chats now, right away (the core's update comes after), so selecting it
        // shows it in the chat list.
        conversationsByID[threadID]?.requestList = nil
        resortConversations()
        flushChanges()
    }

    func deleteThread(_ threadID: String) async throws {
        try await core.call("threads.delete", ThreadParams(threadID: threadID))
    }

    func leaveThread(_ threadID: String) async throws {
        try await core.call("threads.leave", ThreadParams(threadID: threadID))
    }

    func block(userID: String) async throws {
        struct Params: Encodable { let userID: String }
        try await core.call("users.block", Params(userID: userID))
    }

    /// Starts receiving the contact's online status for a 1:1 chat.
    func subscribePresence(_ threadID: String) {
        post("threads.subscribePresence", ThreadParams(threadID: threadID))
    }

    /// Files downloaded this session, by "messageID|attachmentID" (message events may predate the download).
    private var downloadedFiles: [String: URL] = [:]

    /// The attachment's local file if it's already downloaded, without downloading it.
    func downloadedFile(for attachment: Attachment, in message: ChatMessage) -> URL? {
        if let path = attachment.localPath, FileManager.default.fileExists(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        guard let url = downloadedFiles["\(message.id)|\(attachment.id)"],
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    /// Returns a local file URL for an attachment, downloading (and decrypting) it if needed.
    func localFile(for attachment: Attachment, in message: ChatMessage) async throws -> URL {
        if let url = downloadedFile(for: attachment, in: message) {
            return url
        }
        struct Params: Encodable { let threadID: String; let messageID: String; let attachmentID: String }
        struct Result: Decodable { let path: String }
        let result = try await core.call(
            "media.download",
            Params(threadID: message.threadID, messageID: message.id, attachmentID: attachment.id),
            as: Result.self
        )
        let url = URL(fileURLWithPath: result.path)
        downloadedFiles["\(message.id)|\(attachment.id)"] = url
        return url
    }

    // MARK: - Events

    private func handleEvent(_ name: String, _ payload: Data) {
        switch name {
        case "state":
            guard let event = core.decodeEvent(StateEvent.self, from: payload) else { return }
            connectionState = event.state
            if event.state == .loggedOut {
                forgetAccount()
            } else if let account = event.account {
                self.account = account
            }
            notify(.connection)

        case "thread":
            guard let conversation = core.decodeEvent(Conversation.self, from: payload) else { return }
            conversationsByID[conversation.id] = conversation
            resortConversations()

        case "threadRemoved":
            guard let event = core.decodeEvent(ThreadRemovedEvent.self, from: payload) else { return }
            conversationsByID[event.threadID] = nil
            messagesByThread[event.threadID] = nil
            resortConversations()

        case "message":
            guard let message = core.decodeEvent(ChatMessage.self, from: payload) else { return }
            upsert(message)
            messageEvents.send(message)

        case "reaction":
            guard let event = core.decodeEvent(ReactionEvent.self, from: payload) else { return }
            if Notifier.shared.isThreadVisible?(event.threadID) != true {
                noteUnseenReaction(event)
            }
            reactionEvents.send(event)

        case "threadRead":
            guard let event = core.decodeEvent(ThreadReadEvent.self, from: payload) else { return }
            clearUnseenReactions(event.threadID, upTo: event.timestamp)
            threadReadEvents.send(event)

        case "messageRemoved":
            guard let event = core.decodeEvent(MessageRemovedEvent.self, from: payload) else { return }
            messagesByThread[event.threadID]?.removeAll { $0.id == event.messageID }
            notify(.messages(threadID: event.threadID))

        case "pendingResolved":
            guard let event = core.decodeEvent(PendingResolvedEvent.self, from: payload) else { return }
            guard var list = messagesByThread[event.threadID],
                  let index = list.firstIndex(where: { $0.id == event.pendingID }) else { return }
            if event.error != nil {
                list[index].status = .failed
            } else if let messageID = event.messageID, list.contains(where: { $0.id == messageID }) {
                // The real message already arrived; drop the local echo.
                list.remove(at: index)
            }
            messagesByThread[event.threadID] = list
            notify(.messages(threadID: event.threadID))

        case "typing":
            guard let event = core.decodeEvent(TypingEvent.self, from: payload) else { return }
            setRemoteTyping(event)

        case "presence":
            guard var event = core.decodeEvent(PresenceEvent.self, from: payload) else { return }
            // Going offline without a time: keep the last time we saw them online.
            if !event.isOnline, event.lastSeen == 0, presence[event.userID]?.isOnline == true {
                event = PresenceEvent(userID: event.userID, isOnline: false,
                                      lastSeen: Int64(Date().timeIntervalSince1970 * 1000))
            } else if !event.isOnline, event.lastSeen == 0, let previous = presence[event.userID] {
                event = PresenceEvent(userID: event.userID, isOnline: false, lastSeen: previous.lastSeen)
            }
            presence[event.userID] = event
            notify(.presence(userID: event.userID))

        case "readReceipt":
            guard let event = core.decodeEvent(ReadReceiptEvent.self, from: payload),
                  var conversation = conversationsByID[event.threadID],
                  let index = conversation.participants.firstIndex(where: { $0.id == event.readerID }) else { return }
            conversation.participants[index].readWatermark = event.timestamp
            conversationsByID[event.threadID] = conversation
            notify(.messages(threadID: event.threadID))

        default:
            break
        }
    }

    private func upsert(_ message: ChatMessage) {
        // Only keep messages for threads the UI has opened; the list view only needs the snippet.
        guard var list = messagesByThread[message.threadID] else { return }
        if let index = list.firstIndex(where: { $0.id == message.id }) {
            list[index] = message
        } else {
            // A confirmed outgoing message carries the ID of its local echo; replace the echo.
            if let pendingID = message.pendingID, pendingID != message.id {
                list.removeAll { $0.id == pendingID }
            }
            let insertAt = list.lastIndex(where: { $0.timestamp <= message.timestamp }).map { $0 + 1 } ?? 0
            list.insert(message, at: insertAt)
        }
        messagesByThread[message.threadID] = list
        if message.isFromMe == false {
            clearTyping(message.senderID, in: message.threadID)
        }
        notify(.messages(threadID: message.threadID))
    }

    private func setRemoteTyping(_ event: TypingEvent) {
        let key = "\(event.threadID)|\(event.senderID)"
        typingTimers[key]?.invalidate()
        if event.isTyping {
            typing[event.threadID, default: []].insert(event.senderID)
            // Messenger doesn't always send a "stopped typing" event.
            typingTimers[key] = Timer.scheduledTimer(withTimeInterval: 8, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.clearTyping(event.senderID, in: event.threadID)
                }
            }
            notify(.typing(threadID: event.threadID))
        } else {
            clearTyping(event.senderID, in: event.threadID)
        }
    }

    private func clearTyping(_ userID: String, in threadID: String) {
        typingTimers.removeValue(forKey: "\(threadID)|\(userID)")?.invalidate()
        guard typing[threadID]?.remove(userID) != nil else { return }
        notify(.typing(threadID: threadID))
    }

    private func resortConversations() {
        conversationsDirty = true
        notify(.conversations)
    }

    /// Changes are coalesced and delivered on the next run loop pass, so a burst of
    /// sync events results in a single UI update.
    private func notify(_ change: Change) {
        if queuedChanges.isEmpty {
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated { self?.flushChanges() }
            }
        }
        if !queuedChanges.contains(change) {
            queuedChanges.append(change)
        }
    }

    private func flushChanges() {
        if conversationsDirty {
            conversationsDirty = false
            let sorted = conversationsByID.values.sorted { $0.lastActivity > $1.lastActivity }
            conversations = sorted.filter { !$0.isRequest }
            requests = sorted.filter(\.isRequest)
        }
        let pending = queuedChanges
        queuedChanges = []
        for change in pending {
            changes.send(change)
        }
    }
}
