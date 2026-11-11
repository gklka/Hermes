import AppKit

/// Buttons you can add to a window's toolbar (View › Customize Toolbar…): the menu commands that
/// make sense there. The window controllers implement the actions (Activity is the app's).
enum ToolbarAction: String, CaseIterable {
    case openChat, findInChat, attachFiles, like, toggleUnread, editMessage, refresh, export, activity

    /// The ones a chat window has (it has no chat list to open chats from).
    static let chatWindow: [ToolbarAction] = [.findInChat, .attachFiles, .like, .toggleUnread, .editMessage, .refresh, .export, .activity]

    var identifier: NSToolbarItem.Identifier { .init("action.\(rawValue)") }

    init?(_ identifier: NSToolbarItem.Identifier) {
        guard let action = Self.allCases.first(where: { $0.identifier == identifier }) else { return nil }
        self = action
    }

    var label: String {
        switch self {
        case .openChat: "Open Chat"
        case .findInChat: "Find in Chat"
        case .attachFiles: "Attach Files"
        case .like: "Like"
        case .toggleUnread: "Mark as Unread"
        case .editMessage: "Edit Message"
        case .refresh: "Refresh"
        case .export: "Export Chat"
        case .activity: "Activity"
        }
    }

    private var paletteLabel: String {
        self == .toggleUnread ? "Mark as Read/Unread" : label
    }

    private var symbol: String {
        switch self {
        case .openChat: "text.bubble"
        case .findInChat: "text.magnifyingglass"
        case .attachFiles: "paperclip"
        case .like: "hand.thumbsup"
        case .toggleUnread: "envelope.badge"
        case .editMessage: "pencil"
        case .refresh: "arrow.clockwise"
        case .export: "square.and.arrow.up"
        case .activity: "list.bullet.rectangle"
        }
    }

    private var shortcut: String? {
        switch self {
        case .openChat: "⌘O"
        case .findInChat: "⌥⌘F"
        case .attachFiles: "⇧⌘A"
        case .like: "⌘L"
        case .toggleUnread: "⇧⌘U"
        case .editMessage: "⌘E"
        case .refresh: "⌘R"
        case .export: "⇧⌘E"
        case .activity: "⌥⌘0"
        }
    }

    private var action: Selector {
        switch self {
        case .openChat: NSSelectorFromString("newMessage:")
        case .findInChat: NSSelectorFromString("findInChat:")
        case .attachFiles: NSSelectorFromString("attachFiles:")
        case .like: NSSelectorFromString("sendLike:")
        case .toggleUnread: NSSelectorFromString("toggleUnread:")
        case .editMessage: NSSelectorFromString("editMessage:")
        case .refresh: NSSelectorFromString("refreshChat:")
        case .export: NSSelectorFromString("exportChat:")
        case .activity: #selector(AppDelegate.toggleActivity(_:))
        }
    }

    /// Only enabled while a chat is open.
    var needsChat: Bool {
        self != .openChat && self != .activity
    }

    /// The toolbar item; `target` implements the action (Activity goes to the app delegate).
    func makeItem(target: AnyObject) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        item.label = label
        item.paletteLabel = paletteLabel
        item.toolTip = shortcut.map { "\(label) (\($0))" } ?? label
        item.target = self == .activity ? nil : target
        item.action = action
        return item
    }

    /// The Mark as Read/Unread button says what it'll do for the open chat.
    static func updateUnreadItem(_ item: NSToolbarItem, unread: Bool) {
        let label = unread ? "Mark as Read" : "Mark as Unread"
        guard item.label != label else { return }
        item.label = label
        item.toolTip = "\(label) (⇧⌘U)"
        item.image = NSImage(systemSymbolName: unread ? "envelope.open" : "envelope.badge", accessibilityDescription: label)
    }
}
