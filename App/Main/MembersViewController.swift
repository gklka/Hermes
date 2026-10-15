import AppKit

/// A group chat's members, as a sheet (the info button, or the "3 people" subtitle in a chat
/// window). Hovering a person shows buttons to message them or view their profile; double-click
/// opens your chat with them too.
final class MembersViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    private let threadID: String
    private let tableView = NSTableView()
    private var members: [Participant] = []

    init(threadID: String) {
        self.threadID = threadID
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 340, height: 400))
        let conversation = ChatStore.shared.conversation(threadID)
        let selfID = ChatStore.shared.account?.id
        // You last, everyone else by name.
        members = (conversation?.participants ?? []).sorted { a, b in
            if (a.id == selfID) != (b.id == selfID) { return b.id == selfID }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }

        let title = NSTextField(labelWithString: conversation?.name ?? "Members")
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.lineBreakMode = .byTruncatingTail
        let count = NSTextField(labelWithString: "\(members.count) people")
        count.font = .systemFont(ofSize: 11)
        count.textColor = .secondaryLabelColor

        let close = NSButton(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close")!, target: self, action: #selector(closeSheet))
        close.bezelStyle = .glass
        close.borderShape = .circle
        close.controlSize = .large
        close.keyEquivalent = "\u{1b}"
        close.toolTip = "Close"

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
    }

    private func isYou(_ person: Participant) -> Bool {
        person.id == ChatStore.shared.account?.id
    }

    /// The person right-clicked or double-clicked; not you.
    private var clickedPerson: Participant? {
        let row = tableView.clickedRow
        guard members.indices.contains(row), !isYou(members[row]) else { return nil }
        return members[row]
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

    func numberOfRows(in tableView: NSTableView) -> Int { members.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
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
