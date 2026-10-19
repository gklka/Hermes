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

/// A 1 pt progress bar (like Safari's page loading), in the chat's tint. It only moves forward
/// during one load, fills up and fades out when it's done, and starts over for another chat.
final class ChatProgressLine: NSView {
    var color: NSColor = BubbleColors.outgoing {
        didSet { applyColor() }
    }
    private let fill = CALayer()
    private var fraction: CGFloat = 0
    private var showing = false
    private var chat: String?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.addSublayer(fill)
        alphaValue = 0
        applyColor()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// `progress`: how far the load is (0…1); nil when there's none.
    func setProgress(_ progress: Double?, chat: String?) {
        if chat != self.chat {
            // Another chat: its own load, from where it is, without animating.
            self.chat = chat
            showing = progress != nil
            fraction = CGFloat(progress ?? 0)
            alphaValue = showing ? 1 : 0
            layoutFill(animated: false)
            return
        }
        if let progress {
            if !showing {
                showing = true
                fraction = 0
                layoutFill(animated: false)
                alphaValue = 1
            }
            // Never back: stages may report a little less than before.
            fraction = max(fraction, CGFloat(progress))
            layoutFill(animated: true)
        } else if showing {
            showing = false
            fraction = 1
            layoutFill(animated: true)
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.4
                context.allowsImplicitAnimation = true
                animator().alphaValue = 0
            }
        }
    }

    override func layout() {
        super.layout()
        layoutFill(animated: false)
    }

    private func layoutFill(animated: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(!animated)
        CATransaction.setAnimationDuration(0.35)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        fill.frame = CGRect(x: 0, y: 0, width: bounds.width * min(1, max(0, fraction)), height: bounds.height)
        CATransaction.commit()
    }

    private func applyColor() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            self.fill.backgroundColor = self.color.cgColor
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColor()
    }

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
