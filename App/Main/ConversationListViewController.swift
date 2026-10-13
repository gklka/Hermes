import AppKit
import Combine

enum ConversationFilter: Int, CaseIterable {
    case all, messages, marketplace

    var title: String {
        switch self {
        case .all: "All"
        case .messages: "Messages"
        case .marketplace: "Marketplace"
        }
    }

    func includes(_ conversation: Conversation) -> Bool {
        switch self {
        case .all: true
        case .messages: !conversation.isMarketplace
        case .marketplace: conversation.isMarketplace
        }
    }
}

final class ConversationListViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    var onSelect: ((String?) -> Void)?
    var onFilterChanged: (() -> Void)?

    private static let filterKey = "ConversationFilter"
    var filter = ConversationFilter(rawValue: UserDefaults.standard.integer(forKey: filterKey)) ?? .all {
        didSet {
            UserDefaults.standard.set(filter.rawValue, forKey: Self.filterKey)
            reload()
            onFilterChanged?()
        }
    }

    private let store = ChatStore.shared
    private let searchField = NSSearchField()
    private let scrollView = NSScrollView()
    private let tableView = NSTableView()
    private var rows: [Conversation] = []
    private var selectedID: String?
    /// The first chat is opened once, when the list first loads after launch.
    private var didAutoSelect = false
    private var cancellables: Set<AnyCancellable> = []
    private var isLoadingMore = false

    override func loadView() {
        view = NSView()

        searchField.placeholderString = "Search"
        searchField.delegate = self
        searchField.sendsSearchStringImmediately = true
        searchField.translatesAutoresizingMaskIntoConstraints = false

        let column = NSTableColumn(identifier: .init("conversation"))
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.style = .sourceList
        tableView.rowHeight = 64
        tableView.intercellSpacing = NSSize(width: 0, height: 0)
        tableView.backgroundColor = .clear
        tableView.dataSource = self
        tableView.delegate = self
        tableView.allowsEmptySelection = true

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.automaticallyAdjustsContentInsets = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(searchField)
        view.addSubview(scrollView)
        NSLayoutConstraint.activate([
            searchField.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            searchField.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            searchField.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            scrollView.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        store.changes
            .sink { [weak self] change in
                switch change {
                case .conversations, .connection:
                    self?.reload()
                case .typing(let threadID):
                    self?.reloadRow(threadID)
                default:
                    break
                }
            }
            .store(in: &cancellables)

        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification, object: scrollView.contentView
        )
        reload()
    }

    func focusSearch() {
        view.window?.makeFirstResponder(searchField)
    }

    /// Selects a conversation programmatically (e.g. after "New Message").
    func select(threadID: String) {
        searchField.stringValue = ""
        selectedID = threadID
        onSelect?(threadID)
        if let conversation = store.conversation(threadID), !filter.includes(conversation) {
            filter = .all
        }
        reload()
        if let index = rows.firstIndex(where: { $0.id == threadID }) {
            tableView.scrollRowToVisible(index)
        }
    }

    private func reload() {
        let query = searchField.stringValue.trimmingCharacters(in: .whitespaces).lowercased()
        rows = store.conversations.filter {
            filter.includes($0) && (query.isEmpty || $0.name.lowercased().contains(query))
        }
        tableView.reloadData()
        if !didAutoSelect, let first = rows.first {
            didAutoSelect = true
            if selectedID == nil {
                selectedID = first.id
                onSelect?(first.id)
            }
        }
        if let selectedID, let index = rows.firstIndex(where: { $0.id == selectedID }) {
            tableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        }
    }

    private func reloadRow(_ threadID: String) {
        guard let index = rows.firstIndex(where: { $0.id == threadID }) else { return }
        tableView.reloadData(forRowIndexes: IndexSet(integer: index), columnIndexes: IndexSet(integer: 0))
    }

    @objc private func scrolled() {
        let visible = scrollView.contentView.bounds
        guard !isLoadingMore, rows.count > 10,
              visible.maxY > tableView.bounds.height - 400 else { return }
        isLoadingMore = true
        Task {
            await store.loadMoreConversations()
            try? await Task.sleep(for: .seconds(2))
            isLoadingMore = false
        }
    }

    // MARK: - Search

    func controlTextDidChange(_ obj: Notification) {
        reload()
    }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int {
        rows.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("ConversationCell")
        let cell = tableView.makeView(withIdentifier: id, owner: self) as? ConversationCellView ?? {
            let cell = ConversationCellView()
            cell.identifier = id
            return cell
        }()
        let conversation = rows[row]
        cell.configure(conversation, isTyping: !(store.typing[conversation.id]?.isEmpty ?? true), selfID: store.account?.id)
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = tableView.selectedRow
        let id = row >= 0 && row < rows.count ? rows[row].id : nil
        guard id != selectedID else { return }
        selectedID = id
        onSelect?(id)
    }
}

