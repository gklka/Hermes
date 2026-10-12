import AppKit

enum BubbleColors {
    static let outgoing = NSColor.systemBlue
    static let incoming = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.23, green: 0.23, blue: 0.24, alpha: 1)
            : NSColor(srgbRed: 0.91, green: 0.91, blue: 0.92, alpha: 1)
    }

    /// A chat's custom Messenger theme colors ("#rrggbb"); empty for the default theme.
    static func theme(_ hexColors: [String]?) -> [NSColor] {
        (hexColors ?? []).compactMap { hex in
            guard hex.count == 7, hex.hasPrefix("#"), let value = UInt32(hex.dropFirst(), radix: 16) else { return nil }
            return NSColor(
                srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
                green: CGFloat((value >> 8) & 0xFF) / 255,
                blue: CGFloat(value & 0xFF) / 255,
                alpha: 1
            )
        }
    }
}

/// An image view that's never a drop target (NSImageView registers for image drags and then
/// refuses them when not editable), so files dropped on a photo reach the chat's drop target.
final class DisplayImageView: NSImageView {
    override func registerForDraggedTypes(_ newTypes: [NSPasteboard.PasteboardType]) {}
}

/// A rounded rectangle whose color resolves with the current appearance.
final class BubbleView: NSView {
    var color: NSColor = BubbleColors.incoming {
        didSet { needsDisplay = true }
    }

    /// Gradient themes: like Messenger, the gradient spans the visible chat, so a bubble's color
    /// depends on where it is on screen. See `alignGradient(to:)`.
    var gradientColors: [NSColor]? {
        didSet { needsDisplay = true }
    }

    private var gradientLayer: CAGradientLayer?
    private var gradientArea: NSRect = .zero

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 17
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        guard let gradientColors, gradientColors.count > 1 else {
            gradientLayer?.isHidden = true
            layer?.backgroundColor = color.cgColor
            return
        }
        let gradient = gradientLayer ?? CAGradientLayer()
        if gradientLayer == nil {
            // The view isn't flipped, so y = 1 is the top.
            gradient.startPoint = CGPoint(x: 0.5, y: 1)
            gradient.endPoint = CGPoint(x: 0.5, y: 0)
            layer?.insertSublayer(gradient, at: 0)
            gradientLayer = gradient
        }
        gradient.colors = gradientColors.map(\.cgColor)
        gradient.isHidden = false
        layer?.backgroundColor = nil
        alignGradient(to: gradientArea)
    }

    /// Stretches the gradient over `area` (the visible chat, in this view's coordinates).
    func alignGradient(to area: NSRect) {
        gradientArea = area
        guard let gradientLayer, !gradientLayer.isHidden else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        gradientLayer.frame = area
        CATransaction.commit()
    }
}

/// Centered gray text: timestamps, system notices, "Read"/"Delivered".
final class CaptionCellView: NSTableCellView {
    private let label = NSTextField(wrappingLabelWithString: "")
    private var alignmentConstraints: [NSLayoutConstraint] = []

    init() {
        super.init(frame: .zero)
        label.font = .systemFont(ofSize: 11, weight: .medium)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    enum Placement { case center, trailing, leading }

    func configure(_ text: String, placement: Placement = .center, color: NSColor = .secondaryLabelColor, maxWidth: CGFloat) {
        label.stringValue = text
        label.textColor = color
        label.preferredMaxLayoutWidth = maxWidth
        NSLayoutConstraint.deactivate(alignmentConstraints)
        switch placement {
        case .center:
            label.alignment = .center
            alignmentConstraints = [
                label.centerXAnchor.constraint(equalTo: centerXAnchor),
                label.widthAnchor.constraint(lessThanOrEqualToConstant: maxWidth),
            ]
        case .trailing:
            label.alignment = .right
            alignmentConstraints = [label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -18)]
        case .leading:
            label.alignment = .left
            alignmentConstraints = [label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18)]
        }
        NSLayoutConstraint.activate(alignmentConstraints)
    }
}

