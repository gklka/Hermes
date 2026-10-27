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

    // MARK: - Rubber-band selection (Finder-style)

    /// Whether a window point is on a message's content (so a press there isn't a marquee).
    var hitsMessage: ((NSPoint) -> Bool)?
    /// The message IDs whose bubbles a rect (in table coordinates) covers.
    var messageIDs: ((NSRect) -> [String])?
    /// The current selection, to extend (Shift) or toggle (Command) from while dragging.
    var currentSelection: (() -> Set<String>)?
    /// Applies the selection the marquee produced, with the anchor for a later Shift-click.
    var applyMarqueeSelection: ((Set<String>, String?) -> Void)?

    private lazy var marquee: NSView = {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.selectedContentBackgroundColor.withAlphaComponent(0.2).cgColor
        view.layer?.borderColor = NSColor.selectedContentBackgroundColor.cgColor
        view.layer?.borderWidth = 1
        view.isHidden = true
        return view
    }()

    override func mouseDown(with event: NSEvent) {
        // Only empty space starts a band; a press on a message keeps the normal handling.
        guard messageIDs != nil, !(hitsMessage?(event.locationInWindow) ?? false) else {
            super.mouseDown(with: event)
            return
        }
        let modifiers = event.modifierFlags.intersection([.command, .shift])
        // Shift and Command extend or toggle the existing selection; a plain drag replaces it.
        let base = modifiers.isEmpty ? [] : (currentSelection?() ?? [])
        let start = convert(event.locationInWindow, from: nil)
        var covered: [String] = []
        // A plain press on empty space (no drag) clears the selection.
        apply(base: base, covered: covered, modifiers: modifiers)
        var dragging = false

        while let next = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            if next.type == .leftMouseUp { break }
            autoscroll(with: next)
            let point = convert(next.locationInWindow, from: nil)
            let rect = NSRect(x: min(start.x, point.x), y: min(start.y, point.y),
                              width: abs(point.x - start.x), height: abs(point.y - start.y))
            // Show the rectangle only once a drag begins, so a plain click doesn't flash it.
            if !dragging {
                dragging = true
                addSubview(marquee, positioned: .above, relativeTo: nil)
                marquee.isHidden = false
            }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            marquee.frame = rect
            CATransaction.commit()
            let ids = messageIDs?(rect) ?? []
            if ids != covered {
                covered = ids
                apply(base: base, covered: covered, modifiers: modifiers)
            }
        }
        if dragging {
            marquee.isHidden = true
            marquee.removeFromSuperview()
        }
    }

    /// The selection for the band so far: Command toggles each covered message against the base
    /// selection, Shift (or a plain drag, with an empty base) adds them.
    private func apply(base: Set<String>, covered: [String], modifiers: NSEvent.ModifierFlags) {
        var result = base
        if modifiers.contains(.command) {
            for id in covered {
                if base.contains(id) { result.remove(id) } else { result.insert(id) }
            }
        } else {
            result.formUnion(covered)
        }
        applyMarqueeSelection?(result, covered.last)
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
            let button = CircularButton(title: emoji, target: self, action: #selector(picked(_:)))
            button.isBordered = false
            button.font = .systemFont(ofSize: 22)
            button.wantsLayer = true
            button.layer?.cornerRadius = 17
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

/// A round button whose keyboard focus ring is a circle, matching its shape (the default ring
/// is a rounded rectangle around the bounds).
private final class CircularButton: NSButton {
    override func drawFocusRingMask() {
        NSBezierPath(ovalIn: bounds).fill()
    }

    override var focusRingMaskBounds: NSRect { bounds }
}
