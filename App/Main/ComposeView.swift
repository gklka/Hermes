import AppKit

protocol ComposeViewDelegate: AnyObject {
    /// `attachments` are the staged files, in the order they appear in the field.
    func composeView(_ view: ComposeView, send text: String, attachments: [URL])
    func composeViewTextDidChange(_ view: ComposeView)
    func composeViewCancelReply(_ view: ComposeView)
}

/// The compose text view: pasting or dropping images/files stages them inline (via
/// `attachmentHandler`); everything else is pasted as plain text.
final class ComposeTextView: NSTextView {
    /// Returns true if the pasteboard held files or images and they were staged.
    var attachmentHandler: ((NSPasteboard) -> Bool)?

    static let attachmentTypes: [NSPasteboard.PasteboardType] =
        [.fileURL] + OutgoingMedia.imagePasteboardTypes + NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }

    override var readablePasteboardTypes: [NSPasteboard.PasteboardType] {
        Self.attachmentTypes + [.string]
    }

    override var acceptableDragTypes: [NSPasteboard.PasteboardType] {
        Self.attachmentTypes + [.string]
    }

    /// Returns true if the pasted text was a link and was inserted as its preview.
    var linkHandler: ((String) -> Bool)?

    override func paste(_ sender: Any?) {
        if attachmentHandler?(.general) == true { return }
        // Inserted directly: pasteAsPlainText inserts nothing in this (rich text) view.
        guard let string = NSPasteboard.general.string(forType: .string), !string.isEmpty else { return }
        if linkHandler?(string) == true { return }
        insertText(string, replacementRange: selectedRange())
    }

    /// Continuity Camera (Insert from iPhone) and services: staged like a paste, instead of
    /// a full-size picture in the text.
    override func readSelection(from pboard: NSPasteboard) -> Bool {
        CoreBridge.shared.log("Compose: inserting from services, types \(pboard.types?.map(\.rawValue) ?? [])")
        if attachmentHandler?(pboard) == true { return true }
        return super.readSelection(from: pboard)
    }

    override func readSelection(from pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        if attachmentHandler?(pboard) == true { return true }
        return super.readSelection(from: pboard, type: type)
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

/// Turns text emoticons like ":)" into emoji as you type, like Messenger does.
enum Emoticons {
    static func emoji(for token: String) -> String? { map[token] }

    private static let map: [String: String] = [
        ":)": "🙂", ":-)": "🙂", "(:": "🙂",
        ":(": "🙁", ":-(": "🙁",
        ":D": "😀", ":-D": "😀",
        "xD": "😆", "XD": "😆",
        ";)": "😉", ";-)": "😉",
        ":P": "😛", ":-P": "😛", ":p": "😛", ":-p": "😛",
        ":O": "😮", ":-O": "😮", ":o": "😮", ":-o": "😮",
        ":'(": "😢",
        ":*": "😘", ":-*": "😘",
        ":/": "😕", ":-/": "😕",
        ":|": "😐", ":-|": "😐",
        ">:(": "😠", ">:-(": "😠",
        "B)": "😎", "B-)": "😎", "8)": "😎", "8-)": "😎",
        "^_^": "😊", "-_-": "😑",
        "<3": "❤️", "</3": "💔",
    ]

}

/// A pasted link, shown in the field as its preview card (like in Messages) and sent as the link.
final class ComposeLinkAttachment: NSTextAttachment {
    let url: URL

    init(url: URL, preview: LinkPreviews.Preview) {
        self.url = url
        super.init(data: nil, ofType: nil)
        update(preview)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private static let width: CGFloat = 240

    func update(_ preview: LinkPreviews.Preview) {
        attachmentCell = NSTextAttachmentCell(imageCell: Self.card(preview))
    }

    /// The card: picture (cropped to the usual share-picture shape), title and site.
    private static func card(_ preview: LinkPreviews.Preview) -> NSImage {
        let hasPicture = preview.image != nil || preview.imageSize != nil
        let pictureHeight = hasPicture ? (width / 1.91).rounded() : 0
        let size = NSSize(width: width, height: pictureHeight + 44)
        // Drawn when displayed, so the colors follow the appearance.
        return NSImage(size: size, flipped: true) { rect in
            NSBezierPath(roundedRect: rect, xRadius: 12, yRadius: 12).addClip()
            BubbleColors.incoming.setFill()
            rect.fill()
            if hasPicture {
                let pictureRect = NSRect(x: 0, y: 0, width: rect.width, height: pictureHeight)
                if let image = preview.image, image.size.width > 0, image.size.height > 0 {
                    let scale = max(pictureRect.width / image.size.width, pictureRect.height / image.size.height)
                    let crop = NSSize(width: pictureRect.width / scale, height: pictureRect.height / scale)
                    let source = NSRect(
                        x: (image.size.width - crop.width) / 2, y: (image.size.height - crop.height) / 2,
                        width: crop.width, height: crop.height
                    )
                    image.draw(in: pictureRect, from: source, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
                } else {
                    NSColor.quaternaryLabelColor.setFill()
                    pictureRect.fill()
                }
            }
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byTruncatingTail
            let title = NSAttributedString(string: preview.title, attributes: [
                .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: paragraph,
            ])
            title.draw(in: NSRect(x: 10, y: pictureHeight + 7, width: rect.width - 20, height: 16))
            let site = NSAttributedString(string: preview.site ?? "", attributes: [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: NSColor.secondaryLabelColor,
                .paragraphStyle: paragraph,
            ])
            site.draw(in: NSRect(x: 10, y: pictureHeight + 24, width: rect.width - 20, height: 15))
            return true
        }
    }
}

/// Bottom input bar: [ growing text field ] [👍], with an optional "Replying to…" banner.
/// Images and files are staged inline in the field, like in Messages, and sent with Return.
/// The button on the right sends the chat's quick reaction, or the message while there is one.
final class ComposeView: NSView, NSTextViewDelegate {
    weak var delegate: ComposeViewDelegate?

    let textView = ComposeTextView(usingTextLayoutManager: false)
    private let scrollView = NSScrollView()
    /// The field and the button are Liquid Glass, like in Messages; messages scroll under them.
    private let fieldGlass = NSGlassEffectView()
    private let field = NSView()
    private let placeholder = NSTextField(labelWithString: "Message")
    private let buttonGlass = NSGlassEffectView()
    private let actionButton = NSButton()
    /// The chat's custom quick reaction emoji; nil for the default like (👍).
    private var quickEmoji: String?
    private var tint: NSColor = BubbleColors.outgoing
    private let replyBanner = NSView()
    private let replyLabel = NSTextField(labelWithString: "")
    private var textHeight = NSLayoutConstraint()
    private var bannerCollapsed = NSLayoutConstraint()

    private static let minTextHeight: CGFloat = 34
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
        textView.linkHandler = { [weak self] string in
            self?.insertLinkPreview(string) ?? false
        }
        textView.allowsUndo = true
        textView.font = .systemFont(ofSize: 14)
        textView.typingAttributes = Self.textAttributes
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 6, height: 9)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = NSSize(width: 0, height: Self.minTextHeight)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = true
        textView.writingToolsBehavior = .none

        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder

        fieldGlass.cornerRadius = Self.minTextHeight / 2
        fieldGlass.contentView = field
        buttonGlass.cornerRadius = Self.minTextHeight / 2
        buttonGlass.contentView = actionButton

        placeholder.textColor = .placeholderTextColor
        placeholder.font = .systemFont(ofSize: 14)

        actionButton.isBordered = false
        actionButton.bezelStyle = .regularSquare
        actionButton.target = self
        actionButton.action = #selector(actionButtonClicked)
        actionButton.setContentHuggingPriority(.required, for: .horizontal)
        updateActionButton()

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

        for view in [replyBanner, fieldGlass, buttonGlass] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        field.translatesAutoresizingMaskIntoConstraints = false
        actionButton.translatesAutoresizingMaskIntoConstraints = false
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

            fieldGlass.topAnchor.constraint(equalTo: replyBanner.bottomAnchor, constant: 8),
            fieldGlass.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
            fieldGlass.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            fieldGlass.trailingAnchor.constraint(equalTo: buttonGlass.leadingAnchor, constant: -8),
            field.topAnchor.constraint(equalTo: fieldGlass.topAnchor),
            field.bottomAnchor.constraint(equalTo: fieldGlass.bottomAnchor),
            field.leadingAnchor.constraint(equalTo: fieldGlass.leadingAnchor),
            field.trailingAnchor.constraint(equalTo: fieldGlass.trailingAnchor),

            buttonGlass.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            buttonGlass.bottomAnchor.constraint(equalTo: fieldGlass.bottomAnchor),
            buttonGlass.widthAnchor.constraint(equalToConstant: Self.minTextHeight),
            buttonGlass.heightAnchor.constraint(equalToConstant: Self.minTextHeight),
            actionButton.topAnchor.constraint(equalTo: buttonGlass.topAnchor),
            actionButton.bottomAnchor.constraint(equalTo: buttonGlass.bottomAnchor),
            actionButton.leadingAnchor.constraint(equalTo: buttonGlass.leadingAnchor),
            actionButton.trailingAnchor.constraint(equalTo: buttonGlass.trailingAnchor),

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

    // MARK: - API

    /// The typed text, without staged files; link cards become their links (set apart by spaces).
    var text: String {
        get {
            let storage = textView.attributedString()
            var result = ""
            var afterLink = false
            storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
                if let link = value as? ComposeLinkAttachment {
                    if let last = result.last, !last.isWhitespace { result += " " }
                    result += link.url.absoluteString
                    afterLink = true
                    return
                }
                let part = (storage.string as NSString).substring(with: range)
                    .replacingOccurrences(of: Self.attachmentCharacter, with: "")
                if afterLink, let first = part.first, !first.isWhitespace { result += " " }
                result += part
                afterLink = afterLink && part.isEmpty
            }
            return result
        }
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
        // Raw image data, unless the copied thing is primarily text (some apps add a picture of it).
        let imageTypes = OutgoingMedia.imagePasteboardTypes
        let candidates = imageTypes + [.string, .rtf, .html]
        let isImage = pasteboard.types?.first(where: candidates.contains).map(imageTypes.contains) ?? false
        // An encoded photo comes first: Continuity Camera also offers a file promise that's never kept.
        if isImage, addImage(from: pasteboard, types: [.png, .jpeg, .heic]) {
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
        return isImage && addImage(from: pasteboard, types: [.tiff])
    }

    private func addImage(from pasteboard: NSPasteboard, types: [NSPasteboard.PasteboardType]) -> Bool {
        for type in types {
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

    /// The chat's quick reaction (nil: the default like) and theme color for the button, the
    /// cursor and selected text.
    func setQuickReaction(_ emoji: String?, tint: NSColor?) {
        quickEmoji = emoji?.isEmpty == false ? emoji : nil
        self.tint = tint ?? BubbleColors.outgoing
        textView.insertionPointColor = self.tint
        textView.selectedTextAttributes = [.backgroundColor: self.tint.withAlphaComponent(0.35)]
        updateActionButton()
    }

    /// Send arrow while there's something to send, otherwise the quick reaction.
    private func updateActionButton() {
        actionButton.title = ""
        actionButton.image = nil
        if hasContent {
            actionButton.image = NSImage(systemSymbolName: "arrow.up.circle.fill", accessibilityDescription: "Send")
            actionButton.symbolConfiguration = .init(pointSize: 22, weight: .regular)
            actionButton.contentTintColor = tint
            actionButton.toolTip = "Send"
        } else if let quickEmoji {
            actionButton.attributedTitle = NSAttributedString(string: quickEmoji, attributes: [.font: NSFont.systemFont(ofSize: 20)])
            actionButton.toolTip = "Send \(quickEmoji)"
        } else {
            actionButton.image = NSImage(systemSymbolName: "hand.thumbsup.fill", accessibilityDescription: "Like")
            actionButton.symbolConfiguration = .init(pointSize: 18, weight: .regular)
            actionButton.contentTintColor = tint
            actionButton.toolTip = "Send a Like"
        }
    }

    func showReply(to name: String, text: String) {
        showBanner("Replying to \(name): \(text)")
    }

    /// Puts a sent message's text in the field to edit it; Return saves, Escape cancels.
    func showEditing(_ text: String) {
        self.text = text
        showBanner("Editing message")
        textView.setSelectedRange(NSRange(location: textView.string.utf16.count, length: 0))
    }

    private func showBanner(_ text: String) {
        replyLabel.stringValue = text
        replyBanner.isHidden = false
        bannerCollapsed.constant = 18
        focus()
    }

    func hideReply() {
        replyBanner.isHidden = true
        bannerCollapsed.constant = 0
    }

    // MARK: - Actions

    @objc private func actionButtonClicked() {
        if hasContent {
            send()
        } else {
            sendQuickReaction()
        }
        focus()
    }

    /// Sends the chat's quick reaction (👍 by default), keeping what's typed.
    func sendQuickReaction() {
        delegate?.composeView(self, send: quickEmoji ?? "👍", attachments: [])
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
        // An emoticon right before Return hasn't been replaced yet (that happens at the next space).
        replaceEmoticon(before: textView.string.utf16.count)
        let text = self.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !attachments.isEmpty else { return }
        // Cleared first: the delegate may put something back (the draft from before editing).
        self.text = ""
        delegate?.composeView(self, send: text, attachments: attachments)
    }

    // MARK: - Link preview

    /// A pasted web link goes into the field as its preview card (Facebook links, which can't
    /// be previewed, stay text). Returns false for anything else.
    private func insertLinkPreview(_ string: String) -> Bool {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard LinkPreviews.isOnlyLink(trimmed),
              case .web(let url) = LinkPreviews.source(text: trimmed, attachments: []) else { return false }
        let source = LinkPreviews.Source.web(url)
        let attachment = ComposeLinkAttachment(url: url, preview: LinkPreviews.shared.preview(for: source))
        let insertion = NSMutableAttributedString(attachment: attachment)
        insertion.addAttributes(Self.textAttributes, range: NSRange(location: 0, length: insertion.length))
        let range = textView.selectedRange()
        guard textView.shouldChangeText(in: range, replacementString: insertion.string) else { return true }
        textView.textStorage?.replaceCharacters(in: range, with: insertion)
        textView.didChangeText()
        textView.setSelectedRange(NSRange(location: range.location + insertion.length, length: 0))
        textView.typingAttributes = Self.textAttributes
        Task { [weak self] in
            guard let loaded = await LinkPreviews.shared.load(source) else { return }
            self?.updateCard(attachment, with: loaded)
        }
        return true
    }

    /// Redraws a card in the field once its preview has loaded (its size may change).
    private func updateCard(_ attachment: ComposeLinkAttachment, with preview: LinkPreviews.Preview) {
        guard let storage = textView.textStorage else { return }
        attachment.update(preview)
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, range, stop in
            guard value as? ComposeLinkAttachment === attachment else { return }
            textView.layoutManager?.invalidateLayout(forCharacterRange: range, actualCharacterRange: nil)
            textView.layoutManager?.invalidateDisplay(forCharacterRange: range)
            stop.pointee = true
        }
        textChanged()
    }

    // MARK: - NSTextViewDelegate

    func textDidChange(_ notification: Notification) {
        textChanged()
        delegate?.composeViewTextDidChange(self)
    }

    private func textChanged() {
        placeholder.isHidden = !textView.string.isEmpty
        updateActionButton()
        if textView.string.isEmpty {
            textView.typingAttributes = Self.textAttributes
        }
        guard let layoutManager = textView.layoutManager, let container = textView.textContainer else { return }
        layoutManager.ensureLayout(for: container)
        let used = layoutManager.usedRect(for: container).height + textView.textContainerInset.height * 2
        textHeight.constant = min(Self.maxTextHeight, max(Self.minTextHeight, ceil(used)))
        if textView.string.isEmpty {
            // After a tall picture is sent, the field shrinks but would stay scrolled down,
            // leaving the cursor below the placeholder.
            textView.sizeToFit()
            scrollView.contentView.scroll(to: .zero)
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
    }

    /// Typing a space or newline after an emoticon (":)") turns it into its emoji; Undo brings it back.
    func textView(_ textView: NSTextView, shouldChangeTextIn range: NSRange, replacementString: String?) -> Bool {
        guard let replacementString, replacementString.count == 1, replacementString.first?.isWhitespace == true,
              let tokenRange = emoticonRange(before: range.location),
              let emoji = Emoticons.emoji(for: (textView.string as NSString).substring(with: tokenRange)) else { return true }
        textView.insertText(emoji + replacementString, replacementRange: NSRange(
            location: tokenRange.location, length: range.location + range.length - tokenRange.location))
        return false
    }

    /// The whitespace-delimited word ending at `location`, if any.
    private func emoticonRange(before location: Int) -> NSRange? {
        let string = textView.string as NSString
        guard location > 0, location <= string.length else { return nil }
        var start = location
        while start > 0, let scalar = Unicode.Scalar(string.character(at: start - 1)),
              !CharacterSet.whitespacesAndNewlines.contains(scalar) {
            start -= 1
        }
        return start < location ? NSRange(location: start, length: location - start) : nil
    }

    private func replaceEmoticon(before location: Int) {
        guard let range = emoticonRange(before: location),
              let emoji = Emoticons.emoji(for: (textView.string as NSString).substring(with: range)) else { return }
        textView.insertText(emoji, replacementRange: range)
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
