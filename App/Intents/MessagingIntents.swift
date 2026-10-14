import AppIntents
import AppKit
import CoreSpotlight
import GeoToolbox
import LinkPresentation

// Chats, people and messages as App Intents entities (the macOS 27 "messages" schema), for the
// Shortcuts actions (ChatIntents.swift) and the messages in Spotlight (SpotlightIndex). The
// schema's Siri intents were dropped: Siri couldn't hand them a recipient (macOS 27.1).

// MARK: - Entities

@available(macOS 27.0, *)
@AppEntity(schema: .messages.messagePerson)
struct MessagePersonEntity {
    static let defaultQuery = MessagePersonQuery()

    /// The Facebook user ID.
    let id: String
    var person: IntentPerson

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(person.displayName)")
    }

    @MainActor
    init(_ participant: Participant) {
        id = participant.id
        person = IntentPerson(
            identifier: .applicationDefined(participant.id),
            name: .displayName(participant.name),
            handle: IntentPerson.Handle(.applicationDefined(participant.id)),
            isMe: participant.id == ChatStore.shared.account?.id
        )
    }

    struct MessagePersonQuery: EntityStringQuery {
        @MainActor
        func entities(for identifiers: [MessagePersonEntity.ID]) async throws -> [MessagePersonEntity] {
            try await IntentSupport.ready()
            let known = IntentSupport.knownPeople()
            return identifiers.compactMap { id in known[id].map(MessagePersonEntity.init) }
        }

        @MainActor
        func entities(matching string: String) async throws -> [MessagePersonEntity] {
            try await IntentSupport.ready()
            return await ChatStore.shared.searchContacts(string).map(MessagePersonEntity.init)
        }

        /// People from the most recent one-to-one chats.
        @MainActor
        func suggestedEntities() async throws -> [MessagePersonEntity] {
            try await IntentSupport.ready()
            let selfID = ChatStore.shared.account?.id
            return ChatStore.shared.conversations.filter { !$0.isGroup }.prefix(20)
                .compactMap { $0.participants.first { $0.id != selfID } }
                .map(MessagePersonEntity.init)
        }
    }
}

@available(macOS 27.0, *)
@AppEntity(schema: .messages.conversation)
struct ConversationEntity {
    static let defaultQuery = ConversationEntityQuery()

