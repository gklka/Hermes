import AppKit

protocol MessageCellDelegate: AnyObject {
    func messageCell(_ cell: MessageCellView, menuFor message: ChatMessage) -> NSMenu?
    func messageCellDidDoubleClick(_ cell: MessageCellView, message: ChatMessage, bubble: NSView)
    func messageCell(_ cell: MessageCellView, open attachment: Attachment, of message: ChatMessage)
    /// "Edited" was clicked: show or hide the earlier versions.
    func messageCellDidToggleEdits(_ message: ChatMessage)
    /// A message's bubble was clicked: select it.
    func messageCellDidClick(_ cell: MessageCellView, message: ChatMessage)
    /// The "not delivered" icon was clicked: offer to resend or delete.
    func messageCellDidClickFailure(_ message: ChatMessage)
    /// The tapback badge was clicked: show who reacted.
    func messageCell(_ cell: MessageCellView, showReactionsOf message: ChatMessage, anchor: NSView)
    /// A message's link preview finished loading; its row's height may change.
    func messageCellDidLoadLinkPreview(messageID: String)
    /// The sender's avatar (group chats) was clicked or right-clicked.
    func messageCell(_ cell: MessageCellView, menuForSenderOf message: ChatMessage) -> NSMenu?
}

/// One message: optional sender name, reply quote, attachments, text bubble and tapbacks.
final class MessageCellView: NSTableCellView {
    struct Layout: Hashable {
        var showSenderName = false
        var senderName = ""
        var showAvatar = false
        var reserveAvatarSpace = false
        var avatarURL: String?
        var isFirstInGroup = true
        var maxWidth: CGFloat = 400
        /// The chat's custom theme for outgoing bubbles (one color or a gradient); empty for the default.
        var outgoingColors: [NSColor] = []
        /// Earlier versions of an edited message are shown.
        var showsEditHistory = false
    }

    weak var delegate: MessageCellDelegate?
    private(set) var message: ChatMessage?

    /// The bubble with its sender name, attachments, link preview and "Edited".
    private let column = NSStackView()
    private let senderLabel = NSTextField(labelWithString: "")
    private let replyView = ReplyQuoteView()
    private let attachmentsStack = NSStackView()
    private let bubble = BubbleView()
    private let textView = MessageTextView()
    private let reactionsBadge = ReactionsBadge()
    private let avatar = AvatarView()
    /// Clicking offers to resend or delete the message.
    private let failedIcon = NSButton()
    /// The preview of a link in the message.
    private let linkCard = LinkCardView()
    /// "Edited" under an edited message; clicking shows the earlier versions above it.
    private let editedButton = NSButton(title: "Edited", target: nil, action: nil)
    private let editedRow = NSView()
    private var editedLeading = NSLayoutConstraint()
    private var editedTrailing = NSLayoutConstraint()
    /// Earlier versions of an edited message, as faded bubbles above the current one.
    private let historyStack = NSStackView()

    /// The typing indicator is this cell in its typing state: an empty bubble with pulsing dots.
    /// When the message arrives, the same cell turns into it (`transitionFromTyping`).
    private let typingDots = NSTextField(labelWithString: "•••")
    private var typingConstraints: [NSLayoutConstraint] = []
    private(set) var isTyping = false
    private static let typingBubbleHeight: CGFloat = 34
    private static let typingDotsFont = NSFont.systemFont(ofSize: 20, weight: .bold)

    // Placeholders; the real constraints are created in init once the views exist.
    private var topConstraint = NSLayoutConstraint()
    private var incomingConstraints: [NSLayoutConstraint] = []
    private var outgoingConstraints: [NSLayoutConstraint] = []
    private var incomingAvatarLeading = NSLayoutConstraint()
    private var widthConstraint = NSLayoutConstraint()
    /// The tapback badge's place: on the top corner of the message's first part (see anchorBadge).
    private var badgeX = NSLayoutConstraint()
    private var badgeY = NSLayoutConstraint()
    /// The text's leading, trailing, top and bottom insets in its bubble.
    private var textInsets: [NSLayoutConstraint] = []

    /// What the attachment views currently show.
    private struct AttachmentsKey: Equatable {
        let messageID: String
        let attachments: [Attachment]
        let maxWidth: CGFloat
    }
    private var shownAttachments: AttachmentsKey?

