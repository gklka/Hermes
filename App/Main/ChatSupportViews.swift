import AppKit

/// The message table. A table view keeps mouse-downs for itself (row tracking) unless the
/// clicked subview opts in, so attachments get them here and can be dragged out.
final class ChatTableView: NSTableView {
    override func validateProposedFirstResponder(_ responder: NSResponder, for event: NSEvent?) -> Bool {
        if event?.type == .leftMouseDown, responder is AttachmentView || responder is ReactionsBadge || responder is CaptionCellView {
            return true
        }
        return super.validateProposedFirstResponder(responder, for: event)
    }
}

/// Shows things (animations) without taking any clicks, scrolls or drags from what's under it.
final class PassthroughView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Accepts files and images dragged anywhere onto the conversation; they're staged in the
/// compose field.
final class DropTargetView: NSView {
    var onDrop: ((NSPasteboard) -> Bool)?
    var onStartLiveResize: (() -> Void)?
    var onEndLiveResize: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes(ComposeTextView.attachmentTypes)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewWillStartLiveResize() {
        super.viewWillStartLiveResize()
        onStartLiveResize?()
    }

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        onEndLiveResize?()
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        ComposeTextView.hasAttachments(sender.draggingPasteboard) ? .copy : []
    }

    // Called continuously during the drag; without it the drop isn't accepted.
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        draggingEntered(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        onDrop?(sender.draggingPasteboard) ?? false
    }
}

/// Row of emoji buttons shown on double-click, like Messages' tapbacks.
final class TapbackPicker: NSViewController {
    var onPick: ((String) -> Void)?
    private let choices: [String]
    private let current: String?

    init(choices: [String], current: String?) {
        self.choices = choices
        self.current = current
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 6, bottom: 4, right: 6)
        for emoji in choices {
            let button = NSButton(title: emoji, target: self, action: #selector(picked(_:)))
            button.isBordered = false
            button.font = .systemFont(ofSize: 22)
            button.wantsLayer = true
            button.layer?.cornerRadius = 15
            if emoji == current {
                button.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.3).cgColor
            }
            button.widthAnchor.constraint(equalToConstant: 34).isActive = true
            button.heightAnchor.constraint(equalToConstant: 34).isActive = true
            stack.addArrangedSubview(button)
        }
        view = stack
    }

    @objc private func picked(_ sender: NSButton) {
        onPick?(sender.title)
    }
}
