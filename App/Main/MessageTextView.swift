import AppKit

/// Read-only, selectable message text. Unlike NSTextField, NSTextView lets us style links
/// (NSTextField always draws them in the system blue). Sizes itself to its text, wrapping at maxWidth.
final class MessageTextView: NSTextView {
    var maxWidth: CGFloat = 400 {
        didSet { if maxWidth != oldValue { invalidateIntrinsicContentSize() } }
    }

    init() {
        let storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: 400, height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        container.widthTracksTextView = false
        storage.addLayoutManager(layoutManager)
        layoutManager.addTextContainer(container)
        super.init(frame: .zero, textContainer: container)
        isEditable = false
        isSelectable = true
        isRichText = true
        drawsBackground = false
        textContainerInset = .zero
        isVerticallyResizable = false
        isHorizontallyResizable = false
        setContentHuggingPriority(.required, for: .horizontal)
        setContentHuggingPriority(.required, for: .vertical)
        setContentCompressionResistancePriority(.required, for: .vertical)
        unregisterDraggedTypes()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // NSTextView's designated init used by AppKit internals.
    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        super.init(frame: frameRect, textContainer: container)
    }

    func setText(_ text: NSAttributedString) {
        textStorage?.setAttributedString(text)
        invalidateIntrinsicContentSize()
    }

    override var intrinsicContentSize: NSSize {
        guard let layoutManager, let textContainer else { return .zero }
        textContainer.containerSize = NSSize(width: maxWidth, height: .greatestFiniteMagnitude)
        layoutManager.ensureLayout(for: textContainer)
        let used = layoutManager.usedRect(for: textContainer)
        return NSSize(width: ceil(used.width), height: ceil(used.height))
    }

    // MARK: - Selecting text

    /// Off until the message is selected: a click then selects the message (the bubble's click
    /// recognizer) instead of starting a text selection. Links stay clickable.
    var allowsTextSelection = false {
        didSet {
            if !allowsTextSelection { setSelectedRange(NSRange(location: 0, length: 0)) }
            allowedAt = ProcessInfo.processInfo.systemUptime
            window?.invalidateCursorRects(for: self)
        }
    }
    private var allowedAt: TimeInterval = 0

    /// The second click of a double-click whose first click selected the message: that one
    /// reacts (the bubble's recognizer), so the text mustn't track it as a word selection.
    private func continuesSelectingClick(_ event: NSEvent) -> Bool {
        event.clickCount > 1 && ProcessInfo.processInfo.systemUptime - allowedAt < NSEvent.doubleClickInterval + 0.1
    }

    override func mouseDown(with event: NSEvent) {
        if let link = link(at: event) {
            trackLink(link, from: event)
        } else if allowsTextSelection && !continuesSelectingClick(event) {
            super.mouseDown(with: event)
        }
    }

    /// The I-beam once the text can be selected, the arrow before; links get the pointing hand.
    private func updateCursor(_ event: NSEvent) {
        if link(at: event) != nil {
            NSCursor.pointingHand.set()
        } else {
            (allowsTextSelection ? NSCursor.iBeam : NSCursor.arrow).set()
        }
    }

    override func mouseMoved(with event: NSEvent) { updateCursor(event) }
    override func cursorUpdate(with event: NSEvent) { updateCursor(event) }

    override func resetCursorRects() {
        if allowsTextSelection { addCursorRect(bounds, cursor: .iBeam) }
    }

    // MARK: - Links

    /// The link under the event, with its character index and range.
    private func link(at event: NSEvent) -> (url: URL, index: Int, range: NSRange)? {
        let point = convert(event.locationInWindow, from: nil)
        guard let storage = textStorage, storage.length > 0, let layoutManager, let textContainer else { return nil }
        // The nearest glyph, if the point is actually on it.
        let glyph = layoutManager.glyphIndex(for: point, in: textContainer)
        let rect = layoutManager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: textContainer)
        guard rect.contains(point) else { return nil }
        let character = layoutManager.characterIndexForGlyph(at: glyph)
        guard character < storage.length else { return nil }
        var range = NSRange()
        let value = storage.attribute(.link, at: character, effectiveRange: &range)
        guard let url = value as? URL ?? (value as? String).flatMap(URL.init(string:)) else { return nil }
        return (url, character, range)
    }

    /// A click opens the link; dragging takes it out, like a link in Safari.
    private func trackLink(_ link: (url: URL, index: Int, range: NSRange), from event: NSEvent) {
        let start = event.locationInWindow
        while let next = window?.nextEvent(matching: [.leftMouseUp, .leftMouseDragged]) {
            if next.type == .leftMouseUp {
                clicked(onLink: link.url, at: link.index)
                return
            }
            guard LinkDrag.isDrag(from: start, to: next) else { continue }
            guard let layoutManager, let textContainer else { return }
            let glyphs = layoutManager.glyphRange(forCharacterRange: link.range, actualCharacterRange: nil)
            let frame = layoutManager.boundingRect(forGlyphRange: glyphs, in: textContainer)
                .offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
            let title = textStorage?.attributedSubstring(from: link.range).string
            let item = LinkDrag.item(url: link.url, title: title, frame: frame, image: snapshot(in: frame))
            beginDraggingSession(with: [item], event: next, source: self)
            return
        }
    }

    // Read-only text: let files dropped on a bubble fall through to the chat's drop target.
    override var acceptableDragTypes: [NSPasteboard.PasteboardType] { [] }
    override func updateDragTypeRegistration() {
        unregisterDraggedTypes()
    }

    // MARK: - Menus

    /// Right-click shows the message's menu (react, reply, …), or the text menu (Copy, Look Up, …)
    /// once the message is selected.
    override func menu(for event: NSEvent) -> NSMenu? {
        allowsTextSelection ? super.menu(for: event) : enclosingCell?.menu(for: event)
    }

    override func didCloseMenu(_ menu: NSMenu, with event: NSEvent?) {
        super.didCloseMenu(menu, with: event)
        enclosingCell?.didCloseMenu(menu, with: event)
    }

    private var enclosingCell: MessageCellView? {
        var view = superview
        while let current = view, !(current is MessageCellView) {
            view = current.superview
        }
        return view as? MessageCellView
    }
}