    // The reply quote sits above the column, on the quoted message's sender's side.
    private let replyConnector = ReplyConnectorView()
    private var replyOnLeft = true
    private var replyLeading = NSLayoutConstraint()
    private var replyTrailing = NSLayoutConstraint()
    private var replyTop = NSLayoutConstraint()
    private var columnBelowReply = NSLayoutConstraint()
    private var outgoingTrailing = NSLayoutConstraint()
    /// When a reply and its quote are on the same side, the reply moves in to make room for the line.
    private static let threadIndent: CGFloat = 30

    private var selectedAt: TimeInterval = 0

    init() {
        super.init(frame: .zero)

        column.orientation = .vertical
        column.spacing = 3
        column.translatesAutoresizingMaskIntoConstraints = false
        // A stack view pulls its views to its own width at its hugging priority; below the text's
        // (required) hugging, so bubbles of different widths (e.g. an edit's earlier version)
        // keep their own sizes.
        column.setHuggingPriority(.defaultHigh, for: .horizontal)

        senderLabel.font = .systemFont(ofSize: 11)
        senderLabel.textColor = .secondaryLabelColor

        attachmentsStack.orientation = .vertical
        attachmentsStack.spacing = 3

        setUpBubble()
        column.addArrangedSubview(senderLabel)
        column.addArrangedSubview(attachmentsStack)
        column.addArrangedSubview(bubble)
        column.addArrangedSubview(linkCard)
        linkCard.isHidden = true
        setUpEditedButton()
        column.addArrangedSubview(editedRow)
        historyStack.orientation = .vertical
        historyStack.spacing = 3
        column.insertArrangedSubview(historyStack, at: column.arrangedSubviews.firstIndex(of: bubble) ?? 0)

        failedIcon.image = NSImage(systemSymbolName: "exclamationmark.circle.fill", accessibilityDescription: "Not delivered")
        failedIcon.symbolConfiguration = .init(pointSize: 15, weight: .regular)
        failedIcon.contentTintColor = .systemRed
        failedIcon.isBordered = false
        failedIcon.bezelStyle = .regularSquare
        failedIcon.toolTip = "Not Delivered"
        failedIcon.target = self
        failedIcon.action = #selector(failedIconClicked)

        // The connector is laid out by hand in layout().
        addSubview(replyConnector)
        for view in [replyView, column, reactionsBadge, avatar, failedIcon] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        setUpConstraints()

        reactionsBadge.onClick = { [weak self] in
            guard let self, let message = self.message else { return }
            self.delegate?.messageCell(self, showReactionsOf: message, anchor: self.reactionsBadge)
        }

        let click = NSClickGestureRecognizer(target: self, action: #selector(clicked))
        let doubleClick = NSClickGestureRecognizer(target: self, action: #selector(doubleClicked))
        doubleClick.numberOfClicksRequired = 2
        for recognizer in [click, doubleClick] {
            // The text view gets the clicks too, so a selected message's text can be clicked
            // and double-clicked (a recognized click would otherwise swallow them).
            recognizer.delaysPrimaryMouseButtonEvents = false
            bubble.addGestureRecognizer(recognizer)
        }
        avatar.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(avatarClicked)))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// The text (or the typing dots) in the bubble.
    private func setUpBubble() {
        let insets = BubbleMetrics.textInsets
        textView.translatesAutoresizingMaskIntoConstraints = false
        bubble.addSubview(textView)
        textInsets = [
            textView.leadingAnchor.constraint(equalTo: bubble.leadingAnchor, constant: insets.left),
            textView.trailingAnchor.constraint(equalTo: bubble.trailingAnchor, constant: -insets.right),
            textView.topAnchor.constraint(equalTo: bubble.topAnchor, constant: insets.top),
            textView.bottomAnchor.constraint(equalTo: bubble.bottomAnchor, constant: -insets.bottom),
        ]
        NSLayoutConstraint.activate(textInsets)

        typingDots.font = Self.typingDotsFont
        typingDots.textColor = .secondaryLabelColor
        typingDots.translatesAutoresizingMaskIntoConstraints = false
        typingDots.isHidden = true
        bubble.addSubview(typingDots)
        typingConstraints = [
            typingDots.leadingAnchor.constraint(equalTo: bubble.leadingAnchor, constant: 14),
            typingDots.trailingAnchor.constraint(equalTo: bubble.trailingAnchor, constant: -14),
            typingDots.centerYAnchor.constraint(equalTo: bubble.centerYAnchor, constant: -1),
            bubble.heightAnchor.constraint(equalToConstant: Self.typingBubbleHeight),
        ]
    }

    /// "Edited", in a row inset like the "Sent" caption (the column is a little further out).
    private func setUpEditedButton() {
        let inset = BubbleMetrics.captionSideInset - BubbleMetrics.sideInset
        editedButton.translatesAutoresizingMaskIntoConstraints = false
        editedRow.addSubview(editedButton)
        editedLeading = editedButton.leadingAnchor.constraint(equalTo: editedRow.leadingAnchor, constant: inset)
        editedTrailing = editedButton.trailingAnchor.constraint(equalTo: editedRow.trailingAnchor, constant: -inset)
        NSLayoutConstraint.activate([
            editedButton.topAnchor.constraint(equalTo: editedRow.topAnchor),
            editedButton.bottomAnchor.constraint(equalTo: editedRow.bottomAnchor),
            editedButton.leadingAnchor.constraint(greaterThanOrEqualTo: editedRow.leadingAnchor),
            editedButton.trailingAnchor.constraint(lessThanOrEqualTo: editedRow.trailingAnchor),
        ])
        editedButton.isBordered = false
        editedButton.bezelStyle = .regularSquare
        editedButton.font = .systemFont(ofSize: 11, weight: .medium)
        editedButton.contentTintColor = .secondaryLabelColor
        editedButton.target = self
        editedButton.action = #selector(editedClicked)
        // Never truncated under a narrow bubble. It may stretch to the column's width, so its
        // title is aligned to the bubble's side in configure.
        editedButton.setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    private func setUpConstraints() {
        let side = BubbleMetrics.sideInset
        topConstraint = column.topAnchor.constraint(equalTo: topAnchor, constant: 2)
        widthConstraint = column.widthAnchor.constraint(lessThanOrEqualToConstant: 400)
        incomingAvatarLeading = column.leadingAnchor.constraint(equalTo: leadingAnchor, constant: side)
        incomingConstraints = [incomingAvatarLeading]
        outgoingTrailing = column.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -side)
        outgoingConstraints = [outgoingTrailing]
        replyTop = replyView.topAnchor.constraint(equalTo: topAnchor, constant: 8)
        columnBelowReply = column.topAnchor.constraint(equalTo: replyView.bottomAnchor, constant: 4)
        replyLeading = replyView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: side)
        replyTrailing = replyView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -side)