    /// The chat's thread ID.
    let id: String
    var recipients: [MessagePersonEntity]
    var displayName: String
    var previewText: AttributedString
    var conversationName: String?
    var isRead: Bool
    var attributes: Set<ConversationAttribute>
    var dateLastActive: Date?

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(displayName)", subtitle: "\(String(previewText.characters))")
    }

    @MainActor
    init(_ conversation: Conversation) {
        let selfID = ChatStore.shared.account?.id
        id = conversation.id
        recipients = conversation.participants.filter { $0.id != selfID }.map(MessagePersonEntity.init)
        displayName = conversation.name
        previewText = AttributedString(conversation.snippet)
        conversationName = conversation.isGroup ? conversation.name : nil
        isRead = conversation.unreadCount == 0
        var attributes: Set<ConversationAttribute> = []
        if conversation.isGroup { attributes.insert(.group) }
        if conversation.isMuted { attributes.insert(.muted) }
        if conversation.isEncrypted { attributes.insert(.encrypted) }
        self.attributes = attributes
        dateLastActive = conversation.lastActivityDate
    }

    struct ConversationEntityQuery: EntityStringQuery {
        @MainActor
        func entities(for identifiers: [ConversationEntity.ID]) async throws -> [ConversationEntity] {
            try await IntentSupport.ready()
            return identifiers.compactMap { ChatStore.shared.conversation($0).map(ConversationEntity.init) }
        }

        @MainActor
        func entities(matching string: String) async throws -> [ConversationEntity] {
            try await IntentSupport.ready()
            return ChatStore.shared.conversations
                .filter { $0.name.range(of: string, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
                .map(ConversationEntity.init)
        }

        @MainActor
        func suggestedEntities() async throws -> [ConversationEntity] {
            try await IntentSupport.ready()
            return ChatStore.shared.conversations.prefix(20).map(ConversationEntity.init)
        }
    }
}

@available(macOS 27.0, *)
@AppEntity(schema: .messages.message)
struct MessageEntity {
    static let defaultQuery = MessageEntityQuery()

    /// "<thread ID>|<message ID>": looking a message up needs its chat.
    let id: String
    var messageType: MessageType
    var author: MessagePersonEntity
    var isRead: Bool
    var attributes: Set<MessageAttribute>
    var conversation: ConversationEntity
    var date: Date
    var subject: AttributedString?
    var body: AttributedString?
    var attachments: [IntentFile]
    var audioMessage: IntentFile?
    var customAttachments: [CustomAttachmentEntity]
    var locations: [GeoToolbox.PlaceDescriptor]
    var links: [LinkPresentation.LinkMetadata]
    var messageEffect: MessageEffect?
    var reaction: ReadReaction?
    var referencedMessage: MessageEntity?
    var notificationIdentifier: String?

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(String(body?.characters ?? AttributedString().characters))",
                              subtitle: "\(conversation.displayName)")
    }

    @MainActor
    init(_ message: ChatMessage, in conversation: Conversation) {
        let store = ChatStore.shared
        id = "\(message.threadID)|\(message.id)"
        messageType = .unspecified
        let name = message.isFromMe ? (store.account?.name ?? "Me") : store.participantName(message.senderID, in: message.threadID)
        author = MessagePersonEntity(Participant(id: message.senderID, name: name))
        isRead = message.isFromMe || conversation.unreadCount == 0 || message.timestamp <= conversation.lastActivity - 1
        var attributes: Set<MessageAttribute> = []
        if message.isFromMe { attributes.insert(.sent) }
        if message.isEdited { attributes.insert(.edited) }
        if message.isUnsent { attributes.insert(.unsent) }
        self.attributes = attributes
        self.conversation = ConversationEntity(conversation)
        date = message.date
        subject = nil
        body = message.text.isEmpty ? nil : AttributedString(message.text)
        attachments = []
        audioMessage = nil
        customAttachments = []
        locations = []
        links = []
        messageEffect = nil
        reaction = message.reactions.first { $0.senderID == store.account?.id }
            .map { ReadReaction.attributedString(AttributedString($0.emoji)) }
        referencedMessage = nil
        notificationIdentifier = nil
    }

    struct MessageEntityQuery: EntityStringQuery {
        @MainActor
        func entities(for identifiers: [MessageEntity.ID]) async throws -> [MessageEntity] {
            try await IntentSupport.ready()
            var result: [MessageEntity] = []
            for identifier in identifiers {
                if let (message, conversation) = await IntentSupport.message(identifier) {
                    result.append(MessageEntity(message, in: conversation))
                }
            }
            return result
        }

        /// Messages containing the text, newest first, in the chats opened so far.
        @MainActor
        func entities(matching string: String) async throws -> [MessageEntity] {
            try await IntentSupport.ready()
            let store = ChatStore.shared
            var result: [MessageEntity] = []
            for conversation in store.conversations {
                for message in store.messages(in: conversation.id).reversed()
                where message.text.range(of: string, options: [.caseInsensitive, .diacriticInsensitive]) != nil {
                    result.append(MessageEntity(message, in: conversation))
                }
            }
            return Array(result.sorted { $0.date > $1.date }.prefix(50))
        }

        /// Your latest messages, the likeliest to edit or unsend.
        @MainActor
        func suggestedEntities() async throws -> [MessageEntity] {
            try await IntentSupport.ready()
            let store = ChatStore.shared
            var result: [MessageEntity] = []
            for conversation in store.conversations.prefix(10) {
                if let message = store.messages(in: conversation.id).last(where: { $0.isFromMe && !$0.isUnsent }) {
                    result.append(MessageEntity(message, in: conversation))
                }
            }
            return result
        }
    }
}

@available(macOS 27.0, *)
@AppEntity(schema: .messages.customAttachment)
struct CustomAttachmentEntity {
    static let defaultQuery = CustomAttachmentQuery()

    let id: String
    var sourceName: AttributedString?
    var description: AttributedString?

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(String(description?.characters ?? AttributedString().characters))")
    }

    /// Messenger has no custom attachments to offer.
    struct CustomAttachmentQuery: EntityQuery {
        func entities(for identifiers: [CustomAttachmentEntity.ID]) async throws -> [CustomAttachmentEntity] { [] }
    }
}

/// Only so SpotlightIndex can delete the entities an earlier build indexed.
@available(macOS 27.0, *)
extension MessagePersonEntity: IndexedEntity {
    var attributeSet: CSSearchableItemAttributeSet {
        let attributes = defaultAttributeSet
        attributes.displayName = person.displayName
        attributes.title = person.displayName
        return attributes
    }
}

