import AppKit

/// Group chat polls, like in Messages: made in the compose field (ComposePollPanel), and shown
/// in the chat as a bubble per option (PollBubblesView), which you click to vote.
enum PollLimits {
    // Messenger's web app's (MessengerWebPollConstants).
    static let questionLength = 200
    static let optionLength = 140
    /// Choices typed at once (when creating a poll, or adding to one).
    static let options = 10
    static let minOptions = 2

    /// Options are the same when they only differ in case or surrounding spaces.
    static func key(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }
}

/// Polls' colors, like Messages' orange.
enum PollColors {
    static let accent = NSColor.systemOrange
    /// An option you haven't voted for: the accent, faint.
    static let unvoted = NSColor(name: nil) { appearance in
        let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return NSColor.systemOrange.withAlphaComponent(dark ? 0.32 : 0.18)
    }
}

// MARK: - Making a poll

/// In the compose field while making a poll, like Messages: the choices, one per line ("Choice
/// 3" waits under the last one), and ✕ to stop. The field under it is the question. Adding
/// choices to a sent poll shows its options above the new ones.
final class ComposePollPanel: NSView, NSTextFieldDelegate {
    enum Mode: Equatable {
        case create
        case addChoices(Poll)
    }

    private(set) var mode: Mode = .create
    var onChange: (() -> Void)?
    var onClose: (() -> Void)?
    /// Return in the last choice: on to the question.
    var onFinishChoices: (() -> Void)?

    private let stack = NSStackView()
    private let scroll = NSScrollView()
    private let closeButton = NSButton()
    private var scrollHeight = NSLayoutConstraint()
    private var fields: [NSTextField] = []
    private var existing: [String] = []

    private static let maxHeight: CGFloat = 300
    private static let font = NSFont.systemFont(ofSize: 15, weight: .bold)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 20, bottom: 14, right: 44)
        let document = PollFlippedView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)
        document.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = document
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false

        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Cancel Poll")
        closeButton.symbolConfiguration = .init(pointSize: 13, weight: .bold)
        closeButton.isBordered = false
        closeButton.contentTintColor = .labelColor
        closeButton.target = self
        closeButton.action = #selector(closeClicked)
        closeButton.toolTip = "Cancel Poll"

        for view in [scroll, closeButton] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        scrollHeight = scroll.heightAnchor.constraint(equalToConstant: 40)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollHeight,
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            stack.topAnchor.constraint(equalTo: document.topAnchor),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor),
            closeButton.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.labelColor.withAlphaComponent(0.08).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 14, yRadius: 14).fill()
    }

    /// Starts over: empty choices, or a sent poll's options and one for a new choice.
    func start(_ mode: Mode) {
        self.mode = mode
        for view in stack.arrangedSubviews {
            view.removeFromSuperview()
        }
        fields = []
        existing = []
        if case .addChoices(let poll) = mode {
            for option in poll.options {
                let label = NSTextField(labelWithString: option.text)
                label.font = Self.font
                label.textColor = .secondaryLabelColor
                label.lineBreakMode = .byTruncatingTail
                stack.addArrangedSubview(label)
                label.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -64).isActive = true
                existing.append(option.text)
            }
        }
        for _ in 0..<minFields {
            addField()
        }
        updateHeight()
    }

    func focusFirstChoice() {
        if let field = fields.first {
            window?.makeFirstResponder(field)
        }
    }

    /// Shift-Tab from the question: the last choice that has text, or the empty one.
    func focusLastChoice() {
        if let field = fields.last(where: { !text(of: $0).isEmpty }) ?? fields.last {
            window?.makeFirstResponder(field)
        }
    }

    /// The choices typed (not the sent poll's own).
    var choices: [String] {
        fields.map { text(of: $0).trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    /// Two different choices for a new poll, one for a sent one; none the same as another.
    var canSend: Bool {
        let all = existing + choices
        guard Set(all.map(PollLimits.key)).count == all.count else { return false }
        return choices.count >= (mode == .create ? PollLimits.minOptions : 1)
    }

    private var minFields: Int { mode == .create ? PollLimits.minOptions : 1 }

    private func addField() {
        let field = NSTextField()
        field.placeholderString = "Choice \(existing.count + fields.count + 1)"
        field.font = Self.font
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.delegate = self
        field.cell?.usesSingleLineMode = true
        field.cell?.lineBreakMode = .byTruncatingTail
        stack.addArrangedSubview(field)
        field.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -64).isActive = true
        fields.append(field)
    }

    private func updateHeight() {
        stack.layoutSubtreeIfNeeded()
        scrollHeight.constant = min(stack.fittingSize.height, Self.maxHeight)
    }

    /// A field's text, also while it's being typed in.
    private func text(of field: NSTextField) -> String {
        (field.currentEditor() as? NSTextView)?.string ?? field.stringValue
    }

    func controlTextDidChange(_ obj: Notification) {
        guard let field = obj.object as? NSTextField else { return }
        if text(of: field).count > PollLimits.optionLength {
            field.stringValue = String(text(of: field).prefix(PollLimits.optionLength))
        }
        // Typing in the last choice puts an empty one under it.
        if field === fields.last, !text(of: field).isEmpty, fields.count < PollLimits.options {
            addField()
            updateHeight()
            if let document = scroll.documentView {
                document.scroll(NSPoint(x: 0, y: document.bounds.height))
            }
        }
        onChange?()
    }

    /// Leaving a choice: emptied ones go (an empty one stays last).
    func controlTextDidEndEditing(_ obj: Notification) {
        for field in fields.dropLast() where fields.count > minFields && field.currentEditor() == nil
            && field.stringValue.trimmingCharacters(in: .whitespaces).isEmpty {
            field.removeFromSuperview()
            fields.removeAll { $0 === field }
        }
        for (index, field) in fields.enumerated() {
            field.placeholderString = "Choice \(existing.count + index + 1)"
        }
        updateHeight()
        onChange?()
    }

    /// Return and Tab go to the next choice (from the last, to the question), Shift-Tab to the
    /// one before; Escape stops.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        let index = fields.firstIndex { $0 === control }
        switch commandSelector {
        case #selector(NSResponder.insertTab(_:)):
            if let index, index + 1 < fields.count {
                window?.makeFirstResponder(fields[index + 1])
            } else {
                onFinishChoices?()
            }
            return true
        case #selector(NSResponder.insertBacktab(_:)):
            if let index, index > 0 {
                window?.makeFirstResponder(fields[index - 1])
            }
            return true
        case #selector(NSResponder.insertNewline(_:)):
            if let field = control as? NSTextField, let index = fields.firstIndex(where: { $0 === field }),
               index + 1 < fields.count, !text(of: field).isEmpty {
                window?.makeFirstResponder(fields[index + 1])
            } else {
                onFinishChoices?()
            }
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            onClose?()
            return true
        default:
            return false
        }
    }

    @objc private func closeClicked() {
        onClose?()
    }
}