        NSLayoutConstraint.activate([
            topConstraint,
            widthConstraint,
            replyView.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: side),
            replyView.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -side),
            column.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -1),
            column.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: side),
            column.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -side),
            avatar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            avatar.bottomAnchor.constraint(equalTo: column.bottomAnchor),
            avatar.widthAnchor.constraint(equalToConstant: 28),
            avatar.heightAnchor.constraint(equalToConstant: 28),
            failedIcon.trailingAnchor.constraint(equalTo: column.leadingAnchor, constant: -6),
            failedIcon.centerYAnchor.constraint(equalTo: column.centerYAnchor),
        ])
    }

    /// Puts the tapback badge on the view's top corner toward the middle of the chat (left on
    /// your messages, right on others').
    private func anchorBadge(to view: NSView, outgoing: Bool) {
        NSLayoutConstraint.deactivate([badgeX, badgeY])
        badgeX = outgoing
            ? reactionsBadge.centerXAnchor.constraint(equalTo: view.leadingAnchor, constant: 2)
            : reactionsBadge.centerXAnchor.constraint(equalTo: view.trailingAnchor, constant: -2)
        badgeY = reactionsBadge.centerYAnchor.constraint(equalTo: view.topAnchor, constant: -2)
        NSLayoutConstraint.activate([badgeX, badgeY])
    }

    // MARK: - Showing a message

    func configure(_ message: ChatMessage, layout: Layout, store: ChatStore) {
        self.message = message
        setTyping(false)
        let outgoing = message.isFromMe

        NSLayoutConstraint.deactivate(incomingConstraints + outgoingConstraints)
        NSLayoutConstraint.activate(outgoing ? outgoingConstraints : incomingConstraints)
        column.alignment = outgoing ? .trailing : .leading
        configureReply(message, layout: layout, selfID: store.account?.id)

        // Sender name and picture (group chats; the picture by the last message of a run).
        senderLabel.isHidden = !layout.showSenderName
        senderLabel.stringValue = layout.senderName
        avatar.isHidden = !layout.showAvatar
        if layout.showAvatar {
            avatar.configure(name: layout.senderName, url: layout.avatarURL)
        }
        avatar.toolTip = layout.showAvatar ? layout.senderName : nil

        // A web link gets Apple's rich preview, which replaces Messenger's own link card.
        let preview = message.isUnsent ? nil : LinkPreviews.source(text: message.text, attachments: message.attachments)
        configureAttachments(message, layout: layout, hidingLinks: preview != nil)
        let textColor = configureBubble(message, layout: layout, preview: preview)

        let emojis = message.reactions.map(\.emoji)
        // On the first part: pictures, the text bubble or a link card.
        let badgeAnchor = [attachmentsStack, bubble, linkCard].first { !$0.isHidden }
        reactionsBadge.isHidden = emojis.isEmpty || badgeAnchor == nil
        if let badgeAnchor {
            anchorBadge(to: badgeAnchor, outgoing: outgoing)
        }
        reactionsBadge.configure(emojis: emojis, highlighted: message.reactions.contains { $0.senderID == store.account?.id })

        // Spacing: tight within a run, looser between runs, extra room for tapbacks.
        let top: CGFloat = layout.isFirstInGroup ? 8 : 1
        let badgeRoom: CGFloat = reactionsBadge.isHidden ? 0 : 12
        topConstraint.constant = top + badgeRoom
        replyTop.constant = top
        columnBelowReply.constant = 5 + badgeRoom
        needsLayout = true

        configureEdits(message, layout: layout, textColor: textColor)

        alphaValue = message.status == .pending ? 0.6 : 1
        failedIcon.isHidden = message.status != .failed
        toolTip = Formatters.messageTime(message.date) + (message.isEdited ? " (edited)" : "")
    }

    /// The quote of the message replied to, on its sender's side (mine on the right). A reply on
    /// the same side as its quote moves in, to make room for the thread line.
    private func configureReply(_ message: ChatMessage, layout: Layout, selfID: String?) {
        let outgoing = message.isFromMe
        let incomingLeading = layout.reserveAvatarSpace ? BubbleMetrics.avatarSideInset : BubbleMetrics.sideInset
        NSLayoutConstraint.deactivate([topConstraint, replyTop, columnBelowReply, replyLeading, replyTrailing])
        var indent: CGFloat = 0
        if let reply = message.replyTo, !message.isUnsent {
            let quotedIsMe = reply.senderID.map { $0 == selfID } ?? !outgoing
            replyOnLeft = !quotedIsMe
            if replyOnLeft != outgoing {
                indent = Self.threadIndent
            }
            replyLeading.constant = incomingLeading
            replyView.configure(text: reply.text.isEmpty ? "Attachment" : reply.text, maxWidth: layout.maxWidth)
            replyView.isHidden = false
            replyConnector.isHidden = false
            NSLayoutConstraint.activate([replyTop, columnBelowReply, replyOnLeft ? replyLeading : replyTrailing])
        } else {
            replyView.isHidden = true
            replyConnector.isHidden = true
            NSLayoutConstraint.activate([topConstraint])
        }
        incomingAvatarLeading.constant = incomingLeading + (outgoing ? 0 : indent)
        outgoingTrailing.constant = -BubbleMetrics.sideInset - (outgoing ? indent : 0)
        widthConstraint.constant = layout.maxWidth - indent
    }

    /// The attachment views. Kept when unchanged: rebuilding them reloads their pictures, which
    /// blinks on every refresh (e.g. while syncing after login).
    private func configureAttachments(_ message: ChatMessage, layout: Layout, hidingLinks: Bool) {
        let shown = message.isUnsent ? [] : message.attachments.filter { !(hidingLinks && $0.kind == .link) }
        let key = AttachmentsKey(messageID: message.id, attachments: shown, maxWidth: min(layout.maxWidth, 280))
        if key != shownAttachments {
            shownAttachments = key
            for view in attachmentsStack.arrangedSubviews {
                view.removeFromSuperview()
            }
            for attachment in shown {
                let view = AttachmentView(attachment: attachment, message: message, maxWidth: key.maxWidth)
                view.onOpen = { [weak self] in
                    guard let self, let message = self.message else { return }
                    self.delegate?.messageCell(self, open: attachment, of: message)
                }
                attachmentsStack.addArrangedSubview(view)
            }
        }
        attachmentsStack.alignment = message.isFromMe ? .trailing : .leading
        attachmentsStack.isHidden = attachmentsStack.arrangedSubviews.isEmpty
    }

    /// The text bubble and the link preview under it. Returns the text's color (for earlier
    /// versions of an edit).
    private func configureBubble(_ message: ChatMessage, layout: Layout, preview: LinkPreviews.Source?) -> NSColor {
        let outgoing = message.isFromMe
        let text = message.isUnsent ? (outgoing ? "You unsent a message" : "Message unsent") : message.text
        // A few emoji alone are shown big, without a bubble.
        let jumbo = !message.isUnsent && text.isJumboEmoji && message.replyTo == nil
        // A message that's only the link shows just the preview.
        bubble.isHidden = text.isEmpty || (preview != nil && LinkPreviews.isOnlyLink(text))
        configureLinkPreview(preview, message: message, maxWidth: layout.maxWidth)

        let onTheme = outgoing && !jumbo && !message.isUnsent
        bubble.color = jumbo || message.isUnsent ? .clear : (outgoing ? layout.outgoingColors.first ?? BubbleColors.outgoing : BubbleColors.incoming)
        bubble.gradientColors = onTheme && layout.outgoingColors.count > 1 ? layout.outgoingColors : nil
        bubble.layer?.borderWidth = message.isUnsent ? 1 : 0
        bubble.layer?.borderColor = NSColor.separatorColor.cgColor

        let font = jumbo ? NSFont.systemFont(ofSize: 44) : BubbleMetrics.font
        let color: NSColor = message.isUnsent ? .secondaryLabelColor : (outgoing && !jumbo ? .white : .labelColor)
        // On the blue bubble links are white; on the gray one they use the system link color.
        let linkColor: NSColor = outgoing && !jumbo ? .white : .linkColor
        textView.linkTextAttributes = [
            .foregroundColor: linkColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .underlineColor: linkColor,
            .cursor: NSCursor.pointingHand,
        ]
        // Selected text in the chat's theme color (lighter white on the themed bubble itself).
        let selection = outgoing && !jumbo
            ? NSColor.white.withAlphaComponent(0.3)
            : (layout.outgoingColors.last ?? BubbleColors.outgoing).withAlphaComponent(0.35)
        textView.selectedTextAttributes = [.backgroundColor: selection]
        let insets = jumbo ? NSEdgeInsetsZero : BubbleMetrics.textInsets
        textView.maxWidth = layout.maxWidth - BubbleMetrics.textInsets.left - BubbleMetrics.textInsets.right
        textView.setText(Self.attributed(text, font: font, color: color, italic: message.isUnsent,
                                         mentions: message.isUnsent ? [] : message.mentions ?? []))
        textInsets[0].constant = insets.left
        textInsets[1].constant = -insets.right
        textInsets[2].constant = insets.top
        textInsets[3].constant = -insets.bottom
        return color
    }

    /// Shows what's known of the link's preview right away and loads the rest (the delegate
    /// re-measures the row then; this also happens for the controller's sizing cell).
    private func configureLinkPreview(_ source: LinkPreviews.Source?, message: ChatMessage, maxWidth: CGFloat) {
        guard let source else {
            linkCard.isHidden = true
            return
        }
        linkCard.isHidden = false
        let width = min(maxWidth, 300)
        linkCard.configure(LinkPreviews.shared.preview(for: source), width: width)
        let messageID = message.id
        Task { [weak self] in
            guard let loaded = await LinkPreviews.shared.load(source), let self else { return }
            if self.message?.id == messageID {
                self.linkCard.configure(loaded, width: width)
            }
            self.delegate?.messageCellDidLoadLinkPreview(messageID: messageID)
        }
    }

    /// "Edited" under the bubble, and the earlier versions above it while they're shown.
    private func configureEdits(_ message: ChatMessage, layout: Layout, textColor: NSColor) {
        let outgoing = message.isFromMe
        let previous = message.previousTexts ?? []
        editedButton.isHidden = !message.isEdited || message.isUnsent
        editedRow.isHidden = editedButton.isHidden
        editedLeading.isActive = !outgoing
        editedTrailing.isActive = outgoing
        editedButton.isEnabled = !previous.isEmpty
        editedButton.title = layout.showsEditHistory ? "Hide Edits" : "Edited"
        editedButton.alignment = outgoing ? .right : .left
        editedButton.toolTip = previous.isEmpty ? nil : (layout.showsEditHistory ? "Hide earlier versions" : "Show earlier versions")
        for view in historyStack.arrangedSubviews {
            view.removeFromSuperview()
        }
        if layout.showsEditHistory, !editedButton.isHidden {
            for text in previous {
                historyStack.addArrangedSubview(Self.previousVersion(
                    text, color: bubble.color, textColor: textColor, maxWidth: layout.maxWidth))
            }
        }
        historyStack.alignment = outgoing ? .trailing : .leading
        historyStack.isHidden = historyStack.arrangedSubviews.isEmpty
    }

    /// Link styling comes from the text view's linkTextAttributes, so only the URL is attached here.
    /// Tagged names are bold.
    private static func attributed(_ text: String, font: NSFont, color: NSColor, italic: Bool,
                                   mentions: [Mention]) -> NSAttributedString {
        var font = font
        if italic {
            font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
        }
        let result = NSMutableAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
        let bold = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
        for mention in mentions where NSMaxRange(mention.range) <= result.length {
            result.addAttribute(.font, value: bold, range: mention.range)
        }
        if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) {
            for match in detector.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                guard let url = match.url else { continue }
                result.addAttribute(.link, value: url, range: match.range)
            }
        }
        return result
    }

    /// An earlier version of the message: a faded bubble like the current one.
    private static func previousVersion(_ text: String, color: NSColor, textColor: NSColor, maxWidth: CGFloat) -> NSView {
        let bubble = BubbleView()
        bubble.color = color
        bubble.alphaValue = 0.5
        let label = NSTextField(wrappingLabelWithString: text)
        label.isSelectable = false
        label.font = BubbleMetrics.font
        label.textColor = textColor
        label.translatesAutoresizingMaskIntoConstraints = false
        bubble.addSubview(label)
        // Sized from the text: otherwise the stack squeezes it to the current (maybe shorter)
        // message's width, and the wrapped lines get cut off.
        let insets = BubbleMetrics.textInsets
        let size = (text as NSString).boundingRect(
            with: NSSize(width: maxWidth - insets.left - insets.right, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: BubbleMetrics.font]
        ).size
        NSLayoutConstraint.activate([
            label.widthAnchor.constraint(equalToConstant: ceil(size.width) + 4),
            label.heightAnchor.constraint(equalToConstant: ceil(size.height)),
            label.leadingAnchor.constraint(equalTo: bubble.leadingAnchor, constant: insets.left),
            label.trailingAnchor.constraint(equalTo: bubble.trailingAnchor, constant: -insets.right),
            label.topAnchor.constraint(equalTo: bubble.topAnchor, constant: insets.top),
            label.bottomAnchor.constraint(equalTo: bubble.bottomAnchor, constant: -insets.bottom),
        ])
        return bubble
    }

    override func layout() {
        super.layout()
        guard !replyConnector.isHidden else { return }
        let target = anchorView === self ? column : anchorView
        replyConnector.frame = bounds
        replyConnector.update(quote: replyView.frame, target: convert(target.bounds, from: target), onLeft: replyOnLeft)
    }

    /// Lines up a gradient theme with the visible chat (call after layout and on scroll).
    func alignGradient(to clipView: NSClipView) {
        bubble.alignGradient(to: bubble.convert(clipView.bounds, from: clipView))
    }

    /// The view showing one of this message's attachments (for Quick Look's zoom).
    func attachmentView(for attachmentID: String) -> AttachmentView? {
        attachmentsStack.arrangedSubviews.lazy.compactMap { $0 as? AttachmentView }.first { $0.attachmentID == attachmentID }
    }

    /// What popovers about this message point at: the text bubble, or the attachments.
    var anchorView: NSView {
        if !bubble.isHidden { return bubble }
        return attachmentsStack.isHidden ? self : attachmentsStack
    }

    /// The sender's avatar (group chats), for showing their contact card next to it.
    var avatarView: NSView? { avatar.isHidden ? nil : avatar }

    /// The message (or typing bubble) arriving: the bubble and what belongs to it zoom in.
    func animateArrival() {
        column.animateAppearance()
    }

    // MARK: - Typing

    /// The typing indicator: just the incoming bubble with the dots, where the next message
    /// will be (the layout's avatar space keeps it aligned with the chat's messages).
    func configureTyping(layout: Layout) {
        message = nil
        setTyping(true)
        NSLayoutConstraint.deactivate(outgoingConstraints + [replyTop, columnBelowReply, replyLeading, replyTrailing])
        NSLayoutConstraint.activate(incomingConstraints + [topConstraint])
        column.alignment = .leading
        incomingAvatarLeading.constant = layout.reserveAvatarSpace ? BubbleMetrics.avatarSideInset : BubbleMetrics.sideInset
        widthConstraint.constant = layout.maxWidth
        topConstraint.constant = 8
        for view in [senderLabel, replyView, replyConnector, attachmentsStack, linkCard, reactionsBadge, avatar,
                     editedRow, historyStack, failedIcon] as [NSView] {
            view.isHidden = true
        }
        bubble.isHidden = false
        bubble.color = BubbleColors.incoming
        bubble.gradientColors = nil
        bubble.layer?.borderWidth = 0
        alphaValue = 1
        toolTip = nil
        needsLayout = true
    }

    private func setTyping(_ typing: Bool) {
        guard typing != isTyping else { return }
        isTyping = typing
        textView.isHidden = typing
        typingDots.isHidden = !typing
        if typing {
            NSLayoutConstraint.deactivate(textInsets)
            NSLayoutConstraint.activate(typingConstraints)
            pulseTypingDots()
        } else {
            typingDots.layer?.removeAnimation(forKey: "pulse")
            NSLayoutConstraint.deactivate(typingConstraints)
            NSLayoutConstraint.activate(textInsets)
        }
    }

    private func pulseTypingDots() {
        let pulse = CABasicAnimation.fade(from: 1, to: 0.35, duration: 0.7)
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        typingDots.wantsLayer = true
        typingDots.layer?.add(pulse, forKey: "pulse")
    }

    /// Animations stop when a cell leaves the window; the dots keep pulsing when it's back.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if isTyping, window != nil { pulseTypingDots() }
    }

    /// Where the typing bubble is: its distance from the cell's top, its left edge and size
    /// (taken before the row grows for the message).
    struct TypingBubble {
        let top: CGFloat
        let x: CGFloat
        let size: CGSize
    }

    var typingBubble: TypingBubble? {
        guard isTyping, bubble.bounds.width > 0 else { return nil }
        let frame = bubble.convert(bubble.bounds, to: self)
        let top = isFlipped ? frame.minY : bounds.height - frame.maxY
        return TypingBubble(top: top, x: frame.minX, size: frame.size)
    }

    /// The typing bubble becomes the message: the bubble opens from where and how big the typing
    /// bubble was to the message's frame (revealing the text, which fades in), the dots fade away,
    /// and the rest of the message (sender name, attachments) fades in. Call once the row has
    /// the message's height.
    func transitionFromTyping(_ typing: TypingBubble, to message: ChatMessage, layout: Layout, store: ChatStore, duration: TimeInterval) {
        configure(message, layout: layout, store: store)
        layoutSubtreeIfNeeded()
        guard let bubbleLayer = bubble.layer, let column = bubble.superview, !bubble.isHidden else {
            animateArrival()
            return
        }
        let newFrame = bubble.frame
        // The typing bubble's place, in the bubble's superview (the column).
        let y = isFlipped ? typing.top : bounds.height - typing.top - typing.size.height
        let oldFrame = column.convert(NSRect(x: typing.x, y: y, width: typing.size.width, height: typing.size.height), from: self)
        let timing = CAMediaTimingFunction(controlPoints: 0.3, 1.15, 0.5, 1)
        // A layer-backed view's layer has its anchor at the corner: position is the origin.
        let size = CABasicAnimation(keyPath: "bounds.size")
        size.fromValue = NSValue(size: oldFrame.size)
        size.toValue = NSValue(size: newFrame.size)
        let position = CABasicAnimation(keyPath: "position")
        position.fromValue = NSValue(point: oldFrame.origin)
        position.toValue = NSValue(point: newFrame.origin)
        let radius = CABasicAnimation(keyPath: "cornerRadius")
        radius.fromValue = BubbleView.cornerRadius(forHeight: typing.size.height)
        radius.toValue = BubbleView.cornerRadius(forHeight: newFrame.height)
        for animation in [size, position, radius] {
            animation.duration = duration
            animation.timingFunction = timing
            bubbleLayer.add(animation, forKey: "typing.\(animation.keyPath ?? "")")
        }

        // The dots: a picture of them fading out where they were, as the text replaces them.
        let dots = CATextLayer()
        dots.string = NSAttributedString(string: "•••", attributes: [
            .font: Self.typingDotsFont, .foregroundColor: NSColor.secondaryLabelColor,
        ])
        dots.contentsScale = window?.backingScaleFactor ?? 2
        dots.frame = CGRect(x: 14, y: (Self.typingBubbleHeight - 26) / 2 - 1, width: 40, height: 26)
        dots.opacity = 0
        bubbleLayer.addSublayer(dots)
        dots.add(CABasicAnimation.fade(from: 1, to: 0, duration: duration * 0.4), forKey: "fade")
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { dots.removeFromSuperlayer() }

        // The rest fades in once the bubble has opened up a little.
        let fadeIn = CAKeyframeAnimation(keyPath: "opacity")
        fadeIn.values = [0, 0, 1]
        fadeIn.keyTimes = [0, 0.3, 1]
        fadeIn.duration = duration
        for view in [textView, senderLabel, attachmentsStack, linkCard, editedRow, avatar, reactionsBadge] as [NSView] where !view.isHidden {
            view.wantsLayer = true
            view.layer?.add(fadeIn, forKey: "typing.fade")
        }
    }

    // MARK: - Clicks and menus

    /// Clicking a sender's avatar shows what you can do with that person (as on the web).
    @objc private func avatarClicked() {
        guard let message, let menu = delegate?.messageCell(self, menuForSenderOf: message) else { return }
        menu.popUp(positioning: nil, at: NSPoint(x: avatar.bounds.maxX + 4, y: avatar.bounds.maxY), in: avatar)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let message else { return nil }
        if !avatar.isHidden, avatar.bounds.contains(avatar.convert(event.locationInWindow, from: nil)) {
            return delegate?.messageCell(self, menuForSenderOf: message)
        }
        guard let menu = delegate?.messageCell(self, menuFor: message) else { return nil }
        // Darken the message while its context menu is open. AppKit may show a copy of the
        // menu, so listen for any menu closing rather than this one.
        setDarkened(true)
        stopWatchingMenu()
        menuEndObserver = NotificationCenter.default.addObserver(
            forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.menuDidEnd() }
        }
        return menu
    }

    override func didCloseMenu(_ menu: NSMenu, with event: NSEvent?) {
        super.didCloseMenu(menu, with: event)
        setDarkened(isMessageSelected)
    }

    private var menuEndObserver: NSObjectProtocol?

    private func menuDidEnd() {
        setDarkened(isMessageSelected)
        stopWatchingMenu()
    }

    private func stopWatchingMenu() {
        if let menuEndObserver { NotificationCenter.default.removeObserver(menuEndObserver) }
        menuEndObserver = nil
    }

    /// A clicked message stays dimmed (like while its menu is open) until something else is clicked.
    var isMessageSelected = false {
        didSet {
            guard isMessageSelected != oldValue else { return }
            selectedAt = ProcessInfo.processInfo.systemUptime
            setDarkened(isMessageSelected)
            // Text can only be selected in the selected message.
            textView.allowsTextSelection = isMessageSelected
            // The I-beam over the whole bubble, including around the text.
            bubble.cursor = isMessageSelected ? .iBeam : nil
        }
    }

    @objc private func clicked() {
        guard let message, !message.isUnsent else { return }
        delegate?.messageCellDidClick(self, message: message)
    }

    /// Double-clicking reacts, unless the message was already selected before the double-click
    /// (its first click selects it): then the text view selects a word instead.
    @objc private func doubleClicked() {
        guard let message, !message.isUnsent else { return }
        let selectedByThisDoubleClick = ProcessInfo.processInfo.systemUptime - selectedAt < NSEvent.doubleClickInterval + 0.1
        guard !isMessageSelected || selectedByThisDoubleClick else { return }
        delegate?.messageCellDidDoubleClick(self, message: message, bubble: bubble)
    }

    @objc private func editedClicked() {
        guard let message else { return }
        delegate?.messageCellDidToggleEdits(message)
    }

    @objc private func failedIconClicked() {
        guard let message else { return }
        delegate?.messageCellDidClickFailure(message)
    }

    /// Multiplies the message's colors (keeping transparency), so bubbles, photos and text darken.
    private static let darkenFilter: CIFilter? = {
        let filter = CIFilter(name: "CIColorMatrix")
        filter?.setValue(CIVector(x: 0.72, y: 0, z: 0, w: 0), forKey: "inputRVector")
        filter?.setValue(CIVector(x: 0, y: 0.72, z: 0, w: 0), forKey: "inputGVector")
        filter?.setValue(CIVector(x: 0, y: 0, z: 0.72, w: 0), forKey: "inputBVector")
        return filter
    }()

    private func setDarkened(_ darkened: Bool) {
        column.wantsLayer = true
        column.layerUsesCoreImageFilters = true
        column.contentFilters = darkened ? Self.darkenFilter.map { [$0] } ?? [] : []
    }
}
