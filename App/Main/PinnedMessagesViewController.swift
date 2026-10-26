import AppKit

/// A chat's pinned messages, as a sheet. Clicking one reveals it in the chat; right-clicking
/// offers to reveal or unpin it.
final class PinnedMessagesViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    /// Called with a message's ID to scroll to and select it in the open chat.
    var onReveal: ((String) -> Void)?

    private let threadID: String
    private let tableView = NSTableView()
    private let emptyLabel = NSTextField(labelWithString: "No pinned messages")
    private var messages: [ChatMessage] = []

    init(threadID: String) {
        self.threadID = threadID
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 420))

        let title = NSTextField(labelWithString: "Pinned Messages")
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.lineBreakMode = .byTruncatingTail

        let close = NSButton.glassClose(target: self, action: #selector(closeSheet))

        tableView.addTableColumn(NSTableColumn(identifier: .init("pinned")))
        tableView.headerView = nil
        tableView.rowHeight = 60
        tableView.style = .inset
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.action = #selector(rowClicked)
        tableView.menu = NSMenu()
        tableView.menu?.addItem(withTitle: "Reveal in the Chat", action: #selector(revealClicked), keyEquivalent: "").target = self
        tableView.menu?.addItem(withTitle: "Unpin", action: #selector(unpinClicked), keyEquivalent: "").target = self

        let scroll = NSScrollView()
        scroll.documentView = tableView
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false

        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.isHidden = true

        for view in [title, close, scroll, emptyLabel] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        NSLayoutConstraint.activate([
            close.topAnchor.constraint(equalTo: root.topAnchor, constant: 12),
            close.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            title.topAnchor.constraint(equalTo: root.topAnchor, constant: 16),
            title.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            title.leadingAnchor.constraint(greaterThanOrEqualTo: root.leadingAnchor, constant: 16),
            title.trailingAnchor.constraint(lessThanOrEqualTo: close.leadingAnchor, constant: -8),
            scroll.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 12),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -8),
            emptyLabel.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
            root.widthAnchor.constraint(equalToConstant: 360),
            root.heightAnchor.constraint(equalToConstant: 420),
        ])
        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        Task {
            messages = await ChatStore.shared.pinnedMessages(in: threadID)
            tableView.reloadData()
            emptyLabel.isHidden = !messages.isEmpty
        }
    }

    /// The message a row shows; the one clicked for the menu actions.
    private func message(at row: Int) -> ChatMessage? {
        messages.indices.contains(row) ? messages[row] : nil
    }

    @objc private func rowClicked() {
        guard let message = message(at: tableView.clickedRow) else { return }
        reveal(message)
    }

    @objc private func revealClicked() {
        guard let message = message(at: tableView.clickedRow) else { return }
        reveal(message)
    }

    @objc private func unpinClicked() {
        guard let message = message(at: tableView.clickedRow) else { return }
        ChatStore.shared.setPinned(message, pinned: false)
        messages.remove(at: tableView.clickedRow)
        if messages.isEmpty {
            closeSheet()
        } else {
            tableView.reloadData()
        }
    }

    private func reveal(_ message: ChatMessage) {
        dismiss(nil)
        onReveal?(message.id)
    }

    @objc private func closeSheet() {
        dismiss(nil)
    }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int { messages.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("PinnedCell")
        let cell = tableView.makeView(withIdentifier: id, owner: self) as? PinnedMessageCellView ?? {
            let cell = PinnedMessageCellView()
            cell.identifier = id
            return cell
        }()
        if let message = message(at: row) {
            cell.configure(message, threadID: threadID)
        }
        return cell
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }
}

/// One pinned message: the sender's picture, their name and the pin's time, and the message text.
private final class PinnedMessageCellView: NSTableCellView {
    private let avatar = AvatarView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let dateLabel = NSTextField(labelWithString: "")
    private let textLabel = NSTextField(wrappingLabelWithString: "")

    init() {
        super.init(frame: .zero)
        nameLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        dateLabel.font = .systemFont(ofSize: 11)
        dateLabel.textColor = .secondaryLabelColor
        dateLabel.alignment = .right
        dateLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        dateLabel.setContentHuggingPriority(.required, for: .horizontal)
        textLabel.font = .systemFont(ofSize: 12)
        textLabel.textColor = .secondaryLabelColor
        textLabel.maximumNumberOfLines = 2
        textLabel.lineBreakMode = .byTruncatingTail

        let header = NSStackView(views: [nameLabel, dateLabel])
        header.orientation = .horizontal
        header.distribution = .fill
        let labels = NSStackView(views: [header, textLabel])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 1
        header.widthAnchor.constraint(equalTo: labels.widthAnchor).isActive = true
        for view in [avatar, labels] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            avatar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            avatar.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            avatar.widthAnchor.constraint(equalToConstant: 32),
            avatar.heightAnchor.constraint(equalToConstant: 32),
            labels.leadingAnchor.constraint(equalTo: avatar.trailingAnchor, constant: 8),
            labels.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            labels.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(_ message: ChatMessage, threadID: String) {
        let store = ChatStore.shared
        let name = message.isFromMe ? "You" : store.participantName(message.senderID, in: threadID)
        nameLabel.stringValue = name.isEmpty ? "Unknown" : name
        dateLabel.stringValue = Formatters.separator(message.date)
        textLabel.stringValue = Self.snippet(message)
        let participant = store.participant(message.senderID, in: threadID)
        avatar.configure(name: name, url: participant?.avatarURL)
    }

    /// The message's text, or a stand-in describing its attachment.
    private static func snippet(_ message: ChatMessage) -> String {
        if !message.text.isEmpty { return message.text }
        switch message.attachments.first?.kind {
        case .image, .sticker: return "Photo"
        case .gif: return "GIF"
        case .video: return "Video"
        case .audio: return "Audio message"
        case .file: return "Attachment"
        case .location: return "Location"
        case nil: return "Message"
        default: return "Attachment"
        }
    }
}