private final class PollFlippedView: NSView {
    override var isFlipped: Bool { true }
}

// MARK: - The poll in the chat

/// A poll in the chat, like in Messages: a bubble per option, the wider the more votes it has
/// (the leader widest), filled where you voted and with a ring where you haven't, and its voters'
/// pictures on it. Clicking an option votes for it, or takes the vote back. Add Choice under
/// them, and the question in a bubble below (where Messages has the poll's comment).
/// New votes animate: the bubbles grow or shrink (with a little bounce), fill or empty, and new
/// choices fade in. Your clicks show at once; Messenger's copy of the poll only replaces what's
/// shown when it differs (someone else voted), and not while your votes are on their way.
final class PollBubblesView: NSView {
    /// Your votes now (every option you chose; you can choose several).
    var onVote: ((_ selected: [String]) -> Void)?
    var onAddChoice: (() -> Void)?
    /// You, as shown among an option's voters once you vote for it.
    var me: Participant?
    private let stack = NSStackView()
    private let addChoice = NSButton(title: "", target: nil, action: nil)
    private var bubbles: [String: PollOptionBubble] = [:]
    private var question: (text: String, view: QuestionBubble)?
    private let outgoing: Bool
    private let maxWidth: CGFloat
    private let questionColor: NSColor

    /// What's shown, the latest copy from Messenger, and how many of your votes are on their way.
    private var current: Poll
    private var latest: Poll
    private var votesSending = 0

    static let bubbleHeight: CGFloat = 40
    static let animationDuration: TimeInterval = 0.35
    /// Ease out, overshooting a little before it settles.
    static let bounce = CAMediaTimingFunction(controlPoints: 0.34, 1.4, 0.64, 1)
    private static let spacing: CGFloat = 4
    private static let font = NSFont.systemFont(ofSize: 15, weight: .bold)
    private static let maxBubbleWidth: CGFloat = 340

