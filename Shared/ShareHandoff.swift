import Foundation

/// How the share extension and the app talk. The extension is sandboxed and can't reach the
/// core, so it leaves what's shared in the app group's Outbox folder (a request.json and the
/// files) and opens `hermes://share?id=<folder>`; the app sends it. The app keeps the
/// recent chats (and their pictures) there for the extension's chat picker. (The share sheet's
/// own conversation suggestions are iOS-only: NSExtensionContext.intent is unavailable on macOS.)
enum ShareHandoff {
    /// From the Info.plist (set in Support/Signing.xcconfig).
    nonisolated static let groupID = Bundle.main.object(forInfoDictionaryKey: "MMAppGroupID") as? String ?? ""
    nonisolated static let urlScheme = "hermes"
    nonisolated static let shareHost = "share"

    nonisolated static var container: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID)
    }

    nonisolated static var outbox: URL? {
        container?.appendingPathComponent("Outbox", isDirectory: true)
    }

    nonisolated static var recentChatsFile: URL? {
        container?.appendingPathComponent("RecentChats.json")
    }

    /// The chats' pictures, as "<thread ID>.png".
    nonisolated static var avatarsFolder: URL? {
        container?.appendingPathComponent("Avatars", isDirectory: true)
    }

    nonisolated static let requestFileName = "request.json"

    /// A chat for the picker, most recent first.
    struct Chat: Codable, Sendable {
        let id: String
        let name: String
        /// Whether Avatars has its picture.
        let hasAvatar: Bool
    }

    struct Request: Codable, Sendable {
        let threadID: String
        let text: String
        /// File names in the request's folder.
        let files: [String]
    }
}
