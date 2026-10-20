import AppKit

/// Someone who can be tagged with @ in the compose field.
struct MentionCandidate: Equatable {
    let id: String
    let name: String
    let avatarURL: String?
}

/// The list of people that opens over the compose field while an "@name" is typed. It never
/// becomes key, so typing stays in the field; the field forwards the arrow keys, Return, Tab and
/// Escape to it.
final class MentionPicker: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    /// Called with the person clicked or chosen with Return/Tab.
    var onPick: ((MentionCandidate) -> Void)?

    private let panel: NSPanel
    private let tableView = PickerTableView()
    private var candidates: [MentionCandidate] = []
    private weak var parentWindow: NSWindow?

    private static let rowHeight: CGFloat = 30
    private static let maxVisibleRows = 6
    private static let width: CGFloat = 260
    private static let padding: CGFloat = 5

    var isVisible: Bool { panel.isVisible }

    override init() {
        panel = NonKeyPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        super.init()
        panel.isFloatingPanel = false
        panel.hasShadow = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hidesOnDeactivate = true
        // No fade-in; the list should appear at once, not flash in.
        panel.animationBehavior = .none

        let background = NSVisualEffectView()
        background.material = .popover
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 10
        background.layer?.masksToBounds = true

        let column = NSTableColumn(identifier: .init("Name"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.style = .plain
        tableView.rowHeight = Self.rowHeight
        tableView.intercellSpacing = .zero
        tableView.backgroundColor = .clear
        tableView.selectionHighlightStyle = .regular
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.action = #selector(clicked)

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets(top: Self.padding, left: 0, bottom: Self.padding, right: 0)
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: background.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: background.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: background.trailingAnchor),
        ])
        panel.contentView = background
    }

    /// Shows the people above `anchor` (the "@" in screen coordinates), the first one selected.
    /// Pass `below: true` to drop it under the anchor instead (for a field near the top of a window).
    func show(_ candidates: [MentionCandidate], above anchor: NSRect, in window: NSWindow, below: Bool = false) {
        let previous = selected
        self.candidates = candidates
        tableView.reloadData()
        let index = previous.flatMap { candidates.firstIndex(of: $0) } ?? 0
        tableView.selectRowIndexes([index], byExtendingSelection: false)
        tableView.scrollRowToVisible(index)

        let rows = CGFloat(min(candidates.count, Self.maxVisibleRows))
        let height = rows * Self.rowHeight + Self.padding * 2
        // Above the line being typed, kept inside the window.
        var x = anchor.minX - 12
        x = min(max(x, window.frame.minX + 8), window.frame.maxX - Self.width - 8)
        let y = below ? anchor.minY - height - 6 : anchor.maxY + 6
        let frame = NSRect(x: x, y: y, width: Self.width, height: height)
        panel.setFrame(frame, display: true)
        if parentWindow !== window {
            parentWindow?.removeChildWindow(panel)
            parentWindow = window
        }
        if panel.parent == nil {
            window.addChildWindow(panel, ordered: .above)
        }
        panel.orderFront(nil)
    }

    func hide() {
        guard panel.isVisible || panel.parent != nil else { return }
        parentWindow?.removeChildWindow(panel)
        panel.orderOut(nil)
    }

    var selected: MentionCandidate? {
        let row = tableView.selectedRow
        return candidates.indices.contains(row) ? candidates[row] : nil
    }

    /// The arrow keys: moves the selection, wrapping around.
    func moveSelection(by delta: Int) {
        guard !candidates.isEmpty else { return }
        let row = (max(tableView.selectedRow, 0) + delta + candidates.count) % candidates.count
        tableView.selectRowIndexes([row], byExtendingSelection: false)
        tableView.scrollRowToVisible(row)
    }

    func pickSelected() {
        if let selected { onPick?(selected) }
    }

    @objc private func clicked() {
        let row = tableView.clickedRow
        guard candidates.indices.contains(row) else { return }
        onPick?(candidates[row])
    }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int { candidates.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("MentionCell")
        let cell = tableView.makeView(withIdentifier: id, owner: nil) as? MentionCellView ?? {
            let cell = MentionCellView()
            cell.identifier = id
            return cell
        }()
        cell.configure(candidates[row])
        return cell
    }
}

/// The list's panel: clicks work in it without taking focus from the compose field.
private final class NonKeyPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Picks on the first click, though its window isn't key.
private final class PickerTableView: NSTableView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// A person in the list: avatar and name.
private final class MentionCellView: NSTableCellView {
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
        textField = nameLabel
        NSLayoutConstraint.activate([
            avatar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            avatar.centerYAnchor.constraint(equalTo: centerYAnchor),
            avatar.widthAnchor.constraint(equalToConstant: 22),
            avatar.heightAnchor.constraint(equalToConstant: 22),
            nameLabel.leadingAnchor.constraint(equalTo: avatar.trailingAnchor, constant: 8),
            nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10),
            nameLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(_ candidate: MentionCandidate) {
        nameLabel.stringValue = candidate.name
        avatar.configure(name: candidate.name, url: candidate.avatarURL)
    }
}