    init(poll: Poll, outgoing: Bool, maxWidth: CGFloat, questionColor: NSColor) {
        self.outgoing = outgoing
        self.maxWidth = maxWidth
        self.questionColor = questionColor
        current = poll
        latest = poll
        super.init(frame: .zero)
        addChoice.target = self
        addChoice.action = #selector(addChoiceClicked)
        addChoice.isBordered = false
        addChoice.attributedTitle = NSAttributedString(string: "Add Choice", attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: PollColors.accent,
        ])

        stack.orientation = .vertical
        stack.alignment = outgoing ? .trailing : .leading
        stack.spacing = Self.spacing
        stack.addArrangedSubview(addChoice)
        stack.setCustomSpacing(6, after: addChoice)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        setAccessibilityElement(false)
        apply(poll, animated: false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// The poll to show once the chat's reload is done.
    private var pendingPoll: Poll?

    /// Whether these bubbles can show the poll for this side, width and color (else new ones).
    func fits(outgoing: Bool, maxWidth: CGFloat, questionColor: NSColor) -> Bool {
        outgoing == self.outgoing && maxWidth == self.maxWidth && questionColor == self.questionColor
    }

    /// Messenger's copy of the poll; `animated`: changes from what's shown animate. Dropped
    /// while your votes are on their way, or when it shows what's shown already.
    func update(_ poll: Poll, animated: Bool) {
        latest = poll
        guard votesSending == 0, Self.votes(of: poll) != Self.votes(of: pendingPoll ?? current) else {
            if votesSending == 0, pendingPoll == nil { current = poll }
            return
        }
        guard animated else {
            pendingPoll = nil
            apply(poll, animated: false)
            return
        }
        // The chat reloads its table (taking the cell out of the window) and lays it out at
        // once; changed then, nothing would animate. So it changes right after.
        pendingPoll = poll
        DispatchQueue.main.async { [weak self] in
            guard let self, let poll = self.pendingPoll else { return }
            self.pendingPoll = nil
            self.apply(poll, animated: self.window != nil)
        }
    }

    /// What a copy of the poll shows: its options, their votes and who cast them.
    private static func votes(of poll: Poll) -> [String] {
        poll.options.map { option in
            "\(option.id)|\(option.text)|\(option.voted == true)|\(option.voteCount)|" + option.voters.map(\.id).joined(separator: ",")
        } + [poll.question ?? ""]
    }

    /// Your click: the option toggles at once (your other votes stay), then the vote is sent.
    private func toggle(_ optionID: String) {
        var poll = pendingPoll ?? current
        guard let index = poll.options.firstIndex(where: { $0.id == optionID }) else { return }
        var option = poll.options[index]
        if option.voted == true {
            option.voted = false
            option.voteCount = max(0, option.voteCount - 1)
            option.voters.removeAll { $0.id == me?.id }
        } else {
            option.voted = true
            option.voteCount += 1
            if let me {
                option.voters.insert(me, at: 0)
            }
        }
        poll.options[index] = option
        pendingPoll = nil
        apply(poll, animated: window != nil)
        bubbles[optionID]?.pop()
        votesSending += 1
        onVote?(poll.options.filter { $0.voted == true }.map(\.id))
    }

    /// A vote you clicked was sent (or not). Once they all are, Messenger's copy of the poll
    /// shows if it differs (if one failed, that's how it was).
    func voteFinished() {
        votesSending = max(0, votesSending - 1)
        if votesSending == 0 {
            update(latest, animated: true)
        }
    }

    private func apply(_ poll: Poll, animated: Bool) {
        current = poll
        let ids = Set(poll.options.map(\.id))
        for (id, bubble) in bubbles where !ids.contains(id) {
            bubble.removeFromSuperview()
            bubbles[id] = nil
        }
        let widths = Self.widths(of: poll.options, maxWidth: min(maxWidth, Self.maxBubbleWidth))
        var appeared: [PollOptionBubble] = []
        for (index, (option, width)) in zip(poll.options, widths).enumerated() {
            let bubble = bubbles[option.id] ?? makeBubble(for: option.id, appeared: &appeared)
            if stack.arrangedSubviews.firstIndex(of: bubble) != index {
                stack.insertArrangedSubview(bubble, at: index)
            }
            bubble.show(option, width: width, animated: animated && !appeared.contains(bubble))
        }
        if let last = poll.options.last.flatMap({ bubbles[$0.id] }) {
            stack.setCustomSpacing(6, after: last)
        }
        updateQuestion(poll.question ?? "")

        guard animated else {
            for bubble in bubbles.values { bubble.alphaValue = 1 }
            return
        }
        for bubble in appeared { bubble.alphaValue = 0 }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.animationDuration
            context.timingFunction = Self.bounce
            context.allowsImplicitAnimation = true
            for bubble in appeared { bubble.animator().alphaValue = 1 }
            layoutSubtreeIfNeeded()
        }
    }

