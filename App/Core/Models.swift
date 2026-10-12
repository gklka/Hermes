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

struct ChatMessage: Codable, Identifiable, Hashable {
    enum Status: String, Codable {
        case pending, sent, delivered, read, failed
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

struct ThreadRemovedEvent: Decodable {
    let threadID: String
}

struct TypingEvent: Decodable {
    let threadID: String
    let senderID: String
    let isTyping: Bool
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