@available(macOS 27.0, *)
extension ConversationEntity: IndexedEntity {
    var attributeSet: CSSearchableItemAttributeSet {
        let attributes = defaultAttributeSet
        attributes.displayName = displayName
        attributes.title = displayName
        return attributes
    }
}

/// Messages are in Spotlight (SpotlightIndex), for Siri and search.
@available(macOS 27.0, *)
extension MessageEntity: IndexedEntity {
    var attributeSet: CSSearchableItemAttributeSet {
        let attributes = defaultAttributeSet
        let text = String(body?.characters ?? AttributedString().characters)
        attributes.title = conversation.displayName
        attributes.displayName = conversation.displayName
        attributes.contentDescription = text
        attributes.textContent = text
        // No authorNames: Spotlight's results view crashed (macOS 27.1) on messages whose author
        // matched someone in Contacts.
        attributes.contentCreationDate = date
        return attributes
    }
}

// MARK: - Enums and unions

@available(macOS 27.0, *)
@AppEnum(schema: .messages.conversationAttribute)
enum ConversationAttribute: String {
    case group, muted, encrypted

    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .group: "Group", .muted: "Muted", .encrypted: "End-to-end encrypted",
    ]
}

@available(macOS 27.0, *)
@AppEnum(schema: .messages.messageAttribute)
enum MessageAttribute: String {
    case sent, edited, unsent

    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .sent: "Sent by me", .edited: "Edited", .unsent: "Unsent",
    ]
}

@available(macOS 27.0, *)
@AppEnum(schema: .messages.messageType)
enum MessageType: String {
    case unspecified

    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .unspecified: "Unspecified",
    ]
}

/// Messenger has no message effects; the schema needs at least one case.
@available(macOS 27.0, *)
@AppEnum(schema: .messages.messageEffect)
enum MessageEffect: String {
    case none

    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .none: "None",
    ]
}

/// Messenger's standard reactions.
@available(macOS 27.0, *)
@AppEnum(schema: .messages.customReaction)
enum Tapback: String {
    case love, haha, wow, sad, angry, like

    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .love: "❤️", .haha: "😆", .wow: "😮", .sad: "😢", .angry: "😠", .like: "👍",
    ]
}

@available(macOS 27.0, *)
@UnionValue
enum ReadReaction {
    case customReaction(Tapback)
    case attributedString(AttributedString)
}

// MARK: - Support

@available(macOS 27.0, *)
enum MessagingIntentError: Error, CustomLocalizedStringResourceConvertible {
    case notReady
    case unsupported(String)

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .notReady: "MessengerMac isn't logged in."
        case .unsupported(let reason): "\(reason)"
        }
    }
}

@available(macOS 27.0, *)
@MainActor
enum IntentSupport {
    private static var store: ChatStore { .shared }

    /// Waits for the app to be logged in with its chats loaded (it may just have been launched
    /// to run the intent).
    static func ready() async throws {
        for _ in 0..<60 where store.account == nil || store.conversations.isEmpty {
            try await Task.sleep(for: .milliseconds(500))
        }
        guard store.account != nil else { throw MessagingIntentError.notReady }
    }

    /// Everyone in the loaded chats, by ID.
    static func knownPeople() -> [String: Participant] {
        var people: [String: Participant] = [:]
        for conversation in store.conversations {
            for participant in conversation.participants where people[participant.id] == nil {
                people[participant.id] = participant
            }
        }
        return people
    }

    /// A message by its entity ID ("<thread ID>|<message ID>"), loading its chat if needed.
    static func message(_ identifier: String) async -> (ChatMessage, Conversation)? {
        let parts = identifier.split(separator: "|", maxSplits: 1).map(String.init)
        guard parts.count == 2, let conversation = store.conversation(parts[0]) else { return nil }
        await store.openThread(parts[0])
        guard let message = store.messages(in: parts[0]).first(where: { $0.id == parts[1] }) else { return nil }
        return (message, conversation)
    }

    /// Copies a file the intent was given into the outgoing folder, like a pasted file.
    static func save(_ file: IntentFile) throws -> URL {
        let url = OutgoingMedia.newSlot().appendingPathComponent(file.filename.isEmpty ? "Attachment" : file.filename)
        try file.data.write(to: url)
        return url
    }
}

@available(macOS 27.0, *)
extension IntentPerson {
    var displayName: String {
        switch name {
        case .displayName(let name): name
        case .components(let components): PersonNameComponentsFormatter().string(from: components)
        case .unknown: "Unknown"
        @unknown default: "Unknown"
        }
    }
}
