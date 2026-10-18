import AppKit

protocol ComposeViewDelegate: AnyObject {
    /// `attachments` are the staged files, in the order they appear in the field.
    func composeView(_ view: ComposeView, send text: String, mentions: [Mention], attachments: [URL])
    func composeViewTextDidChange(_ view: ComposeView)
    func composeViewCancelReply(_ view: ComposeView)
    /// The + button's menu: Attach File… and (where polls can be made) Create Poll….
    func composeViewAttachFiles(_ view: ComposeView)
    func composeViewCanCreatePoll(_ view: ComposeView) -> Bool
    /// A poll made in the field: its choices, and the question typed under them.
    func composeView(_ view: ComposeView, createPoll question: String, options: [String])
    /// Choices added to a sent poll, and a message typed with them (may be empty).
    func composeView(_ view: ComposeView, addChoices choices: [String], to poll: Poll, comment: String)
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

/// Bottom input bar: [+] [ growing text field ] [👍], with an optional "Replying to…" banner.
/// The + button's menu attaches files or creates a poll; a poll is made in the field, like in
/// Messages (its choices above the text, which is the question).
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
    private let plusGlass = NSGlassEffectView()
    /// Opens the menu with Attach File… and Create Poll….
    private let plusButton = NSButton()
    /// While making a poll (or adding choices to one): its choices, above the text.
    private let pollPanel = ComposePollPanel()
    private let pollSeparator = NSBox()
    private var textTopToField = NSLayoutConstraint()
    private var textTopToPoll = NSLayoutConstraint()
    var isMakingPoll: Bool { !pollPanel.isHidden }
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

    /// People who can be tagged by typing @ (a group chat's members); empty: no tagging.
    var mentionCandidates: [MentionCandidate] = [] {
        didSet {
            if mentionCandidates != oldValue { updateMentionPicker() }
        }
    }
    private let mentionPicker = MentionPicker()
    /// The "@name" being typed, which a pick replaces.
    private var mentionQueryRange: NSRange?
    /// Marks a tag in the field ("@Anna"), with the person's ID.
    private static let mentionKey = NSAttributedString.Key("HermesMention")
    private static let mentionFont = NSFont.boldSystemFont(ofSize: 14)

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
        mentionPicker.onPick = { [weak self] candidate in
            self?.insertMention(candidate)
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
        // The glass around the field would otherwise add insets, shifting the text off center.
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsetsZero

        fieldGlass.cornerRadius = Self.minTextHeight / 2
        fieldGlass.contentView = field
        buttonGlass.cornerRadius = Self.minTextHeight / 2
        buttonGlass.contentView = actionButton
        plusGlass.cornerRadius = Self.minTextHeight / 2
        plusGlass.contentView = plusButton

        plusButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "More")
        plusButton.symbolConfiguration = .init(pointSize: 15, weight: .semibold)
        plusButton.isBordered = false
        plusButton.bezelStyle = .regularSquare
        plusButton.contentTintColor = tint
        plusButton.target = self
        plusButton.action = #selector(plusClicked)
        plusButton.toolTip = "Attach a file or create a poll"

        pollPanel.isHidden = true
        pollPanel.onChange = { [weak self] in self?.updateActionButton() }
        pollPanel.onClose = { [weak self] in self?.endPoll() }
        pollPanel.onFinishChoices = { [weak self] in self?.focus() }
        pollSeparator.boxType = .separator
        pollSeparator.isHidden = true

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

