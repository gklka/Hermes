import AppKit
import Combine

/// A group chat's members, as a sheet (the info button, or the "3 people" subtitle in a chat
/// window). Hovering a person shows buttons to message them or view their profile; double-click
/// opens your chat with them too. A last "Add member" row opens a search to add people.
final class MembersViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    private let threadID: String
    private let tableView = NSTableView()
    private var members: [Participant] = []
    private var cancellable: AnyCancellable?

    init(threadID: String) {
        self.threadID = threadID
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 340, height: 400))
        reloadMembers()

        let title = NSTextField(labelWithString: ChatStore.shared.conversation(threadID)?.name ?? "Members")
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.lineBreakMode = .byTruncatingTail
        let count = NSTextField(labelWithString: "\(members.count) people")
        count.font = .systemFont(ofSize: 11)
        count.textColor = .secondaryLabelColor

        let close = NSButton.glassClose(target: self, action: #selector(closeSheet))

        tableView.addTableColumn(NSTableColumn(identifier: .init("member")))
        tableView.headerView = nil
        tableView.rowHeight = 44
        tableView.style = .inset
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(messageClicked)
        tableView.menu = NSMenu()
        tableView.menu?.addItem(withTitle: "Message", action: #selector(messageClicked), keyEquivalent: "").target = self
        tableView.menu?.addItem(withTitle: "View Profile", action: #selector(profileClicked), keyEquivalent: "").target = self

        let scroll = NSScrollView()
        scroll.documentView = tableView
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false

        for view in [title, count, close, scroll] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        NSLayoutConstraint.activate([
            close.topAnchor.constraint(equalTo: root.topAnchor, constant: 12),
            close.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            title.topAnchor.constraint(equalTo: root.topAnchor, constant: 16),
            title.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            title.trailingAnchor.constraint(lessThanOrEqualTo: close.leadingAnchor, constant: -8),
            count.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 2),
            count.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            scroll.topAnchor.constraint(equalTo: count.bottomAnchor, constant: 12),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -8),
            root.widthAnchor.constraint(equalToConstant: 340),
            root.heightAnchor.constraint(equalToConstant: 400),
        ])
        view = root

        // Keep the list current when members are added (here or elsewhere).
        cancellable = ChatStore.shared.changes
            .sink { [weak self] change in
                if case .conversations = change { self?.reloadMembers() }
            }
    }

    /// Loads the chat's members (you last, everyone else by name) and refreshes the list.
    private func reloadMembers() {
        let selfID = ChatStore.shared.account?.id
        members = (ChatStore.shared.conversation(threadID)?.participants ?? []).sorted { a, b in
            if (a.id == selfID) != (b.id == selfID) { return b.id == selfID }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
        tableView.reloadData()
    }

    private func isYou(_ person: Participant) -> Bool {
        person.id == ChatStore.shared.account?.id
    }

    /// The person right-clicked or double-clicked; not you, and not the "Add member" row.
    private var clickedPerson: Participant? {
        let row = tableView.clickedRow
        guard members.indices.contains(row), !isYou(members[row]) else { return nil }
        return members[row]
    }

    /// The last row is "Add member".
    private var addRow: Int { members.count }

    /// Opens a search to add people to the group.
    private func addMembers() {
        let panel = NewChatViewController()
        panel.titleText = "Add Members"
        panel.actionTitle = "Add"
        panel.noteText = "Search for people to add to this group."
        panel.excludedIDs = Set(members.map(\.id))
        let threadID = threadID
        panel.onCreate = { userIDs in
            guard !userIDs.isEmpty else { return }
            Task { try? await ChatStore.shared.addParticipants(to: threadID, userIDs: userIDs) }
        }
        presentAsSheet(panel)
    }

    @objc private func messageClicked() {
        clickedPerson.map(message)
    }

    @objc private func profileClicked() {
        clickedPerson.map(viewProfile)
    }

    /// Opens your 1:1 chat with them (created if there's none yet).
    private func message(_ person: Participant) {
        dismiss(nil)
        Task {
            guard let conversation = try? await ChatStore.shared.openDirectChat(with: person.id) else { return }
            (NSApp.delegate as? AppDelegate)?.openChat(conversation.id)
        }
    }

    private func viewProfile(_ person: Participant) {
        guard let url = Facebook.profileURL(of: person.id) else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func closeSheet() {
        dismiss(nil)
    }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int { members.count + 1 }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        if row == addRow {
            let id = NSUserInterfaceItemIdentifier("AddMemberCell")
            let cell = tableView.makeView(withIdentifier: id, owner: self) as? AddMemberCellView ?? {
                let cell = AddMemberCellView()
                cell.identifier = id
                return cell
            }()
            cell.onClick = { [weak self] in self?.addMembers() }
            return cell
        }
        let id = NSUserInterfaceItemIdentifier("MemberCell")
        let cell = tableView.makeView(withIdentifier: id, owner: self) as? MemberCellView ?? {
            let cell = MemberCellView()
            cell.identifier = id
            return cell
        }()
        let person = members[row]
        let you = isYou(person)
        cell.configure(person, isYou: you)
        cell.onMessage = you ? nil : { [weak self] in self?.message(person) }
        cell.onProfile = { [weak self] in self?.viewProfile(person) }
        return cell
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }
}

/// A member: picture and name, and on hover, buttons to message them and view their profile.
private final class MemberCellView: NSTableCellView {
    private let avatar = AvatarView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let messageButton = MemberCellView.symbolButton("message", label: "Message")
    private let profileButton = MemberCellView.symbolButton("info.circle", label: "View Profile")
    private var hoverArea: NSTrackingArea?
    private var isHovered = false {
        didSet { updateButtons() }
    }