    private func makeBubble(for id: String, appeared: inout [PollOptionBubble]) -> PollOptionBubble {
        let bubble = PollOptionBubble(font: Self.font, height: Self.bubbleHeight)
        bubble.onClick = { [weak self] in
            self?.toggle(id)
        }
        bubbles[id] = bubble
        appeared.append(bubble)
        return bubble
    }

    private func updateQuestion(_ text: String) {
        guard text != question?.text else { return }
        question?.view.removeFromSuperview()
        question = nil
        guard !text.isEmpty else { return }
        let view = QuestionBubble(text: text, color: questionColor, outgoing: outgoing, maxWidth: maxWidth)
        stack.addArrangedSubview(view)
        question = (text, view)
    }

    @objc private func addChoiceClicked() {
        onAddChoice?()
    }

    /// Each option's bubble width: wide enough for every option's text, and wider by its share
    /// of the leader's votes, up to `maxWidth` for the leader.
    private static func widths(of options: [Poll.Option], maxWidth: CGFloat) -> [CGFloat] {
        let natural = options.map { PollOptionBubble.naturalWidth(of: $0, font: font) }
        let base = min(natural.max() ?? 0, maxWidth)
        let leader = options.map(\.voteCount).max() ?? 0
        return zip(options, natural).map { option, own in
            let share = leader > 0 ? CGFloat(option.voteCount) / CGFloat(leader) : 0
            return min(maxWidth, max(own, base + (maxWidth - base) * share))
        }
    }
}

/// An option's bubble: filled in the accent color if you voted for it, faint with a ring if
/// not; the voters' pictures at its end.
private final class PollOptionBubble: NSView {
    var onClick: (() -> Void)?
    private(set) var option: Poll.Option?
    private var voted = false
    private let label = NSTextField(labelWithString: "")
    private let ring = PollRing()
    /// Holds the voters' pictures (replaced, crossfading, when they change).
    private let facesHolder = NSView()
    private var faces: PollFacepile?
    private var widthConstraint = NSLayoutConstraint()
    private var facesWidth = NSLayoutConstraint()
    private var facesTrailing = NSLayoutConstraint()

    private static let sideInset: CGFloat = 20
    private static let ringSize: CGFloat = 24
    private static let faceSize: CGFloat = 24

    init(font: NSFont, height: CGFloat) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = height / 2
        layer?.cornerCurve = .continuous
        label.font = font
        label.lineBreakMode = .byTruncatingTail
        label.wantsLayer = true
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        facesHolder.wantsLayer = true