        for view in [replyBanner, plusGlass, fieldGlass, buttonGlass] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        field.translatesAutoresizingMaskIntoConstraints = false
        actionButton.translatesAutoresizingMaskIntoConstraints = false
        plusButton.translatesAutoresizingMaskIntoConstraints = false
        for view in [pollPanel, pollSeparator, scrollView, placeholder] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            field.addSubview(view)
        }
        textTopToField = scrollView.topAnchor.constraint(equalTo: field.topAnchor)
        textTopToPoll = scrollView.topAnchor.constraint(equalTo: pollSeparator.bottomAnchor, constant: 2)

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
            plusGlass.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            plusGlass.bottomAnchor.constraint(equalTo: fieldGlass.bottomAnchor),
            plusGlass.widthAnchor.constraint(equalToConstant: Self.minTextHeight),
            plusGlass.heightAnchor.constraint(equalToConstant: Self.minTextHeight),
            plusButton.topAnchor.constraint(equalTo: plusGlass.topAnchor),
            plusButton.bottomAnchor.constraint(equalTo: plusGlass.bottomAnchor),
            plusButton.leadingAnchor.constraint(equalTo: plusGlass.leadingAnchor),
            plusButton.trailingAnchor.constraint(equalTo: plusGlass.trailingAnchor),

            fieldGlass.leadingAnchor.constraint(equalTo: plusGlass.trailingAnchor, constant: 8),
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
            textTopToField,
            scrollView.bottomAnchor.constraint(equalTo: field.bottomAnchor),
            textHeight,

            pollPanel.topAnchor.constraint(equalTo: field.topAnchor, constant: 8),
            pollPanel.leadingAnchor.constraint(equalTo: field.leadingAnchor, constant: 8),
            pollPanel.trailingAnchor.constraint(equalTo: field.trailingAnchor, constant: -8),
            pollSeparator.topAnchor.constraint(equalTo: pollPanel.bottomAnchor, constant: 8),
            pollSeparator.leadingAnchor.constraint(equalTo: field.leadingAnchor, constant: 18),
            pollSeparator.trailingAnchor.constraint(equalTo: field.trailingAnchor, constant: -18),

            placeholder.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor, constant: 11),
            placeholder.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
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
        get { composed().text }
        set {
            draft = NSAttributedString(string: newValue, attributes: Self.textAttributes)
        }
    }

    /// The typed text (see `text`) and the people tagged in it.
    private func composed() -> (text: String, mentions: [Mention]) {
        let storage = textView.attributedString()
        var result = ""
        var mentions: [Mention] = []
        var afterLink = false
        storage.enumerateAttributes(in: NSRange(location: 0, length: storage.length)) { attributes, range, _ in
            if let link = attributes[.attachment] as? ComposeLinkAttachment {
                if let last = result.last, !last.isWhitespace { result += " " }
                result += link.url.absoluteString
                afterLink = true
                return
            }
            let part = (storage.string as NSString).substring(with: range)
                .replacingOccurrences(of: Self.attachmentCharacter, with: "")
            if afterLink, let first = part.first, !first.isWhitespace { result += " " }
            if let userID = attributes[Self.mentionKey] as? String, !part.isEmpty {
                let offset = result.utf16.count
                // A tag split into runs (by other attributes) stays one.
                if let last = mentions.last, last.userID == userID, last.offset + last.length == offset {
                    mentions[mentions.count - 1] = Mention(offset: last.offset, length: last.length + part.utf16.count, userID: userID)
                } else {
                    mentions.append(Mention(offset: offset, length: part.utf16.count, userID: userID))
                }
            }
            result += part
            afterLink = afterLink && part.isEmpty
        }
        return (result, mentions)
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

    @objc private func plusClicked() {
        let menu = NSMenu()
        let attach = menu.addItem(withTitle: "Attach File…", action: #selector(attachClicked), keyEquivalent: "")
        attach.image = NSImage(systemSymbolName: "paperclip", accessibilityDescription: nil)
        attach.target = self
        if delegate?.composeViewCanCreatePoll(self) == true {
            let poll = menu.addItem(withTitle: "Create Poll…", action: #selector(createPollClicked), keyEquivalent: "")
            poll.image = NSImage(systemSymbolName: "chart.bar.xaxis", accessibilityDescription: nil)
            poll.target = self
        }
        // Above the button, like the composer's other popups.
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: plusButton.bounds.height + 6), in: plusButton)
    }

    @objc private func attachClicked() {
        delegate?.composeViewAttachFiles(self)
    }

    @objc private func createPollClicked() {
        startPoll()
    }

    // MARK: - Polls

    /// Create Poll: choices appear above the text, which becomes the question.
    func startPoll() {
        showPollPanel(.create, placeholder: "Ask a question")
        pollPanel.focusFirstChoice()
    }

    /// A sent poll's Add Choice: its options above, and a new choice to type.
    func startAddingChoices(to poll: Poll) {
        showPollPanel(.addChoices(poll), placeholder: "Add comment or Send")
        pollPanel.focusFirstChoice()
    }

    private func showPollPanel(_ mode: ComposePollPanel.Mode, placeholder text: String) {
        pollPanel.start(mode)
        pollPanel.isHidden = false
        pollSeparator.isHidden = false
        textTopToField.isActive = false
        textTopToPoll.isActive = true
        placeholder.stringValue = text
        updateActionButton()
    }

    /// Back to a message (✕, Escape, or the poll was sent).
    func endPoll() {
        guard isMakingPoll else { return }
        pollPanel.isHidden = true
        pollSeparator.isHidden = true
        textTopToPoll.isActive = false
        textTopToField.isActive = true
        placeholder.stringValue = "Message"
        updateActionButton()
        focus()
    }

    /// A new poll needs a question and two different choices; added choices need one.
    private var canSendPoll: Bool {
        guard pollPanel.canSend else { return false }
        if case .create = pollPanel.mode {
            return !composed().text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return true
    }

    private func sendPoll() {
        guard canSendPoll else {
            NSSound.beep()
            return
        }
        let text = composed().text.trimmingCharacters(in: .whitespacesAndNewlines)
        let choices = pollPanel.choices
        let mode = pollPanel.mode
        self.text = ""
        endPoll()
        switch mode {
        case .create:
            delegate?.composeView(self, createPoll: text, options: choices)
        case .addChoices(let poll):
            delegate?.composeView(self, addChoices: choices, to: poll, comment: text)
        }
    }

    /// The chat's quick reaction (nil: the default like) and theme color for the button, the
    /// cursor and selected text.
    func setQuickReaction(_ emoji: String?, tint: NSColor?) {
        quickEmoji = emoji?.isEmpty == false ? emoji : nil
        self.tint = tint ?? BubbleColors.outgoing
        textView.insertionPointColor = self.tint
        textView.selectedTextAttributes = [.backgroundColor: self.tint.withAlphaComponent(0.35)]
        plusButton.contentTintColor = self.tint
        updateActionButton()
    }

    /// Send arrow while there's something to send, otherwise the quick reaction.
    private func updateActionButton() {
        actionButton.title = ""
        actionButton.image = nil
        actionButton.isEnabled = true
        if isMakingPoll {
            let ready = canSendPoll
            actionButton.image = NSImage(systemSymbolName: "arrow.up.circle.fill", accessibilityDescription: "Send Poll")
            actionButton.symbolConfiguration = .init(pointSize: 22, weight: .regular)
            actionButton.contentTintColor = ready ? PollColors.accent : .tertiaryLabelColor
            actionButton.isEnabled = ready
            actionButton.toolTip = "Send Poll"
        } else if hasContent {
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
        if isMakingPoll || hasContent {
            send()
        } else {
            sendQuickReaction()
        }
        focus()
    }

    /// Sends the chat's quick reaction (👍 by default), keeping what's typed.
    func sendQuickReaction() {
        delegate?.composeView(self, send: quickEmoji ?? "👍", mentions: [], attachments: [])
    }

    @objc private func cancelReply() {
        delegate?.composeViewCancelReply(self)
    }

    private func send() {
        if isMakingPoll {
            sendPoll()
            return
        }
        var attachments: [URL] = []
        let storage = textView.attributedString()
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, _, _ in
            if let attachment = value as? ComposeAttachment {
                attachments.append(attachment.fileURL)
            }
        }
        // An emoticon right before Return hasn't been replaced yet (that happens at the next space).
        replaceEmoticon(before: textView.string.utf16.count)
        let composed = composed()
        let text = composed.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !attachments.isEmpty else { return }
        // The tags' places in the trimmed text.
        let leading = text.isEmpty ? 0 : (composed.text as NSString).range(of: text).location
        let mentions = composed.mentions.compactMap { mention -> Mention? in
            let offset = mention.offset - leading
            guard offset >= 0, offset + mention.length <= text.utf16.count else { return nil }
            return Mention(offset: offset, length: mention.length, userID: mention.userID)
        }
        // Cleared first: the delegate may put something back (the draft from before editing).
        self.text = ""
        delegate?.composeView(self, send: text, mentions: mentions, attachments: attachments)
    }

    // MARK: - Tagging people

    /// Opens, updates or closes the list of people for the "@name" before the insertion point.
    private func updateMentionPicker() {
        guard !mentionCandidates.isEmpty, let window, let query = mentionQuery() else {
            hideMentionPicker()
            return
        }
        let matches = Self.matches(mentionCandidates, query: query.text)
        guard !matches.isEmpty else {
            hideMentionPicker()
            return
        }
        mentionQueryRange = query.range
        let anchor = textView.firstRect(forCharacterRange: NSRange(location: query.range.location, length: 1), actualRange: nil)
        mentionPicker.show(matches, above: anchor, in: window)
    }

    private func hideMentionPicker() {
        mentionQueryRange = nil
        mentionPicker.hide()
    }

    /// The "@…" typed right before the insertion point: at the start or after a space, on one
    /// line, and not a tag already.
    private func mentionQuery() -> (range: NSRange, text: String)? {
        let selection = textView.selectedRange()
        guard selection.length == 0, let storage = textView.textStorage else { return nil }
        let string = storage.string as NSString
        let isSpace = { (c: unichar) in Unicode.Scalar(c).map { CharacterSet.whitespaces.contains($0) } ?? false }
        var at = selection.location - 1
        while at >= 0, selection.location - at <= 40 {
            let c = string.character(at: at)
            if c == 0x0A || c == 0x0D || c == 0xFFFC { return nil }
            if c == 0x40, at == 0 || isSpace(string.character(at: at - 1)) || string.character(at: at - 1) == 0x0A {
                guard storage.attribute(Self.mentionKey, at: at, effectiveRange: nil) == nil else { return nil }
                let range = NSRange(location: at, length: selection.location - at)
                let text = string.substring(with: NSRange(location: at + 1, length: range.length - 1))
                // A space right after the @, or two in a row: not a name being typed.
                if text.hasPrefix(" ") || text.contains("  ") { return nil }
                return (range, text)
            }
            at -= 1
        }
        return nil
    }

    /// The people whose name, or one of its words, starts with what's typed (ignoring case
    /// and accents).
    private static func matches(_ candidates: [MentionCandidate], query: String) -> [MentionCandidate] {
        let fold = { (s: String) in s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil) }
        let typed = fold(query)
        guard !typed.isEmpty else { return candidates }
        return candidates.filter { candidate in
            let name = fold(candidate.name)
            if name.hasPrefix(typed) { return true }
            return name.indices.contains { index in
                index > name.startIndex && name[name.index(before: index)] == " " && name[index...].hasPrefix(typed)
            }
        }
    }

    /// Replaces the "@name" being typed with the person's tag and a space.
    private func insertMention(_ candidate: MentionCandidate) {
        guard let range = mentionQueryRange, let storage = textView.textStorage, NSMaxRange(range) <= storage.length else { return }
        hideMentionPicker()
        let tag = NSMutableAttributedString(string: "@" + candidate.name, attributes: Self.textAttributes)
        tag.addAttributes([Self.mentionKey: candidate.id, .font: Self.mentionFont], range: NSRange(location: 0, length: tag.length))
        tag.append(NSAttributedString(string: " ", attributes: Self.textAttributes))
        guard textView.shouldChangeText(in: range, replacementString: tag.string) else { return }
        storage.replaceCharacters(in: range, with: tag)
        textView.didChangeText()
        textView.setSelectedRange(NSRange(location: range.location + tag.length, length: 0))
        textView.typingAttributes = Self.textAttributes
    }

    /// Editing inside a tag (or deleting into it) turns it back into plain text, like on Messenger.
    /// Typing right before or after it leaves it.
    private func breakMentions(touching range: NSRange) {
        guard let storage = textView.textStorage else { return }
        var broken: [NSRange] = []
        storage.enumerateAttribute(Self.mentionKey, in: NSRange(location: 0, length: storage.length)) { value, tagRange, _ in
            guard value != nil else { return }
            let touches = range.length == 0
                ? range.location > tagRange.location && range.location < NSMaxRange(tagRange)
                : NSIntersectionRange(range, tagRange).length > 0
            if touches { broken.append(tagRange) }
        }
        for tagRange in broken {
            storage.removeAttribute(Self.mentionKey, range: tagRange)
            storage.addAttribute(.font, value: Self.textAttributes[.font] as Any, range: tagRange)
        }
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
        let height = min(Self.maxTextHeight, max(Self.minTextHeight, ceil(used)))
        if textHeight.constant != height {
            textHeight.constant = height
            // Grow now, before the text view scrolls to the cursor: scrolling inside the old,
            // shorter field would leave the text shifted up once it grows.
            superview?.layoutSubtreeIfNeeded()
            let clip = scrollView.contentView
            clip.scroll(to: clip.constrainBoundsRect(clip.bounds).origin)
            scrollView.reflectScrolledClipView(clip)
        }
        if textView.string.isEmpty {
            // After a tall picture is sent, the field shrinks but would stay scrolled down,
            // leaving the cursor below the placeholder.
            textView.sizeToFit()
            scrollView.contentView.scroll(to: .zero)
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
        updateMentionPicker()
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        updateMentionPicker()
    }

    func textDidEndEditing(_ notification: Notification) {
        hideMentionPicker()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        hideMentionPicker()
    }

    /// Text typed after a tag isn't part of it.
    func textView(_ textView: NSTextView, shouldChangeTypingAttributes oldTypingAttributes: [String: Any],
                  toAttributes newTypingAttributes: [NSAttributedString.Key: Any]) -> [NSAttributedString.Key: Any] {
        guard newTypingAttributes[Self.mentionKey] != nil else { return newTypingAttributes }
        var attributes = newTypingAttributes
        attributes[Self.mentionKey] = nil
        attributes[.font] = Self.textAttributes[.font]
        return attributes
    }

    /// Typing a space or newline after an emoticon (":)") turns it into its emoji; Undo brings it back.
    func textView(_ textView: NSTextView, shouldChangeTextIn range: NSRange, replacementString: String?) -> Bool {
        if replacementString != nil {
            breakMentions(touching: range)
        }
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
        // The list of people takes the arrow keys, Return, Tab and Escape while it's open.
        if mentionPicker.isVisible {
            switch commandSelector {
            case #selector(NSResponder.moveUp(_:)):
                mentionPicker.moveSelection(by: -1)
                return true
            case #selector(NSResponder.moveDown(_:)):
                mentionPicker.moveSelection(by: 1)
                return true
            case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertTab(_:)):
                mentionPicker.pickSelected()
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                hideMentionPicker()
                return true
            default:
                break
            }
        }
        switch commandSelector {
        // Making a poll: Tab goes around its choices and the question.
        case #selector(NSResponder.insertTab(_:)) where isMakingPoll:
            pollPanel.focusFirstChoice()
            return true
        case #selector(NSResponder.insertBacktab(_:)) where isMakingPoll:
            pollPanel.focusLastChoice()
            return true
        case #selector(NSResponder.insertNewline(_:)):
            let flags = NSApp.currentEvent?.modifierFlags ?? []
            if flags.contains(.shift) || flags.contains(.option) {
                textView.insertNewlineIgnoringFieldEditor(nil)
            } else {
                send()
            }
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            if isMakingPoll {
                endPoll()
            } else {
                delegate?.composeViewCancelReply(self)
            }
            return true
        default:
            return false
        }
    }
}
