import AppKit

/// Find in Chat's bar above the messages: the search field, how many were found, and Done.
/// Escape (or Done) closes it.
final class ChatSearchBar: NSView, NSSearchFieldDelegate {
    var onChange: ((String) -> Void)?
    var onClose: (() -> Void)?

    let searchField = NSSearchField()
    private let statusLabel = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        searchField.placeholderString = "Search in Chat"
        searchField.delegate = self
        searchField.sendsSearchStringImmediately = true
        searchField.controlSize = .large

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        statusLabel.setContentHuggingPriority(.required, for: .horizontal)

        let done = NSButton(title: "Done", target: self, action: #selector(close))
        done.bezelStyle = .push
        done.controlSize = .large

        let row = NSStackView(views: [searchField, statusLabel, done])
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            searchField.widthAnchor.constraint(greaterThanOrEqualToConstant: 160),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    var status: String {
        get { statusLabel.stringValue }
        set { statusLabel.stringValue = newValue }
    }

    func controlTextDidChange(_ obj: Notification) {
        onChange?(searchField.stringValue)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard commandSelector == #selector(NSResponder.cancelOperation(_:)) else { return false }
        close()
        return true
    }

    @objc private func close() {
        onClose?()
    }
}
