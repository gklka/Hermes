import AppKit
import Combine
import Intents
import Security
import UserNotifications

/// Posts a notification for each new incoming message, with the sender's profile picture.
/// The picture is shown as the notification's avatar (a communication notification, like
/// Messages) when the system allows it, otherwise as an image attachment. (macOS has no API for
/// a group picture, so group notifications show the sender.)
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()

    /// Set by the chat view: true while the given chat is on screen in the active window.
    var isThreadVisible: ((String) -> Bool)?
    /// Called when a notification is clicked, with its chat and message.
    var onOpenThread: ((_ threadID: String, _ messageID: String?) -> Void)?

    private let center = UNUserNotificationCenter.current()
    private let store = ChatStore.shared
    private let launchTime = Date()
    private var notifiedIDs: Set<String> = []
    private var cancellables: Set<AnyCancellable> = []

    /// Messages older than this aren't new (they're backfill or history imports).
    private static let maxAge: TimeInterval = 5 * 60

    func start() {
        center.delegate = self
        Task {
            do {
                let granted = try await center.requestAuthorization(options: [.alert, .sound, .badge])
                CoreBridge.shared.log("Notifier: authorization granted: \(granted)")
            } catch {
                CoreBridge.shared.log("Notifier: authorization failed: \(error)")
            }
        }
        store.messageEvents
            .sink { [weak self] message in self?.handle(message) }
            .store(in: &cancellables)
    }

    /// Removes the chat's notifications from Notification Center (e.g. once it's opened).
    func clear(threadID: String) {
        Task {
            let ids = await center.deliveredNotifications()
                .filter { $0.request.content.threadIdentifier == threadID }
                .map(\.request.identifier)
            if !ids.isEmpty {
                center.removeDeliveredNotifications(withIdentifiers: ids)
            }
        }
    }

    /// Dev hook (WebDOMInspector): two notifications in each of two fake chats, to check grouping.
    func postTest() {
        Task {
            for (index, thread) in ["test-chat-a", "test-chat-a", "test-chat-b", "test-chat-b"].enumerated() {
                let content = UNMutableNotificationContent()
                content.title = thread
                content.body = "Test message \(index + 1)"
                content.threadIdentifier = thread
                try? await center.add(UNNotificationRequest(identifier: "test-\(index)", content: content, trigger: nil))
            }
        }
    }

    // MARK: - Posting

    private func handle(_ message: ChatMessage) {
        guard !message.isFromMe, !message.isSystem, !message.isUnsent, message.pendingID == nil else { return }
        // Only new messages: not ones that arrived before launch or are being backfilled.
        let date = message.date
        guard date > launchTime.addingTimeInterval(-30), Date().timeIntervalSince(date) < Self.maxAge else { return }
        // Edits and other updates re-send the same message.
        guard notifiedIDs.insert(message.id).inserted else { return }
        let conversation = store.conversation(message.threadID)
        if conversation?.isMuted == true || isThreadVisible?(message.threadID) == true { return }
        Task { await post(message, in: conversation) }
    }

    private func post(_ message: ChatMessage, in conversation: Conversation?) async {
        let isGroup = conversation?.isGroup ?? false
        let sender = store.participant(message.senderID, in: message.threadID)
        let senderName = sender?.name ?? conversation?.name ?? "Messenger"
        let body = Self.body(for: message)

        let content = UNMutableNotificationContent()
        content.title = isGroup ? (conversation?.name ?? senderName) : senderName
        content.subtitle = isGroup ? senderName : ""
        content.body = body
        content.sound = .default
        content.threadIdentifier = message.threadID
        content.userInfo = ["threadID": message.threadID, "messageID": message.id]

        let avatarURL = sender?.avatarURL ?? (isGroup ? nil : conversation?.avatarURL)
        let avatar = await Self.pngData(from: avatarURL)

        var finalContent: UNNotificationContent = content
        do {
            guard Self.canUseCommunicationNotifications else { throw NotifierError.noCommunicationEntitlement }
            finalContent = try await communicationContent(
                content, message: message, senderName: senderName, body: body,
                avatar: avatar, groupName: isGroup ? conversation?.name : nil
            )
        } catch {
            if !(error is NotifierError) {
                CoreBridge.shared.log("Notifier: no communication notification (\(error)); attaching the picture instead")
            }
            if let avatar, let attachment = Self.attachment(avatar) {
                content.attachments = [attachment]
            }
        }

        let request = UNNotificationRequest(identifier: message.id, content: finalContent, trigger: nil)
        do {
            try await center.add(request)
        } catch {
            CoreBridge.shared.log("Notifier: posting failed: \(error)")
        }
    }

    private enum NotifierError: Error {
        case noCommunicationEntitlement
    }

    /// Communication notifications need an entitlement that requires a provisioning profile.
    /// With the current ad-hoc signing it's absent, and the picture is attached instead.
    private static let canUseCommunicationNotifications: Bool = {
        guard let task = SecTaskCreateFromSelf(nil) else { return false }
        let value = SecTaskCopyValueForEntitlement(task, "com.apple.developer.usernotifications.communication" as CFString, nil)
        return (value as? Bool) == true
    }()

    /// Turns the content into a communication notification: the system shows the sender's
    /// picture as the notification's icon (and the group's name and picture for groups).
    private func communicationContent(
        _ content: UNMutableNotificationContent, message: ChatMessage, senderName: String, body: String,
        avatar: Data?, groupName: String?
    ) async throws -> UNNotificationContent {
        let person = INPerson(
            personHandle: INPersonHandle(value: message.senderID, type: .unknown),
            nameComponents: nil,
            displayName: senderName,
            image: avatar.map { INImage(imageData: $0) },
            contactIdentifier: nil,
            customIdentifier: message.senderID
        )
        // A group needs its other members as recipients to be shown as a group.
        var recipients: [INPerson]?
        if groupName != nil, let conversation = store.conversation(message.threadID) {
            recipients = conversation.participants.filter { $0.id != message.senderID }.map {
                INPerson(
                    personHandle: INPersonHandle(value: $0.id, type: .unknown), nameComponents: nil,
                    displayName: $0.name, image: nil, contactIdentifier: nil, customIdentifier: $0.id
                )
            }
        }
        let intent = INSendMessageIntent(
            recipients: recipients,
            outgoingMessageType: .outgoingMessageText,
            content: body,
            speakableGroupName: groupName.map { INSpeakableString(spokenPhrase: $0) },
            conversationIdentifier: message.threadID,
            serviceName: nil,
            sender: person,
            attachments: nil
        )
        let interaction = INInteraction(intent: intent, response: nil)
        interaction.direction = .incoming
        try await interaction.donate()
        return try content.updating(from: intent)
    }

    private static func body(for message: ChatMessage) -> String {
        if !message.text.isEmpty { return message.text }
        guard let first = message.attachments.first else { return "Sent a message" }
        let count = message.attachments.count
        switch first.kind {
        case .image: return count > 1 ? "Sent \(count) photos" : "Sent a photo"
        case .gif: return "Sent a GIF"
        case .video: return "Sent a video"
        case .audio: return "Sent a voice message"
        case .sticker: return "Sent a sticker"
        case .file: return "Sent a file"
        case .link: return first.url ?? "Sent a link"
        }
    }

    private static func pngData(from urlString: String?) async -> Data? {
        guard let urlString, let url = URL(string: urlString),
              let image = await ImageCache.shared.image(for: url),
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }

    private static func attachment(_ png: Data) -> UNNotificationAttachment? {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("NotificationImages", isDirectory: true)
        let url = directory.appendingPathComponent(UUID().uuidString + ".png")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try png.write(to: url)
            // The system moves the file into its own store.
            return try UNNotificationAttachment(identifier: "avatar", url: url)
        } catch {
            CoreBridge.shared.log("Notifier: image attachment failed: \(error)")
            return nil
        }
    }

    // MARK: - UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        // Only posted when the chat isn't on screen, so show it even while the app is active.
        [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let userInfo = response.notification.request.content.userInfo
        guard let threadID = userInfo["threadID"] as? String else { return }
        let messageID = userInfo["messageID"] as? String
        await MainActor.run { self.onOpenThread?(threadID, messageID) }
    }
}