/// Shown in encrypted chats whose history hasn't been restored in Messenger web yet.
final class RestoreCellView: NSTableCellView {
    private let label = NSTextField(wrappingLabelWithString: "🔒 End-to-end encrypted. Restore your encrypted chats with your PIN to see earlier messages.")
    private let button = NSButton(title: "Restore Encrypted Chats…", target: nil, action: #selector(AppDelegate.showWebSync(_:)))
    private var widthConstraint: NSLayoutConstraint?

    init() {
        super.init(frame: .zero)
        label.font = .systemFont(ofSize: 11, weight: .medium)
        label.textColor = .secondaryLabelColor
        label.alignment = .center
        button.bezelStyle = .push
        button.controlSize = .regular
        for view in [label, button] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        let width = label.widthAnchor.constraint(lessThanOrEqualToConstant: 400)
        widthConstraint = width
        NSLayoutConstraint.activate([
            width,
            label.topAnchor.constraint(equalTo: topAnchor, constant: 16),
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            button.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 8),
            button.centerXAnchor.constraint(equalTo: centerXAnchor),
            button.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(maxWidth: CGFloat) {
        label.preferredMaxLayoutWidth = maxWidth
        widthConstraint?.constant = maxWidth
    }
}

/// "•••" bubble shown while someone is typing.
final class TypingCellView: NSTableCellView {
    private let bubble = BubbleView()
    private let dots = NSTextField(labelWithString: "•••")

    init() {
        super.init(frame: .zero)
        dots.font = .systemFont(ofSize: 20, weight: .bold)
        dots.textColor = .secondaryLabelColor
        for view in [bubble, dots] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
        }
        addSubview(bubble)
        bubble.addSubview(dots)
        NSLayoutConstraint.activate([
            bubble.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            bubble.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            bubble.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
            bubble.heightAnchor.constraint(equalToConstant: 34),
            dots.leadingAnchor.constraint(equalTo: bubble.leadingAnchor, constant: 14),
            dots.trailingAnchor.constraint(equalTo: bubble.trailingAnchor, constant: -14),
            dots.centerYAnchor.constraint(equalTo: bubble.centerYAnchor, constant: -1),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 1
        pulse.toValue = 0.35
        pulse.duration = 0.7
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        dots.wantsLayer = true
        dots.layer?.add(pulse, forKey: "pulse")
    }
}

protocol MessageCellDelegate: AnyObject {
    func messageCell(_ cell: MessageCellView, menuFor message: ChatMessage) -> NSMenu?
    func messageCellDidDoubleClick(_ cell: MessageCellView, message: ChatMessage, bubble: NSView)
    func messageCell(_ cell: MessageCellView, open attachment: Attachment, of message: ChatMessage)
}

/// One message: optional sender name, reply quote, attachments, text bubble and tapbacks.
final class MessageCellView: NSTableCellView {
    struct Layout {
        var showSenderName = false
        var senderName = ""
        var showAvatar = false
        var reserveAvatarSpace = false
        var avatarURL: String?
        var isFirstInGroup = true
        var maxWidth: CGFloat = 400
        /// The chat's custom theme for outgoing bubbles (one color or a gradient); empty for the default.
        var outgoingColors: [NSColor] = []
    }

    weak var delegate: MessageCellDelegate?
    private(set) var message: ChatMessage?

    private let column = NSStackView()
    private let senderLabel = NSTextField(labelWithString: "")
    private let replyView = ReplyQuoteView()
    private let attachmentsStack = NSStackView()
    private let bubble = BubbleView()
    private let textView = MessageTextView()
    private let reactionsBadge = ReactionsBadge()
    private let avatar = AvatarView()
    private let failedIcon = DisplayImageView()

    // Placeholders; the real constraints are created in init once the views exist.
    private var topConstraint = NSLayoutConstraint()
    private var incomingConstraints: [NSLayoutConstraint] = []
    private var outgoingConstraints: [NSLayoutConstraint] = []
    private var incomingAvatarLeading = NSLayoutConstraint()
    private var widthConstraint = NSLayoutConstraint()
    private var badgeIncoming = NSLayoutConstraint()
    private var badgeOutgoing = NSLayoutConstraint()
    private var textInsets: [NSLayoutConstraint] = []

    init() {
        super.init(frame: .zero)

        column.orientation = .vertical
        column.spacing = 3
        column.translatesAutoresizingMaskIntoConstraints = false
        column.setHuggingPriority(.required, for: .horizontal)

        senderLabel.font = .systemFont(ofSize: 11)
        senderLabel.textColor = .secondaryLabelColor

        attachmentsStack.orientation = .vertical
        attachmentsStack.spacing = 3

        textView.translatesAutoresizingMaskIntoConstraints = false
        bubble.addSubview(textView)
        textInsets = [
            textView.leadingAnchor.constraint(equalTo: bubble.leadingAnchor, constant: 12),
            textView.trailingAnchor.constraint(equalTo: bubble.trailingAnchor, constant: -12),
            textView.topAnchor.constraint(equalTo: bubble.topAnchor, constant: 7),
            textView.bottomAnchor.constraint(equalTo: bubble.bottomAnchor, constant: -7),
        ]
        NSLayoutConstraint.activate(textInsets)

        column.addArrangedSubview(senderLabel)
        column.addArrangedSubview(replyView)
        column.addArrangedSubview(attachmentsStack)
        column.addArrangedSubview(bubble)

        failedIcon.image = NSImage(systemSymbolName: "exclamationmark.circle.fill", accessibilityDescription: "Not delivered")
        failedIcon.contentTintColor = .systemRed

        for view in [column, reactionsBadge, avatar, failedIcon] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }

        topConstraint = column.topAnchor.constraint(equalTo: topAnchor, constant: 2)
        widthConstraint = column.widthAnchor.constraint(lessThanOrEqualToConstant: 400)
        incomingAvatarLeading = column.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14)
        incomingConstraints = [incomingAvatarLeading]
        outgoingConstraints = [column.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14)]
        badgeIncoming = reactionsBadge.centerXAnchor.constraint(equalTo: bubble.trailingAnchor, constant: -2)
        badgeOutgoing = reactionsBadge.centerXAnchor.constraint(equalTo: bubble.leadingAnchor, constant: 2)

        NSLayoutConstraint.activate([
            topConstraint,
            widthConstraint,
            column.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -1),
            column.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 14),
            column.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -14),
            reactionsBadge.centerYAnchor.constraint(equalTo: bubble.topAnchor, constant: -2),
            avatar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            avatar.bottomAnchor.constraint(equalTo: column.bottomAnchor),
            avatar.widthAnchor.constraint(equalToConstant: 28),
            avatar.heightAnchor.constraint(equalToConstant: 28),
            failedIcon.trailingAnchor.constraint(equalTo: column.leadingAnchor, constant: -6),
            failedIcon.centerYAnchor.constraint(equalTo: column.centerYAnchor),
        ])

        let doubleClick = NSClickGestureRecognizer(target: self, action: #selector(doubleClicked))
        doubleClick.numberOfClicksRequired = 2
        bubble.addGestureRecognizer(doubleClick)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Lines up a gradient theme with the visible chat (call after layout and on scroll).
    func alignGradient(to clipView: NSClipView) {
        bubble.alignGradient(to: bubble.convert(clipView.bounds, from: clipView))
    }

    /// The view showing one of this message's attachments (for Quick Look's zoom).
    func attachmentView(for attachmentID: String) -> AttachmentView? {
        attachmentsStack.arrangedSubviews.lazy.compactMap { $0 as? AttachmentView }.first { $0.attachmentID == attachmentID }
    }

    func configure(_ message: ChatMessage, layout: Layout, store: ChatStore) {
        self.message = message
        let outgoing = message.isFromMe

        NSLayoutConstraint.deactivate(incomingConstraints + outgoingConstraints + [badgeIncoming, badgeOutgoing])
        NSLayoutConstraint.activate((outgoing ? outgoingConstraints : incomingConstraints) + [outgoing ? badgeOutgoing : badgeIncoming])
        incomingAvatarLeading.constant = layout.reserveAvatarSpace ? 44 : 14
        column.alignment = outgoing ? .trailing : .leading
        widthConstraint.constant = layout.maxWidth

        // Sender name (group chats)
        senderLabel.isHidden = !layout.showSenderName
        senderLabel.stringValue = layout.senderName

        // Avatar (group chats, last message of a run)
        avatar.isHidden = !layout.showAvatar
        if layout.showAvatar {
            avatar.configure(name: layout.senderName, url: layout.avatarURL)
        }

        // Reply quote
        if let reply = message.replyTo, !message.isUnsent {
            replyView.isHidden = false
            let name = reply.senderID.map { store.participantName($0, in: message.threadID) } ?? ""
            replyView.configure(name: name, text: reply.text.isEmpty ? "Attachment" : reply.text, maxWidth: layout.maxWidth)
        } else {
            replyView.isHidden = true
        }

        // Attachments
        for view in attachmentsStack.arrangedSubviews {
            view.removeFromSuperview()
        }
        if !message.isUnsent {
            for attachment in message.attachments {
                let view = AttachmentView(attachment: attachment, message: message, maxWidth: min(layout.maxWidth, 280))
                view.onOpen = { [weak self] in
                    guard let self, let message = self.message else { return }
                    self.delegate?.messageCell(self, open: attachment, of: message)
                }
                attachmentsStack.addArrangedSubview(view)
            }
        }
        attachmentsStack.alignment = outgoing ? .trailing : .leading
        attachmentsStack.isHidden = attachmentsStack.arrangedSubviews.isEmpty

        // Text bubble
        let text = message.isUnsent ? (outgoing ? "You unsent a message" : "Message unsent") : message.text
        let jumbo = !message.isUnsent && text.isJumboEmoji && message.replyTo == nil
        bubble.isHidden = text.isEmpty
        let themed = outgoing && !jumbo && !message.isUnsent
        bubble.color = jumbo || message.isUnsent ? .clear : (outgoing ? layout.outgoingColors.first ?? BubbleColors.outgoing : BubbleColors.incoming)
        bubble.gradientColors = themed && layout.outgoingColors.count > 1 ? layout.outgoingColors : nil
        bubble.layer?.borderWidth = message.isUnsent ? 1 : 0
        bubble.layer?.borderColor = NSColor.separatorColor.cgColor
        let font = jumbo ? NSFont.systemFont(ofSize: 44) : NSFont.systemFont(ofSize: 14)
        let color: NSColor = message.isUnsent ? .secondaryLabelColor : (outgoing && !jumbo ? .white : .labelColor)
        // On the blue bubble links are white; on the gray one they use the system link color.
        let linkColor: NSColor = outgoing && !jumbo ? .white : .linkColor
        textView.linkTextAttributes = [
            .foregroundColor: linkColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .underlineColor: linkColor,
            .cursor: NSCursor.pointingHand,
        ]
        textView.maxWidth = layout.maxWidth - 24
        textView.setText(Self.attributed(text, font: font, color: color, italic: message.isUnsent))
        textInsets[0].constant = jumbo ? 0 : 12
        textInsets[1].constant = jumbo ? 0 : -12
        textInsets[2].constant = jumbo ? 0 : 7
        textInsets[3].constant = jumbo ? 0 : -7

        // Tapbacks
        let emojis = message.reactions.map(\.emoji)
        reactionsBadge.isHidden = emojis.isEmpty || bubble.isHidden
        reactionsBadge.configure(emojis: emojis, highlighted: message.reactions.contains { $0.senderID == store.account?.id })

        // Spacing: tight within a run, looser between runs, extra room for tapbacks.
        topConstraint.constant = (layout.isFirstInGroup ? 8 : 1) + (reactionsBadge.isHidden ? 0 : 12)

        alphaValue = message.status == .pending ? 0.6 : 1
        failedIcon.isHidden = message.status != .failed
        toolTip = Formatters.messageTime(message.date) + (message.isEdited ? " (edited)" : "")
    }

    /// Link styling comes from the text view's linkTextAttributes, so only the URL is attached here.
    private static func attributed(_ text: String, font: NSFont, color: NSColor, italic: Bool) -> NSAttributedString {
        var font = font
        if italic {
            font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
        }
        let result = NSMutableAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
        if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) {
            for match in detector.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                guard let url = match.url else { continue }
                result.addAttribute(.link, value: url, range: match.range)
            }
        }
        return result
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let message else { return nil }
        return delegate?.messageCell(self, menuFor: message)
    }

    @objc private func doubleClicked() {
        guard let message, !message.isUnsent else { return }
        delegate?.messageCellDidDoubleClick(self, message: message, bubble: bubble)
    }
}

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

    // Read-only text: let files dropped on a bubble fall through to the chat's drop target.
    override var acceptableDragTypes: [NSPasteboard.PasteboardType] { [] }
    override func updateDragTypeRegistration() {
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

    /// Right-click shows the message's menu (react, reply, …) rather than the text menu.
    override func menu(for event: NSEvent) -> NSMenu? {
        var view = superview
        while let current = view, !(current is MessageCellView) {
            view = current.superview
        }
        return view?.menu(for: event)
    }
}