    var onMessage: (() -> Void)? {
        didSet { updateButtons() }
    }
    var onProfile: (() -> Void)?

    private static func symbolButton(_ symbol: String, label: String) -> NSButton {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)!
            .withSymbolConfiguration(.init(pointSize: 15, weight: .regular))!
        let button = NSButton(image: image, target: nil, action: nil)
        button.isBordered = false
        button.contentTintColor = .secondaryLabelColor
        button.toolTip = label
        return button
    }

    init() {
        super.init(frame: .zero)
        nameLabel.font = .systemFont(ofSize: 13)
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        detailLabel.font = .systemFont(ofSize: 11)
        detailLabel.textColor = .secondaryLabelColor
        messageButton.target = self
        messageButton.action = #selector(messageTapped)
        profileButton.target = self
        profileButton.action = #selector(profileTapped)

        let labels = NSStackView(views: [nameLabel, detailLabel])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 0
        let buttons = NSStackView(views: [messageButton, profileButton])
        buttons.spacing = 10
        for view in [avatar, labels, buttons] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            avatar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            avatar.centerYAnchor.constraint(equalTo: centerYAnchor),
            avatar.widthAnchor.constraint(equalToConstant: 30),
            avatar.heightAnchor.constraint(equalToConstant: 30),
            labels.leadingAnchor.constraint(equalTo: avatar.trailingAnchor, constant: 8),
            labels.centerYAnchor.constraint(equalTo: centerYAnchor),
            labels.trailingAnchor.constraint(lessThanOrEqualTo: buttons.leadingAnchor, constant: -8),
            buttons.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            buttons.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        updateButtons()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(_ person: Participant, isYou: Bool) {
        nameLabel.stringValue = person.name
        detailLabel.stringValue = "You"
        detailLabel.isHidden = !isYou
        avatar.configure(name: person.name, url: person.avatarURL)
    }

    /// Shown while the pointer is over the row; no message button on your own row.
    private func updateButtons() {
        messageButton.isHidden = !isHovered || onMessage == nil
        profileButton.isHidden = !isHovered
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        hoverArea = area
        // A row that scrolled under (or out from under) the pointer.
        if let window {
            isHovered = bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil))
        }
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }

    override func prepareForReuse() {
        super.prepareForReuse()
        isHovered = false
    }

    @objc private func messageTapped() { onMessage?() }
    @objc private func profileTapped() { onProfile?() }
}

/// The "Add member" row: a plus avatar and a label, matching the member rows' layout. The whole
/// row is a button that highlights while pressed; clicking opens the add-people sheet. A table
/// view only routes clicks to NSControl cell subviews, so the row is backed by a button (not a
/// plain view) to stay clickable.
private final class AddMemberCellView: NSTableCellView {
    private let button = PressButton()
    private let circle = NSView()
    private let plus = NSImageView(image: NSImage(systemSymbolName: "plus", accessibilityDescription: "Add member") ?? NSImage())
    private let label = NSTextField(labelWithString: "Add member")
    var onClick: (() -> Void)?

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 8

        button.title = ""
        button.isBordered = false
        button.focusRingType = .none
        button.setButtonType(.momentaryChange)
        button.target = self
        button.action = #selector(clicked)
        button.onHighlightChange = { [weak self] in self?.updateHighlight() }

        circle.wantsLayer = true
        circle.layer?.cornerRadius = 15
        plus.symbolConfiguration = .init(pointSize: 15, weight: .medium)
        plus.translatesAutoresizingMaskIntoConstraints = false
        circle.addSubview(plus)

        label.font = .systemFont(ofSize: 13)

        for view in [button, circle, label] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            button.leadingAnchor.constraint(equalTo: leadingAnchor),
            button.trailingAnchor.constraint(equalTo: trailingAnchor),
            button.topAnchor.constraint(equalTo: topAnchor),
            button.bottomAnchor.constraint(equalTo: bottomAnchor),
            circle.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            circle.centerYAnchor.constraint(equalTo: centerYAnchor),
            circle.widthAnchor.constraint(equalToConstant: 30),
            circle.heightAnchor.constraint(equalToConstant: 30),
            plus.centerXAnchor.constraint(equalTo: circle.centerXAnchor),
            plus.centerYAnchor.constraint(equalTo: circle.centerYAnchor),
            label.leadingAnchor.constraint(equalTo: circle.trailingAnchor, constant: 8),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
        ])
        updateHighlight()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    @objc private func clicked() {
        // Opening the sheet steals the mouse-up, so the button never un-highlights: clear it here.
        button.highlight(false)
        updateHighlight()
        onClick?()
    }

    /// All clicks in the row go to the button (the avatar and label don't intercept them).
    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(convert(point, from: superview)) ? button : nil
    }

    /// A gray highlight only while pressed.
    private func updateHighlight() {
        let pressed = button.isHighlighted
        layer?.backgroundColor = (pressed ? NSColor.labelColor.withAlphaComponent(0.1) : .clear).cgColor
        circle.layer?.backgroundColor = (pressed ? NSColor.labelColor.withAlphaComponent(0.2)
            : NSColor.quaternaryLabelColor).cgColor
    }
}

/// A button that reports when its pressed (highlighted) state changes, so a custom row can show
/// a pressed look.
private final class PressButton: NSButton {
    var onHighlightChange: (() -> Void)?

    override var isHighlighted: Bool {
        didSet { if isHighlighted != oldValue { onHighlightChange?() } }
    }
}