        // The ring over the pictures, which are cut away around it (layout()).
        for view in [label, facesHolder, ring] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        widthConstraint = widthAnchor.constraint(equalToConstant: 0)
        facesWidth = facesHolder.widthAnchor.constraint(equalToConstant: 0)
        facesTrailing = facesHolder.trailingAnchor.constraint(equalTo: trailingAnchor)
        NSLayoutConstraint.activate([
            widthConstraint,
            heightAnchor.constraint(equalToConstant: height),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.sideInset),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: facesHolder.leadingAnchor, constant: -10),
            ring.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            ring.centerYAnchor.constraint(equalTo: centerYAnchor),
            ring.widthAnchor.constraint(equalToConstant: Self.ringSize),
            ring.heightAnchor.constraint(equalToConstant: Self.ringSize),
            facesHolder.centerYAnchor.constraint(equalTo: centerYAnchor),
            facesHolder.heightAnchor.constraint(equalToConstant: Self.faceSize),
            facesWidth,
            facesTrailing,
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.checkBox)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Shows the option. Animated, the color, text color, ring and pictures crossfade; the
    /// width and the pictures' place move with the caller's animation (layout).
    func show(_ option: Poll.Option, width: CGFloat, animated: Bool) {
        let previous = self.option
        self.option = option
        let wasVoted = voted
        voted = option.voted == true
        widthConstraint.constant = width
        // Without your vote, the ring is last and the pictures overlap its left edge.
        facesTrailing.constant = voted ? -12 : -(10 + Self.ringSize - 6)

        if label.stringValue != option.text {
            label.stringValue = option.text
        }
        if previous == nil || wasVoted != voted {
            if animated { label.layer?.add(Self.fade(), forKey: "fade") }
            label.textColor = voted ? .white : PollColors.accent
            applyBackground(animated: animated)
            if animated {
                ring.animator().alphaValue = voted ? 0 : 1
            } else {
                ring.alphaValue = voted ? 0 : 1
            }
        }
        if previous?.voters != option.voters {
            faces?.removeFromSuperview()
            let pile = PollFacepile(voters: option.voters, size: Self.faceSize)
            pile.translatesAutoresizingMaskIntoConstraints = false
            facesHolder.addSubview(pile)
            NSLayoutConstraint.activate([
                pile.trailingAnchor.constraint(equalTo: facesHolder.trailingAnchor),
                pile.centerYAnchor.constraint(equalTo: facesHolder.centerYAnchor),
            ])
            faces = pile
            facesWidth.constant = pile.width
            if animated { facesHolder.layer?.add(Self.fade(), forKey: "fade") }
        }

        let names = option.voters.map(\.name).filter { !$0.isEmpty }
        let count = option.voteCount == 1 ? "1 vote" : "\(option.voteCount) votes"
        toolTip = names.isEmpty ? count : "\(count): " + names.joined(separator: ", ")
        setAccessibilityLabel("\(option.text), \(count)")
        setAccessibilityValue(voted ? 1 : 0)
        // The cut around the ring (layout()).
        needsLayout = true
    }

    private static func fade() -> CATransition {
        let fade = CATransition()
        fade.type = .fade
        fade.duration = PollBubblesView.animationDuration
        return fade
    }

    /// The fill, as the current appearance resolves it.
    private func applyBackground(animated: Bool) {
        var color = NSColor.clear.cgColor
        effectiveAppearance.performAsCurrentDrawingAppearance {
            color = (self.voted ? PollColors.accent : PollColors.unvoted).cgColor
        }
        if animated, let from = layer?.backgroundColor {
            let animation = CABasicAnimation(keyPath: "backgroundColor")
            animation.fromValue = from
            animation.toValue = color
            animation.duration = PollBubblesView.animationDuration
            animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            layer?.add(animation, forKey: "backgroundColor")
        }
        layer?.backgroundColor = color
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyBackground(animated: false)
    }

    override func layout() {
        super.layout()
        updateFacesMask()
    }

    /// Without your vote, the pictures are cut away around the ring (a little wider than it), like
    /// in Messages.
    private func updateFacesMask() {
        guard let holderLayer = facesHolder.layer else { return }
        guard !voted, faces != nil else {
            holderLayer.mask = nil
            return
        }
        let ringFrame = facesHolder.convert(ring.frame, from: self).insetBy(dx: -2, dy: -2)
        let path = CGMutablePath()
        path.addRect(facesHolder.bounds)
        path.addEllipse(in: ringFrame)
        let mask = (holderLayer.mask as? CAShapeLayer) ?? CAShapeLayer()
        mask.fillRule = .evenOdd
        mask.path = path
        mask.frame = facesHolder.bounds
        holderLayer.mask = mask
    }

    /// Room for the text, the voters' pictures and the ring.
    static func naturalWidth(of option: Poll.Option, font: NSFont) -> CGFloat {
        let text = ceil((option.text as NSString).size(withAttributes: [.font: font]).width)
        let shownFaces = min(option.voters.count, 3)
        let faces = shownFaces == 0 ? 0 : faceSize + CGFloat(shownFaces - 1) * faceSize * 0.65 + 10
        let ring = option.voted == true ? 12 : ringSize + 10
        return sideInset + text + 14 + faces + ring
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onClick?()
    }

    override func accessibilityPerformPress() -> Bool {
        onClick?()
        return true
    }

    /// A clicked bubble springs: squeezed a little, back to its size with a bounce.
    func pop() {
        guard let layer else { return }
        let center = CGPoint(x: layer.bounds.midX, y: layer.bounds.midY)
        var from = CATransform3DMakeTranslation(center.x, center.y, 0)
        from = CATransform3DScale(from, 0.94, 0.94, 1)
        from = CATransform3DTranslate(from, -center.x, -center.y, 0)
        let spring = CASpringAnimation(keyPath: "transform")
        spring.fromValue = from
        spring.toValue = CATransform3DIdentity
        spring.damping = 12
        spring.stiffness = 300
        spring.duration = spring.settlingDuration
        layer.add(spring, forKey: "pop")
    }
}

