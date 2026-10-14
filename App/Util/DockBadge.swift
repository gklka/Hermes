import AppKit
import Combine

/// The Dock icon's badge: how many chats are unread (including ones marked unread) or have
/// reactions to your messages you haven't seen. Muted chats don't count, as they don't notify
/// either.
final class DockBadge {
    static let shared = DockBadge()

    private let store = ChatStore.shared
    private var cancellable: AnyCancellable?

    func start() {
        guard cancellable == nil else { return }
        cancellable = store.changes.sink { [weak self] change in
            switch change {
            case .conversations, .connection: self?.update()
            default: break
            }
        }
        update()
    }

    private func update() {
        let unread = store.conversations.count {
            !$0.isMuted && ($0.unreadCount > 0 || store.unseenReactions[$0.id] != nil)
        }
        let label = unread > 0 ? "\(unread)" : nil
        if NSApp.dockTile.badgeLabel != label {
            NSApp.dockTile.badgeLabel = label
        }
    }
}