/// Small quoted preview shown above a reply.
final class ReplyQuoteView: NSView {
    private let bar = NSView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let textLabel = NSTextField(wrappingLabelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        bar.wantsLayer = true
        bar.layer?.cornerRadius = 1.5
        bar.layer?.backgroundColor = NSColor.tertiaryLabelColor.cgColor
        nameLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        nameLabel.textColor = .secondaryLabelColor
        textLabel.font = .systemFont(ofSize: 12)
        textLabel.textColor = .secondaryLabelColor
        textLabel.maximumNumberOfLines = 2
        textLabel.lineBreakMode = .byTruncatingTail
        textLabel.cell?.truncatesLastVisibleLine = true
        for view in [bar, nameLabel, textLabel] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            bar.topAnchor.constraint(equalTo: topAnchor),
            bar.bottomAnchor.constraint(equalTo: bottomAnchor),
            bar.widthAnchor.constraint(equalToConstant: 3),
            nameLabel.leadingAnchor.constraint(equalTo: bar.trailingAnchor, constant: 6),
            nameLabel.topAnchor.constraint(equalTo: topAnchor),
            nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            textLabel.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            textLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 1),
            textLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            textLabel.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(name: String, text: String, maxWidth: CGFloat) {
        nameLabel.stringValue = name.isEmpty ? "Reply" : name
        textLabel.stringValue = text
        textLabel.preferredMaxLayoutWidth = maxWidth - 20
    }
}

