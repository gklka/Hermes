import Foundation

/// Mirrors the JSON shapes emitted by the Go core (Core/api.go).

struct Participant: Codable, Hashable {
    let id: String
    var name: String
    var avatarURL: String?
    /// Last message timestamp (ms) this participant has read.
    var readWatermark: Int64?
}

struct Conversation: Codable, Identifiable, Hashable {
    let id: String
    var name: String
    var avatarURL: String?
    var snippet: String
    var snippetSenderID: String?
    /// Milliseconds since epoch.
    var lastActivity: Int64
    var unreadCount: Int
    var isGroup: Bool
    var isEncrypted: Bool
    var isMuted: Bool
    var isMarketplace: Bool
    var participants: [Participant]
    /// The chat's custom Messenger theme for outgoing bubbles: one color, or several for a
    /// gradient (top to bottom of the visible chat). Nil for the default theme.
    var bubbleColors: [String]?
    /// The chat's custom quick reaction emoji (the like button). Nil for the default like.
    var quickEmoji: String?

    var lastActivityDate: Date { Date(timeIntervalSince1970: TimeInterval(lastActivity) / 1000) }
}

struct Reaction: Codable, Hashable {
    let senderID: String
    let emoji: String
}

struct ReplyPreview: Codable, Hashable {
    let messageID: String
    let senderID: String?
    let text: String
}

struct Attachment: Codable, Hashable {
    enum Kind: String, Codable {
        case image, gif, video, audio, sticker, file, link
    }

    let id: String
    let kind: Kind
    var url: String?
    var previewURL: String?
    var localPath: String?
    var width: Int?
    var height: Int?
    var filename: String?
    var mimeType: String?
    var title: String?
}

extension Attachment.Kind {
    /// What an attachment of this kind is called, where it has no name of its own.
    var label: String {
        switch self {
        case .image: "Photo"
        case .gif: "GIF"
        case .sticker: "Sticker"
        case .video: "Video"
        case .audio: "Voice Message"
        case .file: "File"
        case .link: "Link"
        }
    }
}

struct ChatMessage: Codable, Identifiable, Hashable {
    enum Status: String, Codable {
        /// Sent here, not confirmed by the server yet (a local echo).
        case pending
        case sent
        /// Set by the app when the send request fails.
        case failed
    }

    let id: String
    let threadID: String
    let senderID: String
    let isFromMe: Bool
    /// Admin/system notices ("X named the group…"), shown centered without a bubble.
    let isSystem: Bool
    var text: String
    /// Milliseconds since epoch.
    let timestamp: Int64
    var attachments: [Attachment]
    var replyTo: ReplyPreview?
    var reactions: [Reaction]
    var status: Status
    var isUnsent: Bool
    var isEdited: Bool
    /// Earlier versions of an edited message (oldest first), as far as the app saw them.
    var previousTexts: [String]?
    /// Set for messages created locally before the server echoed them back.
    var pendingID: String?

    var date: Date { Date(timeIntervalSince1970: TimeInterval(timestamp) / 1000) }
}

struct Account: Codable, Hashable {
    let id: String
    let name: String
    var avatarURL: String?
}

enum ConnectionState: String, Codable {
    case loggedOut, connecting, connected, disconnected
}

// MARK: - Event payloads

struct StateEvent: Decodable {
    let state: ConnectionState
    let account: Account?
    let error: String?
}

struct MessageRemovedEvent: Decodable {
    let threadID: String
    let messageID: String
}

/// messages.fetchOlder's result (apiFetchOlderResult): one page of history from Messenger.
struct FetchOlderResult: Decodable {
    let fetched: Int
    let hasMore: Bool
}

/// The chat was read up to `timestamp`, here or on another device (apiThreadReadEvent).
struct ThreadReadEvent: Decodable {
    let threadID: String
    /// Milliseconds since epoch.
    let timestamp: Int64
}

/// Someone else reacted to one of your messages (apiReactionEvent), for a notification.
struct ReactionEvent: Decodable {
    let threadID: String
    let messageID: String
    let senderID: String
    let emoji: String
    /// Milliseconds since epoch.
    let timestamp: Int64
    let messageText: String
}

struct ThreadRemovedEvent: Decodable {
    let threadID: String
}

struct TypingEvent: Decodable {
    let threadID: String
    let senderID: String
    let isTyping: Bool
}

struct PresenceEvent: Decodable {
    let userID: String
    let isOnline: Bool
    /// Milliseconds since 1970; 0 if the contact hides it.
    let lastSeen: Int64
}

struct ReadReceiptEvent: Decodable {
    let threadID: String
    let readerID: String
    let timestamp: Int64
}

struct PendingResolvedEvent: Decodable {
    let threadID: String
    let pendingID: String
    let messageID: String?
    let error: String?
}

struct MessagesPage: Decodable {
    let messages: [ChatMessage]
    let hasMore: Bool
}
