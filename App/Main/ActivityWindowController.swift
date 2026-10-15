import AppKit

/// Window › Activity, like Mail's: a small utility panel with the timeline of what's loaded
/// from Messenger web (encrypted chats' history, and the chat list): up next (the queue, and chats waiting to be
/// checked again), now (the running import with its progress), and done (since launch).
/// Double-click a chat to open it.
final class ActivityWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    static let shared = ActivityWindowController()

    private enum Row {
        case header(String)
        case item(WebHistoryImporter.ActivityItem)
    }

    private let tableView = NSTableView()
    private let emptyLabel = NSTextField(labelWithString: "No Activity")
    private var rows: [Row] = []
    /// Counts down the retries and ages the times while the panel is open.
    private var timer: Timer?

    private init() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 420),
            styleMask: [.titled, .closable, .resizable, .utilityWindow],
            backing: .buffered, defer: true
        )
        panel.title = "Activity"
        panel.isFloatingPanel = false
        panel.hidesOnDeactivate = false
        panel.minSize = NSSize(width: 300, height: 160)
        panel.isReleasedWhenClosed = false
        super.init(window: panel)
        panel.setFrameAutosaveName("Activity")
        if !panel.setFrameUsingName("Activity") { panel.center() }

        let column = NSTableColumn(identifier: .init("Activity"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.style = .plain
        tableView.usesAutomaticRowHeights = true
        tableView.intercellSpacing = NSSize(width: 0, height: 0)
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(openChat)

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        tableView.backgroundColor = .clear

        emptyLabel.font = .systemFont(ofSize: 13)
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.alignment = .center

        let content = NSView()
        for view in [scrollView, emptyLabel] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: content.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            emptyLabel.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: content.centerYAnchor),
        ])
        panel.contentView = content

        NotificationCenter.default.addObserver(self, selector: #selector(refresh), name: WebHistoryImporter.activityDidChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(panelWillClose), name: NSWindow.willCloseNotification, object: panel)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Shows the panel, or closes it if it's open (the menu item toggles it, like Mail's).
    func toggle() {
        if window?.isVisible == true {
            close()
        } else {
            showWindow(nil)
            refresh()
            timer?.invalidate()
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
        }
    }

    @objc private func panelWillClose() {
        timer?.invalidate()
        timer = nil
    }

    @objc private func refresh() {
        guard window?.isVisible == true else { return }
        let items = WebChatImporter.shared.activityItems + WebHistoryImporter.shared.activityItems
        rows = []
        let sections: [(WebHistoryImporter.ActivityItem.Section, String)] = [(.upNext, "Up Next"), (.now, "Now"), (.done, "Done")]
        for (section, title) in sections {
            var inSection = items.filter { $0.section == section }
            if section == .done {
                inSection.sort { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
            }
            guard !inSection.isEmpty else { continue }
            rows.append(.header(title))
            rows += inSection.map { .item($0) }
        }
        emptyLabel.isHidden = !rows.isEmpty
        tableView.reloadData()
    }

    @objc private func openChat() {
        let row = tableView.clickedRow
        guard rows.indices.contains(row), case .item(let item) = rows[row], let threadID = item.threadID else { return }
        (NSApp.delegate as? AppDelegate)?.openChat(threadID)
    }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        if case .header = rows[row] { return true }
        return false
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        !self.tableView(tableView, isGroupRow: row)
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        switch rows[row] {
        case .header(let title):
            let id = NSUserInterfaceItemIdentifier("ActivityHeader")
            let cell = tableView.makeView(withIdentifier: id, owner: nil) as? NSTableCellView ?? {
                let cell = NSTableCellView()
                cell.identifier = id
                let label = NSTextField(labelWithString: "")
                label.font = .systemFont(ofSize: 11, weight: .semibold)
                label.textColor = .secondaryLabelColor
                label.translatesAutoresizingMaskIntoConstraints = false
                cell.addSubview(label)
                cell.textField = label
                NSLayoutConstraint.activate([
                    label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 10),
                    label.topAnchor.constraint(equalTo: cell.topAnchor, constant: 6),
                    label.bottomAnchor.constraint(equalTo: cell.bottomAnchor, constant: -4),
                ])
                return cell
            }()
            cell.textField?.stringValue = title
            return cell
        case .item(let item):
            let id = NSUserInterfaceItemIdentifier("ActivityCell")
            let cell = tableView.makeView(withIdentifier: id, owner: nil) as? ActivityCellView ?? {
                let cell = ActivityCellView()
                cell.identifier = id
                return cell
            }()
            cell.configure(item)
            return cell
        }
    }
}

/// A chat in the Activity window (or the chat list): its picture and name, what's read, what's
/// happening, and a progress bar while it's being read.
private final class ActivityCellView: NSTableCellView {
    private let avatar = AvatarView()
    /// In place of the avatar for rows that aren't about one chat.
    private let symbol = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let stateLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let progressBar = NSProgressIndicator()
    private var progressHeight: NSLayoutConstraint!
    private var progressGap: NSLayoutConstraint!