/// Tapback-style bubble with reaction emojis.
final class ReactionsBadge: NSView {
    private let label = NSTextField(labelWithString: "")
    private let background = BubbleView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        background.layer?.cornerRadius = 12
        background.layer?.borderWidth = 2
        for view in [background, label] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        label.font = .systemFont(ofSize: 13)
        NSLayoutConstraint.activate([
            background.leadingAnchor.constraint(equalTo: leadingAnchor),
            background.trailingAnchor.constraint(equalTo: trailingAnchor),
            background.topAnchor.constraint(equalTo: topAnchor),
            background.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(equalToConstant: 24),
            widthAnchor.constraint(greaterThanOrEqualToConstant: 24),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 5),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -5),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(emojis: [String], highlighted: Bool) {
        var unique: [String] = []
        for emoji in emojis where !unique.contains(emoji) {
            unique.append(emoji)
        }
        let countSuffix = emojis.count > 1 ? " \(emojis.count)" : ""
        label.stringValue = unique.prefix(3).joined() + countSuffix
        background.color = highlighted ? BubbleColors.outgoing : BubbleColors.incoming
        background.layer?.borderColor = NSColor.windowBackgroundColor.cgColor
        label.textColor = highlighted ? .white : .labelColor
    }
}

/// Image / video / file / link attachment.
final class AttachmentView: NSView {
    var onOpen: (() -> Void)?

