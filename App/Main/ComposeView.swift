import AppKit

protocol ComposeViewDelegate: AnyObject {
    /// `attachments` are the staged files, in the order they appear in the field.
    func composeView(_ view: ComposeView, send text: String, attachments: [URL])
    func composeViewTextDidChange(_ view: ComposeView)
    func composeViewAttach(_ view: ComposeView)
    func composeViewCancelReply(_ view: ComposeView)
}

/// The compose text view: pasting or dropping images/files stages them inline (via
/// `attachmentHandler`); everything else is pasted as plain text.
final class ComposeTextView: NSTextView {
    /// Returns true if the pasteboard held files or images and they were staged.
    var attachmentHandler: ((NSPasteboard) -> Bool)?

    static let attachmentTypes: [NSPasteboard.PasteboardType] =
        [.fileURL, .png, .tiff] + NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }

    override var readablePasteboardTypes: [NSPasteboard.PasteboardType] {
        Self.attachmentTypes + [.string]
    }

    override var acceptableDragTypes: [NSPasteboard.PasteboardType] {
        Self.attachmentTypes + [.string]
    }

    override func paste(_ sender: Any?) {
        if attachmentHandler?(.general) == true { return }
        pasteAsPlainText(sender)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        Self.hasAttachments(sender.draggingPasteboard) ? .copy : super.draggingEntered(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        Self.hasAttachments(sender.draggingPasteboard) ? .copy : super.draggingUpdated(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        if attachmentHandler?(sender.draggingPasteboard) == true { return true }
        return super.performDragOperation(sender)
    }

    static func hasAttachments(_ pasteboard: NSPasteboard) -> Bool {
        pasteboard.availableType(from: attachmentTypes) != nil
    }
}

/// Bottom input bar: [+] [ growing text field ] [😀], with an optional "Replying to…" banner.
/// Images and files are staged inline in the field, like in Messages, and sent with Return.
final class ComposeView: NSView, NSTextViewDelegate {
    weak var delegate: ComposeViewDelegate?

    let textView = ComposeTextView(usingTextLayoutManager: false)
    private let scrollView = NSScrollView()
    private let field = NSView()
    private let placeholder = NSTextField(labelWithString: "Message")
    private let plusButton = NSButton()
    private let emojiButton = NSButton()
    private let replyBanner = NSView()
    private let replyLabel = NSTextField(labelWithString: "")
    private var textHeight = NSLayoutConstraint()
    private var bannerCollapsed = NSLayoutConstraint()

    private static let minTextHeight: CGFloat = 30
    private static let maxTextHeight: CGFloat = 220
    private static let textAttributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 14),
        .foregroundColor: NSColor.labelColor,
    ]

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        // Text input. Rich text only so it can hold inline attachments; text is always plain.
        textView.delegate = self
        textView.isRichText = true
        textView.importsGraphics = false
        textView.attachmentHandler = { [weak self] pasteboard in
            self?.addAttachments(from: pasteboard) ?? false
        }
        textView.allowsUndo = true
        textView.font = .systemFont(ofSize: 14)
        textView.typingAttributes = Self.textAttributes
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 6, height: 7)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = NSSize(width: 0, height: Self.minTextHeight)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = true

        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder

        field.wantsLayer = true
        field.layer?.cornerRadius = 15
        field.layer?.cornerCurve = .continuous
        field.layer?.borderWidth = 1

        placeholder.textColor = .placeholderTextColor
        placeholder.font = .systemFont(ofSize: 14)

        configure(plusButton, symbol: "plus", label: "Attach", action: #selector(attach))
        configure(emojiButton, symbol: "face.smiling", label: "Emoji", action: #selector(showEmoji))

        // Reply banner
        replyBanner.wantsLayer = true
        replyLabel.font = .systemFont(ofSize: 12)
        replyLabel.textColor = .secondaryLabelColor
        replyLabel.lineBreakMode = .byTruncatingTail
        let closeReply = NSButton()
        configure(closeReply, symbol: "xmark.circle.fill", label: "Cancel reply", action: #selector(cancelReply))
        for view in [replyLabel, closeReply] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            replyBanner.addSubview(view)
        }
        replyBanner.isHidden = true

        for view in [replyBanner, plusButton, field, emojiButton] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        for view in [scrollView, placeholder] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            field.addSubview(view)
        }

        textHeight = scrollView.heightAnchor.constraint(equalToConstant: Self.minTextHeight)
        bannerCollapsed = replyBanner.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            replyBanner.topAnchor.constraint(equalTo: topAnchor),
            replyBanner.leadingAnchor.constraint(equalTo: field.leadingAnchor, constant: 6),
            replyBanner.trailingAnchor.constraint(equalTo: field.trailingAnchor),
            bannerCollapsed,
            replyLabel.leadingAnchor.constraint(equalTo: replyBanner.leadingAnchor),
            replyLabel.centerYAnchor.constraint(equalTo: replyBanner.centerYAnchor),
            replyLabel.trailingAnchor.constraint(lessThanOrEqualTo: closeReply.leadingAnchor, constant: -6),
            closeReply.trailingAnchor.constraint(equalTo: replyBanner.trailingAnchor),
            closeReply.centerYAnchor.constraint(equalTo: replyBanner.centerYAnchor),

            field.topAnchor.constraint(equalTo: replyBanner.bottomAnchor, constant: 8),
            field.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
            field.leadingAnchor.constraint(equalTo: plusButton.trailingAnchor, constant: 8),
            field.trailingAnchor.constraint(equalTo: emojiButton.leadingAnchor, constant: -8),

            plusButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            plusButton.bottomAnchor.constraint(equalTo: field.bottomAnchor, constant: -3),
            emojiButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            emojiButton.bottomAnchor.constraint(equalTo: field.bottomAnchor, constant: -3),

            scrollView.leadingAnchor.constraint(equalTo: field.leadingAnchor, constant: 4),
            scrollView.trailingAnchor.constraint(equalTo: field.trailingAnchor, constant: -4),
            scrollView.topAnchor.constraint(equalTo: field.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: field.bottomAnchor),
            textHeight,

            placeholder.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor, constant: 11),
            placeholder.centerYAnchor.constraint(equalTo: field.centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func configure(_ button: NSButton, symbol: String, label: String, action: Selector) {
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        button.symbolConfiguration = .init(pointSize: 16, weight: .medium)
        button.isBordered = false
        button.bezelStyle = .regularSquare
        button.contentTintColor = .secondaryLabelColor
        button.target = self
        button.action = action
        button.toolTip = label
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func updateLayer() {
        field.layer?.borderColor = NSColor.separatorColor.cgColor
        field.layer?.backgroundColor = NSColor.textBackgroundColor.withAlphaComponent(0.6).cgColor
    }

    override var wantsUpdateLayer: Bool { true }

    // MARK: - API

    /// The typed text, without staged attachments.
    var text: String {
        get { textView.string.replacingOccurrences(of: Self.attachmentCharacter, with: "") }
        set {
            draft = NSAttributedString(string: newValue, attributes: Self.textAttributes)
        }
    }

    /// Text and staged attachments, for keeping per-chat drafts.
    var draft: NSAttributedString {
        get { NSAttributedString(attributedString: textView.attributedString()) }
        set {
            textView.textStorage?.setAttributedString(newValue)
            textView.typingAttributes = Self.textAttributes
            textChanged()
        }
    }

    var hasContent: Bool {
        !textView.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static let attachmentCharacter = "\u{FFFC}"

    /// Stages files (e.g. from the open panel or a drop on the chat) at the insertion point.
    func addFiles(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        let insertion = NSMutableAttributedString()
        for url in urls {
            insertion.append(NSAttributedString(attachment: ComposeAttachment(fileURL: url)))
        }
        let range = textView.selectedRange()
        if textView.shouldChangeText(in: range, replacementString: insertion.string) {
            textView.textStorage?.replaceCharacters(in: range, with: insertion)
            textView.didChangeText()
            textView.setSelectedRange(NSRange(location: range.location + insertion.length, length: 0))
        }
        textView.typingAttributes = Self.textAttributes
        focus()
    }

    /// Stages files, file promises (Photos, browsers) or raw image data from a paste or drop.
    @discardableResult
    func addAttachments(from pasteboard: NSPasteboard) -> Bool {
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            addFiles(urls)
            return true
        }
        if let promises = pasteboard.readObjects(forClasses: [NSFilePromiseReceiver.self]) as? [NSFilePromiseReceiver],
           !promises.isEmpty {
            for promise in promises {
                promise.receivePromisedFiles(atDestination: OutgoingMedia.newSlot(), options: [:], operationQueue: .main) { [weak self] url, error in
                    guard error == nil else { return }
                    MainActor.assumeIsolated { self?.addFiles([url]) }
                }
            }
            return true
        }
        // Raw image data, unless the copied thing is primarily text (some apps add a picture of it).
        let candidates: [NSPasteboard.PasteboardType] = [.png, .tiff, .string, .rtf, .html]
        guard let first = pasteboard.types?.first(where: candidates.contains), first == .png || first == .tiff else {
            return false
        }
        for type in [NSPasteboard.PasteboardType.png, .tiff] {
            if let data = pasteboard.data(forType: type), let url = OutgoingMedia.save(imageData: data, type: type) {
                addFiles([url])
                return true
            }
        }
        return false
    }

    func focus() {
        window?.makeFirstResponder(textView)
    }

    func showReply(to name: String, text: String) {
        replyLabel.stringValue = "Replying to \(name): \(text)"
        replyBanner.isHidden = false
        bannerCollapsed.constant = 18
        focus()
    }

    func hideReply() {
        replyBanner.isHidden = true
        bannerCollapsed.constant = 0
    }

    // MARK: - Actions

    @objc private func attach() {
        delegate?.composeViewAttach(self)
    }

    @objc private func showEmoji() {
        focus()
        NSApp.orderFrontCharacterPalette(nil)
    }

    @objc private func cancelReply() {
        delegate?.composeViewCancelReply(self)
    }

    private func send() {
        var attachments: [URL] = []
        let storage = textView.attributedString()
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, _, _ in
            if let attachment = value as? ComposeAttachment {
                attachments.append(attachment.fileURL)
            }
        }
        let text = self.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !attachments.isEmpty else { return }
        delegate?.composeView(self, send: text, attachments: attachments)
        self.text = ""
    }

    // MARK: - NSTextViewDelegate

    func textDidChange(_ notification: Notification) {
        textChanged()
        delegate?.composeViewTextDidChange(self)
    }

    private func textChanged() {
        placeholder.isHidden = !textView.string.isEmpty
        if textView.string.isEmpty {
            textView.typingAttributes = Self.textAttributes
        }
        guard let layoutManager = textView.layoutManager, let container = textView.textContainer else { return }
        layoutManager.ensureLayout(for: container)
        let used = layoutManager.usedRect(for: container).height + textView.textContainerInset.height * 2
        textHeight.constant = min(Self.maxTextHeight, max(Self.minTextHeight, ceil(used)))
    }

    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)):
            let flags = NSApp.currentEvent?.modifierFlags ?? []
            if flags.contains(.shift) || flags.contains(.option) {
                textView.insertNewlineIgnoringFieldEditor(nil)
            } else {
                send()
            }
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            delegate?.composeViewCancelReply(self)
            return true
        default:
            return false
        }
    }
}