/// The ring on an option you haven't voted for.
private final class PollRing: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(ovalIn: bounds.insetBy(dx: 1, dy: 1))
        path.lineWidth = 2
        PollColors.accent.setStroke()
        path.stroke()
    }
}

/// The poll's question, in a message bubble.
private final class QuestionBubble: NSView {
    init(text: String, color: NSColor, outgoing: Bool, maxWidth: CGFloat) {
        super.init(frame: .zero)
        let bubble = BubbleView()
        bubble.color = color
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = BubbleMetrics.font
        label.textColor = outgoing ? .white : .labelColor
        let insets = BubbleMetrics.textInsets
        label.preferredMaxLayoutWidth = maxWidth - insets.left - insets.right
        for view in [bubble, label] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            bubble.leadingAnchor.constraint(equalTo: leadingAnchor),
            bubble.trailingAnchor.constraint(equalTo: trailingAnchor),
            bubble.topAnchor.constraint(equalTo: topAnchor),
            bubble.bottomAnchor.constraint(equalTo: bottomAnchor),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: insets.left),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -insets.right),
            label.topAnchor.constraint(equalTo: topAnchor, constant: insets.top),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -insets.bottom),
            widthAnchor.constraint(lessThanOrEqualToConstant: maxWidth),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}

/// Up to three voters' pictures, overlapping (the newest on top).
final class PollFacepile: NSView {
    let width: CGFloat

    init(voters: [Participant], size: CGFloat) {
        let count = min(voters.count, 3)
        width = count == 0 ? 0 : size + CGFloat(count - 1) * size * 0.65
        super.init(frame: .zero)
        let shown = Array(voters.prefix(3))
        let step = size * 0.65
        for (index, voter) in shown.enumerated().reversed() {
            let avatar = AvatarView()
            avatar.configure(name: voter.name, url: voter.avatarURL)
            avatar.translatesAutoresizingMaskIntoConstraints = false
            addSubview(avatar)
            NSLayoutConstraint.activate([
                avatar.widthAnchor.constraint(equalToConstant: size),
                avatar.heightAnchor.constraint(equalToConstant: size),
                avatar.topAnchor.constraint(equalTo: topAnchor),
                avatar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: CGFloat(index) * step),
            ])
        }
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: width),
            heightAnchor.constraint(equalToConstant: size),
        ])
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}

/// A poll as its own row, under its system message ("… created a poll"), on its creator's side.
/// The bubbles are the chat's (ChatViewController.pollViews), moved into whichever cell shows
/// them, so they stay the same views across reloads.
final class PollCardCellView: NSTableCellView {
    private var bubbles: PollBubblesView?

    func host(_ view: PollBubblesView, outgoing: Bool) {
        guard view.superview !== self else { return }
        if bubbles?.superview === self {
            bubbles?.removeFromSuperview()
        }
        view.removeFromSuperview()
        view.translatesAutoresizingMaskIntoConstraints = false
        addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            view.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
            outgoing
                ? view.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -BubbleMetrics.sideInset)
                : view.leadingAnchor.constraint(equalTo: leadingAnchor, constant: BubbleMetrics.avatarSideInset),
        ])
        bubbles = view
    }
}

// MARK: - Voting

extension ChatViewController {
    /// Your votes after a click (already shown): every option you chose. Votes go out in order,
    /// so the last click wins.
    func sendPollVote(_ selected: [String], in poll: Poll, threadID: String, from bubbles: PollBubblesView) {
        Task { [weak self, weak bubbles] in
            do {
                try await ChatStore.shared.vote(in: poll.id, threadID: threadID, selected: selected, added: [])
            } catch {
                self?.showPollError("Your vote couldn't be sent", error)
            }
            bubbles?.voteFinished()
        }
    }

    func showPollError(_ message: String, _ error: Error) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = error.localizedDescription
        if let window = view.window {
            alert.beginSheetModal(for: window, completionHandler: nil)
        }
    }
}