    private let attachment: Attachment
    private let message: ChatMessage
    private let imageView = DisplayImageView()

    init(attachment: Attachment, message: ChatMessage, maxWidth: CGFloat) {
        self.attachment = attachment
        self.message = message
        super.init(frame: .zero)
        wantsLayer = true

        switch attachment.kind {
        case .image, .gif, .sticker, .video:
            setUpVisual(maxWidth: maxWidth)
        case .audio, .file:
            setUpPill(
                symbol: attachment.kind == .audio ? "waveform" : "doc.fill",
                title: attachment.filename ?? (attachment.kind == .audio ? "Audio message" : "File"),
                subtitle: nil,
                maxWidth: maxWidth
            )
        case .link:
            setUpPill(
                symbol: "link",
                title: attachment.title ?? attachment.url ?? "Link",
                subtitle: attachment.url.flatMap { URL(string: $0)?.host() },
                maxWidth: maxWidth
            )
        }

        let click = NSClickGestureRecognizer(target: self, action: #selector(clicked))
        addGestureRecognizer(click)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    @objc private func clicked() {
        onOpen?()
    }

    var attachmentID: String { attachment.id }

    /// The picture shown in the chat (images, GIFs, stickers, video previews); Quick Look zooms from it.
    var displayedImage: NSImage? { imageView.superview == nil ? nil : imageView.image }

    private func setUpVisual(maxWidth: CGFloat) {
        let maxHeight: CGFloat = 320
        var size = CGSize(width: attachment.width ?? 0, height: attachment.height ?? 0)
        if size.width <= 0 || size.height <= 0 {
            size = CGSize(width: 220, height: 220)
        }
        let box = attachment.kind == .sticker ? CGSize(width: 140, height: 140) : CGSize(width: maxWidth, height: maxHeight)
        let scale = min(1, box.width / size.width, box.height / size.height)
        size = CGSize(width: max(60, size.width * scale), height: max(60, size.height * scale))

        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.animates = true
        imageView.wantsLayer = true
        imageView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(imageView)

        if attachment.kind != .sticker {
            layer?.cornerRadius = 16
            layer?.cornerCurve = .continuous
            layer?.masksToBounds = true
            layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor
            imageView.imageScaling = .scaleAxesIndependently
        }
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: size.width),
            heightAnchor.constraint(equalToConstant: size.height),
            imageView.leadingAnchor.constraint(equalTo: leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: trailingAnchor),
            imageView.topAnchor.constraint(equalTo: topAnchor),
            imageView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        if attachment.kind == .video {
            let play = DisplayImageView(image: NSImage(systemSymbolName: "play.circle.fill", accessibilityDescription: "Play") ?? NSImage())
            play.symbolConfiguration = .init(pointSize: 40, weight: .regular)
            play.contentTintColor = .white
            play.translatesAutoresizingMaskIntoConstraints = false
            addSubview(play)
            NSLayoutConstraint.activate([
                play.centerXAnchor.constraint(equalTo: centerXAnchor),
                play.centerYAnchor.constraint(equalTo: centerYAnchor),
            ])
            // Facebook gives video thumbnails; encrypted videos have none.
            if let preview = attachment.previewURL, let url = URL(string: preview) {
                Task { [weak self] in
                    self?.imageView.image = await ImageCache.shared.image(for: url)
                }
            }
            return
        }

        let key = ImageCache.key(for: attachment, in: message)
        if let cached = ImageCache.shared.cached(key) {
            imageView.image = cached
        } else if let path = attachment.localPath, let image = NSImage(contentsOfFile: path) {
            imageView.image = image
        } else {
            Task { [weak self] in
                guard let self else { return }
                self.imageView.image = await ImageCache.shared.image(for: self.attachment, in: self.message)
            }
        }
    }

    private func setUpPill(symbol: String, title: String, subtitle: String?, maxWidth: CGFloat) {
        let background = BubbleView()
        background.color = BubbleColors.incoming
        let icon = DisplayImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage())
        icon.symbolConfiguration = .init(pointSize: 18, weight: .regular)
        icon.contentTintColor = .secondaryLabelColor
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 13, weight: .medium)
        titleLabel.lineBreakMode = .byTruncatingMiddle
        let subtitleLabel = NSTextField(labelWithString: subtitle ?? "")
        subtitleLabel.font = .systemFont(ofSize: 11)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.isHidden = subtitle == nil

        let texts = NSStackView(views: [titleLabel, subtitleLabel])
        texts.orientation = .vertical
        texts.alignment = .leading
        texts.spacing = 1

        for view in [background, icon, texts] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            background.leadingAnchor.constraint(equalTo: leadingAnchor),
            background.trailingAnchor.constraint(equalTo: trailingAnchor),
            background.topAnchor.constraint(equalTo: topAnchor),
            background.bottomAnchor.constraint(equalTo: bottomAnchor),
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            texts.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            texts.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            texts.topAnchor.constraint(equalTo: topAnchor, constant: 9),
            texts.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -9),
            widthAnchor.constraint(lessThanOrEqualToConstant: maxWidth),
        ])
    }
}
