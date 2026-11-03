import AppKit

/// A chat's toolbar buttons (listing, pinned messages, calls, members) as one toolbar item on one
/// Liquid Glass capsule. Switching chats only shows and hides buttons inside it: hiding and
/// showing separate toolbar items made the toolbar animate them over each other, with the glass
/// stretching out of the window.
final class ChatToolbarButtons: NSView {
    static let itemID = NSToolbarItem.Identifier("chatButtons")

    enum Kind: CaseIterable {
        case listing, pinned, audioCall, videoCall, members

        var symbol: String {
            switch self {
            case .listing: "storefront"
            case .pinned: "pin.fill"
            case .audioCall: "phone"
            case .videoCall: "video"
            case .members: "info.circle"
            }
        }

        var label: String {
            switch self {
            case .listing: "Open the Listing on Facebook"
            case .pinned: "Pinned Messages"
            case .audioCall: "Audio Call"
            case .videoCall: "Video Call"
            case .members: "Members"
            }
        }

        /// Implemented by both the main window and chat windows.
        var action: Selector {
            switch self {
            case .listing: NSSelectorFromString("openListing:")
            case .pinned: NSSelectorFromString("showPinnedMessages:")
            case .audioCall: NSSelectorFromString("startAudioCall:")
            case .videoCall: NSSelectorFromString("startVideoCall:")
            case .members: NSSelectorFromString("showMembers:")
            }
        }
    }

    private static let height: CGFloat = 36
    private static let buttonWidth: CGFloat = 38

    private let glass = NSGlassEffectView()
    private let stack = NSStackView()
    private var buttons: [Kind: NSButton] = [:]

    /// The toolbar item holding the buttons; `target` implements every Kind's action.
    static func makeItem(target: AnyObject) -> (NSToolbarItem, ChatToolbarButtons) {
        let view = ChatToolbarButtons(target: target)
        let item = NSToolbarItem(itemIdentifier: itemID)
        item.view = view
        item.label = "Chat"
        item.isBordered = false
        return (item, view)
    }

    init(target: AnyObject) {
        super.init(frame: .zero)
        stack.orientation = .horizontal
        stack.spacing = 0
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 4, bottom: 0, right: 4)
        stack.detachesHiddenViews = true
        for kind in Kind.allCases {
            let button = NSButton()
            button.image = NSImage(systemSymbolName: kind.symbol, accessibilityDescription: kind.label)
            button.symbolConfiguration = .init(pointSize: 15, weight: .regular)
            button.isBordered = false
            button.bezelStyle = .regularSquare
            button.imagePosition = .imageOnly
            button.contentTintColor = .labelColor
            button.toolTip = kind.label
            button.target = target
            button.action = kind.action
            button.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                button.widthAnchor.constraint(equalToConstant: Self.buttonWidth),
                button.heightAnchor.constraint(equalToConstant: Self.height),
            ])
            buttons[kind] = button
            stack.addArrangedSubview(button)
        }
        glass.cornerRadius = Self.height / 2
        glass.contentView = stack
        glass.translatesAutoresizingMaskIntoConstraints = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(glass)
        NSLayoutConstraint.activate([
            glass.leadingAnchor.constraint(equalTo: leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: trailingAnchor),
            glass.topAnchor.constraint(equalTo: topAnchor),
            glass.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: glass.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: glass.trailingAnchor),
            stack.topAnchor.constraint(equalTo: glass.topAnchor),
            stack.bottomAnchor.constraint(equalTo: glass.bottomAnchor),
        ])
        show([])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Shows only these buttons (none: the capsule disappears).
    func show(_ kinds: Set<Kind>) {
        for (kind, button) in buttons where button.isHidden == kinds.contains(kind) {
            button.isHidden = !kinds.contains(kind)
        }
        glass.isHidden = kinds.isEmpty
    }

    /// The buttons a chat has.
    static func kinds(for conversation: Conversation?, hasPinnedMessages: Bool) -> Set<Kind> {
        guard let conversation else { return [] }
        var kinds: Set<Kind> = [.audioCall, .videoCall]
        if conversation.isMarketplace { kinds.insert(.listing) }
        if hasPinnedMessages { kinds.insert(.pinned) }
        if conversation.isGroup { kinds.insert(.members) }
        return kinds
    }
}