    init() {
        super.init(frame: .zero)
        nameLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        stateLabel.font = .systemFont(ofSize: 11, weight: .medium)
        stateLabel.alignment = .right
        stateLabel.setContentHuggingPriority(.required, for: .horizontal)
        stateLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        detailLabel.font = .systemFont(ofSize: 11)
        detailLabel.textColor = .tertiaryLabelColor
        detailLabel.lineBreakMode = .byTruncatingTail
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.isSelectable = false
        progressBar.style = .bar
        progressBar.controlSize = .small
        progressBar.minValue = 0
        progressBar.maxValue = 1
        symbol.image = NSImage(systemSymbolName: "list.bullet", accessibilityDescription: nil)
        symbol.symbolConfiguration = .init(pointSize: 15, weight: .medium)
        symbol.contentTintColor = .secondaryLabelColor

        let views: [NSView] = [avatar, symbol, nameLabel, stateLabel, detailLabel, statusLabel, progressBar]
        for view in views {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        progressHeight = progressBar.heightAnchor.constraint(equalToConstant: 0)
        progressGap = progressBar.topAnchor.constraint(equalTo: detailLabel.bottomAnchor, constant: 0)
        NSLayoutConstraint.activate([
            avatar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            avatar.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            avatar.widthAnchor.constraint(equalToConstant: 28),
            avatar.heightAnchor.constraint(equalToConstant: 28),
            avatar.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -8),
            symbol.centerXAnchor.constraint(equalTo: avatar.centerXAnchor),
            symbol.centerYAnchor.constraint(equalTo: avatar.centerYAnchor),

            nameLabel.leadingAnchor.constraint(equalTo: avatar.trailingAnchor, constant: 8),
            nameLabel.topAnchor.constraint(equalTo: topAnchor, constant: 7),
            stateLabel.leadingAnchor.constraint(greaterThanOrEqualTo: nameLabel.trailingAnchor, constant: 6),
            stateLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            stateLabel.firstBaselineAnchor.constraint(equalTo: nameLabel.firstBaselineAnchor),

            detailLabel.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            detailLabel.trailingAnchor.constraint(lessThanOrEqualTo: stateLabel.trailingAnchor),
            detailLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 1),

            progressBar.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            progressBar.trailingAnchor.constraint(equalTo: stateLabel.trailingAnchor),
            progressGap,
            progressHeight,

            statusLabel.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            statusLabel.trailingAnchor.constraint(equalTo: stateLabel.trailingAnchor),
            statusLabel.topAnchor.constraint(equalTo: progressBar.bottomAnchor, constant: 3),
            statusLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        // The status wraps to the cell's width.
        statusLabel.preferredMaxLayoutWidth = max(100, bounds.width - 56)
        super.layout()
    }

    func configure(_ item: WebHistoryImporter.ActivityItem) {
        if let threadID = item.threadID {
            let conversation = ChatStore.shared.conversation(threadID)
            let name = conversation?.name ?? "Chat \(threadID)"
            nameLabel.stringValue = name
            avatar.configure(name: name, url: conversation?.avatarURL)
        } else {
            nameLabel.stringValue = item.name ?? ""
        }
        avatar.isHidden = item.threadID == nil
        symbol.isHidden = item.threadID != nil
        statusLabel.stringValue = item.status
        detailLabel.stringValue = Self.detail(item)
        stateLabel.textColor = .secondaryLabelColor
        switch item.kind {
        case .running:
            stateLabel.stringValue = item.progress.map { "\(Int($0 * 100))%" } ?? "Working"
            stateLabel.textColor = .controlAccentColor
        case .queued: stateLabel.stringValue = "Queued"
        case .waiting: stateLabel.stringValue = "Waiting"
        case .done: stateLabel.stringValue = "Done"
        case .retrying: stateLabel.stringValue = "Will Check Again"
        case .needsRestore:
            stateLabel.stringValue = "Needs PIN"
            stateLabel.textColor = .systemOrange
        case .failed:
            stateLabel.stringValue = "Failed"
            stateLabel.textColor = .systemRed
        }
        let running = item.kind == .running
        progressBar.isHidden = !running
        progressHeight.constant = running ? 12 : 0
        progressGap.constant = running ? 4 : 0
        if running {
            if let progress = item.progress {
                progressBar.stopAnimation(nil)
                progressBar.isIndeterminate = false
                progressBar.doubleValue = progress
            } else {
                progressBar.isIndeterminate = true
                progressBar.startAnimation(nil)
            }
        } else {
            progressBar.stopAnimation(nil)
        }
        let past = item.section == .done
        nameLabel.textColor = past ? .secondaryLabelColor : .labelColor
        avatar.alphaValue = past ? 0.6 : 1
        symbol.alphaValue = past ? 0.6 : 1
    }

    /// "Older messages · 10:57, took 23 s".
    private static func detail(_ item: WebHistoryImporter.ActivityItem) -> String {
        var parts = [item.title]
        if let date = item.date {
            let time = Calendar.current.isDateInToday(date)
                ? DateFormatter.localizedString(from: date, dateStyle: .none, timeStyle: .short)
                : DateFormatter.localizedString(from: date, dateStyle: .short, timeStyle: .short)
            switch item.section {
            case .now: parts.append("started \(time)")
            default: parts.append(time)
            }
        }
        if let duration = item.duration {
            let seconds = Int(duration.rounded())
            parts.append(seconds < 60 ? "took \(seconds) s" : "took \(seconds / 60) min \(seconds % 60) s")
        }
        return parts.joined(separator: " · ")
    }
}