final class ConversationCellView: NSTableCellView {
    private let avatar = ConversationAvatarView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let dateLabel = NSTextField(labelWithString: "")
    private let snippetLabel = NSTextField(wrappingLabelWithString: "")
    private let unreadDot = NSView()
    private let mutedIcon = NSImageView()
    /// A hidden view still takes space; these collapse the muted icon when it's hidden.
    private lazy var mutedLeading = mutedIcon.leadingAnchor.constraint(equalTo: nameLabel.trailingAnchor, constant: 4)
    private lazy var mutedCollapsed = mutedIcon.widthAnchor.constraint(equalToConstant: 0)

    init() {
        super.init(frame: .zero)

        nameLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        dateLabel.font = .systemFont(ofSize: 12)
        dateLabel.textColor = .secondaryLabelColor
        dateLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        dateLabel.setContentHuggingPriority(.required, for: .horizontal)

        snippetLabel.font = .systemFont(ofSize: 12)
        snippetLabel.textColor = .secondaryLabelColor
        snippetLabel.maximumNumberOfLines = 2
        // Word wrap (a truncating mode would keep each paragraph on one line), "…" on line 2.
        snippetLabel.lineBreakMode = .byWordWrapping
        snippetLabel.cell?.truncatesLastVisibleLine = true

        unreadDot.wantsLayer = true
        unreadDot.layer?.cornerRadius = 5
        unreadDot.layer?.backgroundColor = NSColor.controlAccentColor.cgColor

        mutedIcon.image = NSImage(systemSymbolName: "bell.slash.fill", accessibilityDescription: "Muted")
        mutedIcon.contentTintColor = .tertiaryLabelColor
        mutedIcon.symbolConfiguration = .init(pointSize: 10, weight: .regular)

        for view in [avatar, nameLabel, dateLabel, snippetLabel, unreadDot, mutedIcon] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            unreadDot.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            unreadDot.centerYAnchor.constraint(equalTo: centerYAnchor),
            unreadDot.widthAnchor.constraint(equalToConstant: 10),
            unreadDot.heightAnchor.constraint(equalToConstant: 10),

            avatar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            avatar.centerYAnchor.constraint(equalTo: centerYAnchor),
            avatar.widthAnchor.constraint(equalToConstant: 42),
            avatar.heightAnchor.constraint(equalToConstant: 42),

            nameLabel.leadingAnchor.constraint(equalTo: avatar.trailingAnchor, constant: 10),
            nameLabel.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            mutedLeading,
            mutedIcon.centerYAnchor.constraint(equalTo: nameLabel.centerYAnchor),
            dateLabel.leadingAnchor.constraint(greaterThanOrEqualTo: mutedIcon.trailingAnchor, constant: 6),
            dateLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            dateLabel.firstBaselineAnchor.constraint(equalTo: nameLabel.firstBaselineAnchor),

            snippetLabel.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            snippetLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            snippetLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 2),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        // A wrapping label only wraps to its preferred width; it's the space right of the avatar
        // (16 + 42 + 10 leading, 10 trailing).
        snippetLabel.preferredMaxLayoutWidth = max(0, bounds.width - 78)
        super.layout()
    }

    func configure(_ conversation: Conversation, isTyping: Bool, selfID: String?) {
        nameLabel.stringValue = conversation.name
        dateLabel.stringValue = Formatters.listTimestamp(conversation.lastActivityDate)
        avatar.configure(conversation, selfID: selfID)
        unreadDot.isHidden = conversation.unreadCount == 0
        mutedIcon.isHidden = !conversation.isMuted
        mutedLeading.constant = conversation.isMuted ? 4 : 0
        mutedCollapsed.isActive = !conversation.isMuted

        if isTyping {
            snippetLabel.stringValue = "typing…"
        } else if conversation.snippetSenderID == selfID, !conversation.snippet.isEmpty {
            snippetLabel.stringValue = "You: \(conversation.snippet)"
        } else if conversation.snippet.isEmpty, conversation.isEncrypted {
            snippetLabel.stringValue = "End-to-end encrypted chat"
        } else {
            snippetLabel.stringValue = conversation.snippet
        }
        nameLabel.font = .systemFont(ofSize: 13, weight: conversation.unreadCount > 0 ? .bold : .semibold)
    }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet {
            // Selected rows in the sidebar use an accent-colored highlight; keep text readable.
            let emphasized = backgroundStyle == .emphasized
            nameLabel.textColor = emphasized ? .alternateSelectedControlTextColor : .labelColor
            dateLabel.textColor = emphasized ? .alternateSelectedControlTextColor : .secondaryLabelColor
            snippetLabel.textColor = emphasized ? .alternateSelectedControlTextColor : .secondaryLabelColor
            unreadDot.layer?.backgroundColor = (emphasized ? NSColor.white : NSColor.controlAccentColor).cgColor
        }
    }
}
