import Foundation

/// Mirrors the JSON shapes emitted by the Go core (Core/api.go).

struct Participant: Codable, Hashable {
    let id: String
    var name: String
    var avatarURL: String?
    /// Last message timestamp (ms) this participant has read.
    var readWatermark: Int64?
    /// What Messenger's people search says about someone ("Friends", a mutual friend).
    var detail: String?
}

struct Conversation: Codable, Identifiable, Hashable {
    let id: String
    var name: String
    var avatarURL: String?
    var snippet: String
    var snippetSenderID: String?
    /// The latest message was unsent by `snippetSenderID` (so there's no snippet text).
    var snippetUnsent: Bool?
    /// Milliseconds since epoch.
    var lastActivity: Int64
    var unreadCount: Int
    var isGroup: Bool
    var isEncrypted: Bool
    var isMuted: Bool
    var isMarketplace: Bool
    /// For a message request (someone you're not connected with wrote; ChatStore.requests),
    /// the list it's in.
    var requestList: RequestList?
    var participants: [Participant]
    /// The chat's custom Messenger theme for outgoing bubbles: one color, or several for a
    /// gradient (top to bottom of the visible chat). Nil for the default theme.
    var bubbleColors: [String]?
    /// The chat's custom quick reaction emoji (the like button). Nil for the default like.
    var quickEmoji: String?

    var lastActivityDate: Date { Date(timeIntervalSince1970: TimeInterval(lastActivity) / 1000) }

    var isRequest: Bool { requestList != nil }
}

/// Messenger's two lists of message requests (the tabs of its Requests page).
enum RequestList: String, Codable, CaseIterable {
    case mayKnow, spam

    var title: String {
        switch self {
        case .mayKnow: "You May Know"
        case .spam: "Spam"
        }
    }
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
        /// A call in the chat (the message's sender called); see `call`.
        case call
        /// A poll (see `poll`), on the system message saying it was created. Messages about
        /// changes to it have one too, without options (only the first message shows the poll).
        case poll
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
    var call: Call?
    var poll: Poll?

    struct Call: Codable, Hashable {
        enum Outcome: String, Codable {
            /// Ringing or going on.
            case started, ended, missed
        }

        let isVideo: Bool
        let outcome: Outcome
        /// Seconds, when known (encrypted chats).
        var duration: Int?
        /// Messenger's own wording of the duration ("9 perc"), in regular chats.
        var durationText: String?
    }
}

/// A group chat's poll (apiPoll).
struct Poll: Codable, Hashable {
    let id: String
    var question: String?
    /// In the order they were added. The card only knows the first three until the votes are synced; then
    /// `moreCount` is how many more there are.
    var options: [Option]
    var moreCount: Int?
    /// Messenger's own wording of the card's button ("Vote", "Change vote"), for when the votes
    /// aren't known here.
    var buttonTitle: String?
    /// The votes are known here (the options have IDs, counts and voters).
    var isComplete: Bool?

    struct Option: Codable, Hashable {
        let id: String
        var text: String
        var voteCount: Int
        /// The share of the chat's members who voted for it.
        var percent: Int
        var voted: Bool?
        /// Who voted for it; the card may only have their pictures.
        var voters: [Participant]
    }

    var hasVoted: Bool { options.contains { $0.voted == true } }
}

/// An option added while voting (apiNewPollOption), and whether you vote for it.
struct NewPollOption: Codable, Hashable {
    let text: String
    let voted: Bool
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
        case .call: "Call"
        case .poll: "Poll"
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
    /// People (or @everyone) tagged in the text.
    var mentions: [Mention]?

    var date: Date { Date(timeIntervalSince1970: TimeInterval(timestamp) / 1000) }
}

/// A tag in a message's text ("@Anna"), apiMention. The range counts UTF-16 code units (NSString's).
struct Mention: Codable, Hashable {
    let offset: Int
    let length: Int
    /// The person tagged; nil for the whole chat (@everyone).
    let userID: String?

    var range: NSRange { NSRange(location: offset, length: length) }
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
