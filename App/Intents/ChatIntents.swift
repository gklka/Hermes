import AppIntents
import AppKit

// Shortcuts actions that take a chat. The schema intents (MessagingIntents.swift) pick a
// message, which is awkward to choose by hand; these act on the chat or your last message in it.

@available(macOS 27.0, *)
struct SendToChatIntent: AppIntent {
    static let title: LocalizedStringResource = "Send Message to Chat"
    static let description = IntentDescription("Sends a message, and any files, to a chat.")

    @Parameter(title: "Chat")
    var chat: ConversationEntity

    @Parameter(title: "Message", inputOptions: String.IntentInputOptions(multiline: true))
    var text: String

    @Parameter(title: "Files", default: [])
    var files: [IntentFile]

    static var parameterSummary: some ParameterSummary {
        Summary("Send \(\.$text) to \(\.$chat)") {
            \.$files
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        try await IntentSupport.ready()
        let attachments = try files.map(IntentSupport.save)
        guard !text.isEmpty || !attachments.isEmpty else {
            throw MessagingIntentError.unsupported("There's nothing to send.")
        }
        ChatStore.shared.send(text: text, attachments: attachments, in: chat.id)
        return .result()
    }
}

@available(macOS 27.0, *)
struct EditLastMessageIntent: AppIntent {
    static let title: LocalizedStringResource = "Edit Last Message"
    static let description = IntentDescription("Edits the last message you sent in a chat.")

    @Parameter(title: "Chat")
    var chat: ConversationEntity

    @Parameter(title: "New Text", inputOptions: String.IntentInputOptions(multiline: true))
    var text: String

    static var parameterSummary: some ParameterSummary {
        Summary("Edit my last message in \(\.$chat) to say \(\.$text)")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        try await IntentSupport.ready()
        let message = try await IntentSupport.lastOwnMessage(in: chat.id)
        try await ChatStore.shared.edit(message, text: text)
        return .result()
    }
}

@available(macOS 27.0, *)
struct UnsendLastMessageIntent: AppIntent {
    static let title: LocalizedStringResource = "Unsend Last Message"
    static let description = IntentDescription("Unsends the last message you sent in a chat.")

    @Parameter(title: "Chat")
    var chat: ConversationEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Unsend my last message in \(\.$chat)")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        try await IntentSupport.ready()
        ChatStore.shared.unsend(try await IntentSupport.lastOwnMessage(in: chat.id))
        return .result()
    }
}

@available(macOS 27.0, *)
struct MarkChatIntent: AppIntent {
    static let title: LocalizedStringResource = "Mark Chat as Read or Unread"
    static let description = IntentDescription("Marks a chat as read or unread.")

    @Parameter(title: "Chat")
    var chat: ConversationEntity

    @Parameter(title: "Read", default: true, displayName: Bool.IntentDisplayName(true: "Read", false: "Unread"))
    var isRead: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("Mark \(\.$chat) as \(\.$isRead)")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        try await IntentSupport.ready()
        if isRead {
            ChatStore.shared.markRead(chat.id)
        } else {
            ChatStore.shared.setUnread(true, threadID: chat.id)
        }
        return .result()
    }
}

/// Ready-made shortcuts, which also give the app its own entry in Shortcuts.
@available(macOS 27.0, *)
struct MessengerShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: SendToChatIntent(),
            phrases: ["Send a message with \(.applicationName)", "Send a \(.applicationName) message"],
            shortTitle: "Send to Chat",
            systemImageName: "paperplane"
        )
        AppShortcut(
            intent: MarkChatIntent(),
            phrases: ["Mark a chat read in \(.applicationName)"],
            shortTitle: "Mark Chat",
            systemImageName: "checkmark.message"
        )
    }
}

@available(macOS 27.0, *)
extension IntentSupport {
    /// Your last message in the chat that can still be edited or unsent.
    static func lastOwnMessage(in threadID: String) async throws -> ChatMessage {
        await ChatStore.shared.openThread(threadID)
        guard let message = ChatStore.shared.messages(in: threadID).last(where: { $0.isFromMe && !$0.isUnsent }) else {
            throw MessagingIntentError.unsupported("You haven't sent a message in this chat.")
        }
        return message
    }
}
