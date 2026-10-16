import AppKit

/// An incoming call, in the top-right corner of the screen like FaceTime's: the caller, and the
/// buttons of the web app's call dialog (red ones decline, green ones answer).
final class IncomingCallPanel: NSPanel {
    struct Button: Decodable {
        /// Its position among the dialog's buttons (marked in the page).
        let index: Int
        /// In the account's language.
        let label: String
        /// "decline", "accept" or "" (unknown).
        let tone: String
    }

    private let buttons: [Button]
    private let onButton: (Button) -> Void

    init(name: String, detail: String, conversation: Conversation?, imageURL: String?,
         buttons: [Button], onButton: @escaping (Button) -> Void) {
        self.buttons = buttons
        self.onButton = onButton
        super.init(contentRect: NSRect(x: 0, y: 0, width: 380, height: 76),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        isReleasedWhenClosed = false

        let background = NSVisualEffectView()
        background.material = .popover
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 18
        background.layer?.masksToBounds = true

        let avatar: NSView
        if let conversation {
            let view = ConversationAvatarView()
            view.configure(conversation, selfID: ChatStore.shared.account?.id)
            avatar = view
        } else {
            let view = AvatarView()
            view.configure(name: name, url: imageURL)
            avatar = view
        }
        avatar.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            avatar.widthAnchor.constraint(equalToConstant: 44),
            avatar.heightAnchor.constraint(equalToConstant: 44),
        ])

        let nameLabel = NSTextField(labelWithString: name)
        nameLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        let detailLabel = NSTextField(labelWithString: detail)
        detailLabel.font = .systemFont(ofSize: 12)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.isHidden = detail.isEmpty
        for label in [nameLabel, detailLabel] {
            label.lineBreakMode = .byTruncatingTail
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        let labels = NSStackView(views: [nameLabel, detailLabel])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 2

        let buttonViews = buttons.map(makeButton)
        let row = NSStackView(views: [avatar, labels] + buttonViews)
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        row.setCustomSpacing(12, after: avatar)
        row.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 14),
            row.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -14),
            row.centerYAnchor.constraint(equalTo: background.centerYAnchor),
        ])
        contentView = background
    }

    /// Top right of the screen with the menu bar.
    func present() {
        if let screen = NSScreen.screens.first {
            let visible = screen.visibleFrame
            setFrameOrigin(NSPoint(x: visible.maxX - frame.width - 16, y: visible.maxY - frame.height - 16))
        }
        orderFrontRegardless()
    }

    override var canBecomeKey: Bool { true }

    /// A round red or green button for declining or answering, otherwise a button with the page's label.
    private func makeButton(_ button: Button) -> NSView {
        let view: NSButton
        if button.tone.isEmpty {
            view = NSButton(title: button.label, target: self, action: #selector(pressed(_:)))
            view.bezelStyle = .push
        } else {
            let accepts = buttons.filter { $0.tone == "accept" }
            // A second answer button is answering with video.
            let symbol = button.tone == "decline" ? "phone.down.fill"
                : (accepts.count > 1 && accepts.last?.index == button.index ? "video.fill" : "phone.fill")
            view = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: button.label) ?? NSImage(),
                            target: self, action: #selector(pressed(_:)))
            view.isBordered = false
            view.wantsLayer = true
            view.layer?.backgroundColor = (button.tone == "decline" ? NSColor.systemRed : NSColor.systemGreen).cgColor
            view.layer?.cornerRadius = 18
            view.contentTintColor = .white
            view.imageScaling = .scaleProportionallyDown
            view.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                view.widthAnchor.constraint(equalToConstant: 36),
                view.heightAnchor.constraint(equalToConstant: 36),
            ])
        }
        view.tag = button.index
        view.toolTip = button.label
        return view
    }

    @objc private func pressed(_ sender: NSButton) {
        guard let button = buttons.first(where: { $0.index == sender.tag }) else { return }
        onButton(button)
    }
}
