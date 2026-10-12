import AppKit

/// "New Message" sheet: search contacts and open a 1:1 chat.
final class NewMessageViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    var onPick: ((Participant) -> Void)?

    private let searchField = NSSearchField()
    private let tableView = NSTableView()
    private var results: [Participant] = []
    private var searchTask: Task<Void, Never>?

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 440))

        let title = NSTextField(labelWithString: "New Message")
        title.font = .systemFont(ofSize: 13, weight: .semibold)

        searchField.placeholderString = "To: name"
        searchField.delegate = self
        searchField.sendsSearchStringImmediately = true

        tableView.addTableColumn(NSTableColumn(identifier: .init("contact")))
        tableView.headerView = nil
        tableView.rowHeight = 40
        tableView.style = .inset
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(pickSelected)

        let scroll = NSScrollView()
        scroll.documentView = tableView
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancel.keyEquivalent = "\u{1b}"
        let open = NSButton(title: "Open", target: self, action: #selector(pickSelected))
        open.keyEquivalent = "\r"

        let note = NSTextField(wrappingLabelWithString: "Earlier messages in encrypted chats can't be loaded. New messages will appear here.")
        note.font = .systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor

        for view in [title, searchField, scroll, note, cancel, open] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: root.topAnchor, constant: 16),
            title.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            searchField.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 12),
            searchField.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            searchField.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            scroll.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            note.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 8),
            note.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            note.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            open.topAnchor.constraint(equalTo: note.bottomAnchor, constant: 12),
            open.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            open.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16),
            cancel.centerYAnchor.constraint(equalTo: open.centerYAnchor),
            cancel.trailingAnchor.constraint(equalTo: open.leadingAnchor, constant: -8),
            root.widthAnchor.constraint(equalToConstant: 360),
            root.heightAnchor.constraint(equalToConstant: 440),
        ])
        view = root
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(searchField)
        search("")
    }

    private func search(_ query: String) {
        searchTask?.cancel()
        searchTask = Task {
            let found = await ChatStore.shared.searchContacts(query)
            guard !Task.isCancelled else { return }
            results = found
            tableView.reloadData()
            if !results.isEmpty {
                tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            }
        }
    }

    func controlTextDidChange(_ obj: Notification) {
        search(searchField.stringValue.trimmingCharacters(in: .whitespaces))
    }

    /// Arrow keys in the search field move the selection; Return opens.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.moveDown(_:)), #selector(NSResponder.moveUp(_:)):
            guard !results.isEmpty else { return true }
            let delta = commandSelector == #selector(NSResponder.moveDown(_:)) ? 1 : -1
            let row = min(max(tableView.selectedRow + delta, 0), results.count - 1)
            tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            tableView.scrollRowToVisible(row)
            return true
        case #selector(NSResponder.insertNewline(_:)):
            pickSelected()
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            cancel()
            return true
        default:
            return false
        }
    }

    @objc private func pickSelected() {
        let row = tableView.selectedRow
        guard row >= 0, row < results.count else { return }
        let contact = results[row]
        dismiss(nil)
        onPick?(contact)
    }

    @objc private func cancel() {
        dismiss(nil)
    }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int {
        results.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("ContactCell")
        let cell = tableView.makeView(withIdentifier: id, owner: self) as? ContactCellView ?? {
            let cell = ContactCellView()
            cell.identifier = id
            return cell
        }()
        cell.configure(results[row])
        return cell
    }
}

final class ContactCellView: NSTableCellView {
    private let avatar = AvatarView()
    private let nameLabel = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        nameLabel.font = .systemFont(ofSize: 13)
        nameLabel.lineBreakMode = .byTruncatingTail
        for view in [avatar, nameLabel] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            avatar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            avatar.centerYAnchor.constraint(equalTo: centerYAnchor),
            avatar.widthAnchor.constraint(equalToConstant: 28),
            avatar.heightAnchor.constraint(equalToConstant: 28),
            nameLabel.leadingAnchor.constraint(equalTo: avatar.trailingAnchor, constant: 8),
            nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -4),
            nameLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(_ contact: Participant) {
        nameLabel.stringValue = contact.name
        avatar.configure(name: contact.name, url: contact.avatarURL)
    }
}
