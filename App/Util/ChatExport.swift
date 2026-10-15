import AppKit

/// File → Export Chat: a Markdown transcript of everything stored for the chat (not just
/// what's loaded): day headings, sender and time, replies, attachments (linked to the
/// downloaded files), links, reactions, edits and unsent messages.
enum ChatExport {
    /// Asks where to save, then writes the transcript.
    static func run(threadID: String, in window: NSWindow?) {
        let store = ChatStore.shared
        guard let conversation = store.conversation(threadID) else { return }
        Task {
            let messages = await store.storedMessages(in: threadID, limit: 1_000_000)
            let markdown = transcript(of: conversation, messages: messages)
            let panel = NSSavePanel()
            panel.nameFieldStringValue = "\(fileName(conversation.name)).md"
            panel.allowedContentTypes = [.init(filenameExtension: "md") ?? .plainText]
            panel.canCreateDirectories = true
            let save = { (response: NSApplication.ModalResponse) in
                guard response == .OK, let url = panel.url else { return }
                do {
                    try markdown.write(to: url, atomically: true, encoding: .utf8)
                } catch {
                    NSAlert(error: error).runModal()
                }
            }
            if let window {
                panel.beginSheetModal(for: window, completionHandler: save)
            } else {
                save(panel.runModal())
            }
        }
    }

    private static func fileName(_ name: String) -> String {
        let cleaned = name.components(separatedBy: CharacterSet(charactersIn: "/:\\")).joined(separator: "-")
        return cleaned.isEmpty ? "Chat" : cleaned
    }

    // MARK: - Markdown

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .full
        f.timeStyle = .none
        return f
    }()

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        return f
    }()

    private static let rangeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()

    static func transcript(of conversation: Conversation, messages: [ChatMessage]) -> String {
        let store = ChatStore.shared
        let myName = store.account?.name ?? "Me"
        func name(_ senderID: String?, isFromMe: Bool = false) -> String {
            if isFromMe || senderID == store.account?.id { return myName }
            guard let senderID else { return "Unknown" }
            if let participant = store.participant(senderID, in: conversation.id), !participant.name.isEmpty {
                return participant.name
            }
            return conversation.isGroup ? "Unknown" : conversation.name
        }
        let byID = Dictionary(messages.map { ($0.id, $0) }, uniquingKeysWith: { $1 })

        var lines: [String] = ["# \(escapeInline(conversation.name))", ""]
        var summary = "Exported from Hermes on \(Formatters.exact(Date())) · \(messages.count) messages"
        if let first = messages.first, let last = messages.last {
            summary += " · \(rangeFormatter.string(from: first.date)) – \(rangeFormatter.string(from: last.date))"
        }
        lines += [summary, ""]
        if conversation.isGroup {
            let members = conversation.participants.map(\.name).filter { !$0.isEmpty }
            lines += ["Members: \(members.map { escapeInline($0) }.joined(separator: ", "))", ""]
        }

        var day: String?
        for message in messages {
            let messageDay = dayFormatter.string(from: message.date)
            if messageDay != day {
                day = messageDay
                lines += ["## \(messageDay)", ""]
            }
            let time = timeFormatter.string(from: message.date)
            if message.isSystem {
                lines += ["*\(escapeInline(message.text)) (\(time))*", ""]
                continue
            }
            var header = "**\(escapeInline(name(message.senderID, isFromMe: message.isFromMe)))** · \(time)"
            if message.isEdited { header += " · edited" }
            var body: [String] = [header]
            if message.isUnsent {
                body.append("*Unsent a message*")
            } else {
                if let reply = message.replyTo {
                    let quoted = byID[reply.messageID]?.text ?? reply.text
                    let firstLine = quoted.split(separator: "\n").first.map(String.init) ?? quoted
                    body.append("> **\(escapeInline(name(reply.senderID))):** \(escapeInline(firstLine))")
                }
                if !message.text.isEmpty {
                    body += message.text.components(separatedBy: "\n").map { escapeLine($0) }
                }
                body += message.attachments.map { attachmentLine($0) }
                if !message.reactions.isEmpty {
                    let reactions = message.reactions.map { "\($0.emoji) \(escapeInline(name($0.senderID)))" }
                    body.append("Reactions: \(reactions.joined(separator: ", "))")
                }
            }
            // Two trailing spaces: a line break within the message.
            lines.append(body.joined(separator: "  \n"))
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    private static func attachmentLine(_ attachment: Attachment) -> String {
        if attachment.kind == .link {
            let url = attachment.url ?? ""
            let title = attachment.title ?? url
            return url.isEmpty ? "🔗 \(escapeInline(title))" : "🔗 [\(escapeInline(title))](<\(url)>)"
        }
        let label = attachment.kind.label
        let name = attachment.filename ?? attachment.localPath.map { URL(fileURLWithPath: $0).lastPathComponent }
        let text = name.map { "\(label): \(escapeInline($0))" } ?? label
        // The downloaded copy, if there is one.
        if let path = attachment.localPath {
            return "📎 [\(text)](<\(URL(fileURLWithPath: path).absoluteString)>)"
        }
        return "📎 \(text)"
    }

    /// Keeps a line of message text from turning into a heading, quote, list or rule.
    private static func escapeLine(_ line: String) -> String {
        let escaped = escapeInline(line)
        let trimmed = escaped.drop { $0 == " " }
        if let first = trimmed.first, "#>-+*=|".contains(first) {
            return "\\" + escaped
        }
        if trimmed.first?.isNumber == true, trimmed.drop(while: { $0.isNumber }).hasPrefix(". ") {
            return "\\" + escaped
        }
        return escaped
    }

    /// Markdown's emphasis and code characters, so they show as typed.
    private static func escapeInline(_ text: String) -> String {
        var out = ""
        for character in text {
            if "\\`*_[]".contains(character) { out.append("\\") }
            out.append(character)
        }
        return out
    }
}
