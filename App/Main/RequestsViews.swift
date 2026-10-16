import AppKit

/// Above the chat list while it shows message requests, like Messenger's Requests page: the
/// "You May Know" and "Spam" tabs, and what opening a request means.
final class RequestsHeaderView: NSView {
    var onTabChange: ((RequestList) -> Void)?

    private let tabs = NSSegmentedControl(labels: RequestList.allCases.map(\.title), trackingMode: .selectOne, target: nil, action: nil)

    var tab: RequestList {
        get { RequestList.allCases[max(0, tabs.selectedSegment)] }
        set { tabs.selectedSegment = RequestList.allCases.firstIndex(of: newValue) ?? 0 }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        tabs.target = self
        tabs.action = #selector(tabChanged)
        tabs.segmentDistribution = .fillEqually
        tabs.selectedSegment = 0

        let info = NSTextField(wrappingLabelWithString:
            "Open a request to get more info about who's messaging you. They won't know you've seen it until you accept.")
        info.font = .systemFont(ofSize: 11)
        info.textColor = .secondaryLabelColor

        let stack = NSStackView(views: [tabs, info])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            tabs.widthAnchor.constraint(equalTo: stack.widthAnchor),
            info.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    @objc private func tabChanged() {
        onTabChange?(tab)
    }
}

/// Instead of the compose bar in a message request: what accepting means, and Block, Delete
/// and Accept, like Messenger's.
final class RequestActionsView: NSView {
    var onBlock: (() -> Void)?
    var onDelete: (() -> Void)?
    var onAccept: (() -> Void)?

    private let info = NSTextField(wrappingLabelWithString: "")
    private let blockButton = NSButton(title: "Block", target: nil, action: nil)
    private let deleteButton = NSButton(title: "Delete", target: nil, action: nil)
    private let acceptButton = NSButton(title: "Accept", target: nil, action: nil)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        info.font = .systemFont(ofSize: 12)
        info.textColor = .secondaryLabelColor
        info.alignment = .center

        for (button, action) in [(blockButton, #selector(blockClicked)), (deleteButton, #selector(deleteClicked)),
                                 (acceptButton, #selector(acceptClicked))] {
            button.target = self
            button.action = action
            button.bezelStyle = .push
            button.controlSize = .large
        }
        blockButton.hasDestructiveAction = true
        deleteButton.hasDestructiveAction = true
        acceptButton.keyEquivalent = "\r"
        let buttons = NSStackView(views: [blockButton, deleteButton, acceptButton])
        buttons.distribution = .fillEqually
        buttons.spacing = 10

        let stack = NSStackView(views: [info, buttons])
        stack.orientation = .vertical
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -14),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor),
            info.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// A group request can't be blocked (that's for people), only deleted or accepted.
    func configure(name: String, isGroup: Bool) {
        info.stringValue = isGroup
            ? "If you accept, the chat moves to your chats, and its members can see when you've read their messages."
            : "If you accept, \(name) can also call you and see info like your Active status and when you've read their messages."
        blockButton.isHidden = isGroup
    }

    @objc private func blockClicked() { onBlock?() }
    @objc private func deleteClicked() { onDelete?() }
    @objc private func acceptClicked() { onAccept?() }
}
