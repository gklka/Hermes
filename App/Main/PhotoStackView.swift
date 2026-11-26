import AppKit

/// Several photos (and videos) of one message as a fanned stack, like Messages: a "5 Photos"
/// label over a pile of slightly turned cards. A sideways two-finger swipe (or a horizontal wheel)
/// sends the top card to the back or brings the last one forward; a click opens the top one.
final class PhotoStackView: NSView {
    /// Opens a picture (a click on the top card, or the label).
    var onOpen: ((Attachment) -> Void)?
    /// A Shift- or Command-click selects the message instead of opening.
    var onSelect: ((NSEvent.ModifierFlags) -> Void)?

    let attachments: [Attachment]
    private let deck: PhotoDeckView
    private let label = NSButton()

    /// Whether a message's attachments get a stack: two or more photos or videos.
    static func stacked(_ attachments: [Attachment]) -> [Attachment] {
        let pictures = attachments.filter { [.image, .video].contains($0.kind) }
        return pictures.count >= 2 ? pictures : []
    }

    init(attachments: [Attachment], message: ChatMessage, maxWidth: CGFloat, outgoing: Bool) {
        self.attachments = attachments
        deck = PhotoDeckView(attachments: attachments, message: message, maxWidth: maxWidth)
        super.init(frame: .zero)

        let videos = attachments.filter { $0.kind == .video }.count
        let noun = videos == 0 ? "Photos" : videos == attachments.count ? "Videos" : "Items"
        label.title = "\(attachments.count) \(noun)"
        label.image = NSImage(systemSymbolName: "square.grid.2x2.fill", accessibilityDescription: nil)
        label.symbolConfiguration = .init(pointSize: 10, weight: .semibold)
        label.imagePosition = .imageLeading
        label.imageHugsTitle = true
        label.isBordered = false
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        label.contentTintColor = .controlAccentColor
        label.attributedTitle = NSAttributedString(string: label.title, attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: NSColor.controlAccentColor,
        ])
        label.target = self
        label.action = #selector(labelClicked)

        deck.onOpen = { [weak self] in self?.onOpen?($0) }
        deck.onSelect = { [weak self] in self?.onSelect?($0) }

        for view in [label, deck] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: topAnchor),
            outgoing ? label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2)
                : label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            deck.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 2),
            deck.leadingAnchor.constraint(equalTo: leadingAnchor),
            deck.trailingAnchor.constraint(equalTo: trailingAnchor),
            deck.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    @objc private func labelClicked() {
        if let top = deck.topAttachment { onOpen?(top) }
    }

    /// The picture shown for an attachment, if it's loaded.
    func displayedImage(for attachmentID: String) -> NSImage? {
        deck.image(for: attachmentID)
    }

    /// The top card's picture and its frame in `deck` coordinates, after bringing that attachment
    /// to the top (so the viewer zooms back into the card it shows).
    func zoomSource(for attachmentID: String) -> (view: NSView, rect: NSRect, image: NSImage)? {
        deck.bringToTop(attachmentID)
        guard let image = deck.image(for: attachmentID) else { return nil }
        return (deck, deck.topCardRect, image)
    }
}

/// The cards. A layer-hosting view: the cards are plain layers, so they can be turned and moved
/// freely (AppKit doesn't manage layer-hosting views' sublayers).
final class PhotoDeckView: NSView, NSDraggingSource {
    var onOpen: ((Attachment) -> Void)?
    var onSelect: ((NSEvent.ModifierFlags) -> Void)?

    private let attachments: [Attachment]
    private let message: ChatMessage
    private let cardSize: CGSize
    private var cards: [CALayer] = []
    private var images: [String: NSImage] = [:]
    /// Indices into `attachments`, top card first.
    private var order: [Int]
    private let pressLayer = CALayer()

    private static let cornerRadius: CGFloat = 16
    /// Room around the top card for the turned cards behind it.
    private static let inset = NSEdgeInsets(top: 8, left: 6, bottom: 8, right: 6)
    /// The cards behind the top one: sideways offset, turn (degrees) and scale, by depth.
    private static let fan: [(dx: CGFloat, angle: CGFloat, scale: CGFloat)] = [
        (0, 0, 1), (9, -2.5, 0.97), (-7, 2, 0.95), (13, -4, 0.93), (-10, 3.5, 0.91),
    ]

    // Swiping
    private enum Gesture { case none, mine, theirs }
    private var gesture = Gesture.none
    private var swallowingMomentum = false
    private var offset: CGFloat = 0
    private var animating = false
    private static let commitDistance: CGFloat = 50

    // Clicking and dragging out
    private var mouseDownPoint: NSPoint?
    private var downModifiers: NSEvent.ModifierFlags = []

    init(attachments: [Attachment], message: ChatMessage, maxWidth: CGFloat) {
        self.attachments = attachments
        self.message = message
        order = Array(attachments.indices)
        // Every card has the first picture's shape, kept between 3:4 and 4:3.
        let first = attachments.first
        var aspect: CGFloat = 3.0 / 4.0
        if let width = first?.width, let height = first?.height, width > 0, height > 0 {
            aspect = min(4.0 / 3.0, max(3.0 / 4.0, CGFloat(width) / CGFloat(height)))
        }
        let box = CGSize(width: maxWidth - Self.inset.left - Self.inset.right, height: 300)
        let width = min(box.width, box.height * aspect)
        cardSize = CGSize(width: width.rounded(), height: (width / aspect).rounded())
        super.init(frame: .zero)

        // Layer-hosting: set the layer before turning layers on.
        let root = CALayer()
        root.masksToBounds = false
        layer = root
        wantsLayer = true

        for attachment in attachments {
            let card = CALayer()
            card.cornerRadius = Self.cornerRadius
            card.cornerCurve = .continuous
            card.masksToBounds = true
            card.contentsGravity = .resizeAspectFill
            card.bounds = CGRect(origin: .zero, size: cardSize)
            card.borderWidth = 0.5
            // Stacking order switches at once (an animated one would pass cards through each other).
            card.actions = ["zPosition": NSNull(), "contents": NSNull()]
            if attachment.kind == .video { addPlayIcon(to: card) }
            root.addSublayer(card)
            cards.append(card)
        }
        for (index, attachment) in attachments.enumerated() {
            load(attachment, into: index)
        }
        pressLayer.backgroundColor = NSColor.black.cgColor
        pressLayer.opacity = 0
        pressLayer.zPosition = 1000
        updateColors()

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: cardSize.width + Self.inset.left + Self.inset.right),
            heightAnchor.constraint(equalToConstant: cardSize.height + Self.inset.top + Self.inset.bottom),
        ])
        placeCards(animated: false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    var topAttachment: Attachment? { order.first.map { attachments[$0] } }

    func image(for attachmentID: String) -> NSImage? { images[attachmentID] }

    /// The top card's frame (unturned), in this view's coordinates.
    var topCardRect: NSRect {
        NSRect(x: Self.inset.left, y: Self.inset.bottom, width: cardSize.width, height: cardSize.height)
    }

    func bringToTop(_ attachmentID: String) {
        guard let index = attachments.firstIndex(where: { $0.id == attachmentID }),
              let position = order.firstIndex(of: index), position != 0 else { return }
        order = Array(order[position...] + order[..<position])
        placeCards(animated: false)
    }

    // MARK: - Pictures

    private func load(_ attachment: Attachment, into index: Int) {
        if attachment.kind == .video {
            guard let preview = attachment.previewURL, let url = URL(string: preview) else { return }
            if let cached = ImageCache.shared.cached(url) { return show(cached, at: index) }
            Task { [weak self] in
                let image = await ImageCache.shared.image(for: url)
                self?.show(image, at: index)
            }
            return
        }
        let key = ImageCache.key(for: attachment, in: message)
        if let cached = ImageCache.shared.cached(key) { return show(cached, at: index) }
        if let path = attachment.localPath, let image = NSImage(contentsOfFile: path) { return show(image, at: index) }
        Task { [weak self, message] in
            let image = await ImageCache.shared.image(for: attachment, in: message)
            self?.show(image, at: index)
        }
    }

    private func show(_ image: NSImage?, at index: Int) {
        guard let image, cards.indices.contains(index) else { return }
        images[attachments[index].id] = image
        cards[index].contents = image
    }

    private func addPlayIcon(to card: CALayer) {
        let config = NSImage.SymbolConfiguration(pointSize: 40, weight: .regular)
            .applying(.init(paletteColors: [.white]))
        guard let symbol = NSImage(systemSymbolName: "play.circle.fill", accessibilityDescription: "Play")?
            .withSymbolConfiguration(config) else { return }
        let icon = CALayer()
        icon.contents = symbol
        icon.contentsGravity = .resizeAspect
        icon.bounds = CGRect(origin: .zero, size: symbol.size)
        icon.position = CGPoint(x: cardSize.width / 2, y: cardSize.height / 2)
        icon.zPosition = 10
        card.addSublayer(icon)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let scale = window?.backingScaleFactor ?? 2
        for card in cards {
            card.contentsScale = scale
            card.sublayers?.forEach { $0.contentsScale = scale }
        }
    }

    private func updateColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            for card in cards {
                card.backgroundColor = NSColor.quaternaryLabelColor.cgColor
                card.borderColor = NSColor.separatorColor.cgColor
            }
        }
    }

    // MARK: - Placing the cards

    private var center: CGPoint {
        CGPoint(x: Self.inset.left + cardSize.width / 2, y: Self.inset.bottom + cardSize.height / 2)
    }

    private static func fan(at depth: Int) -> (dx: CGFloat, angle: CGFloat, scale: CGFloat) {
        fan[min(depth, fan.count - 1)]
    }

    private static func transform(angle: CGFloat, scale: CGFloat) -> CATransform3D {
        CATransform3DScale(CATransform3DMakeRotation(angle * .pi / 180, 0, 0, 1), scale, scale, 1)
    }

    /// Puts every card in its place for the current order (the top card shifted by `offset`).
    private func placeCards(animated: Bool, duration: CFTimeInterval = 0.3) {
        CATransaction.begin()
        CATransaction.setDisableActions(!animated)
        CATransaction.setAnimationDuration(duration)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        for (depth, index) in order.enumerated() {
            let card = cards[index]
            let fan = Self.fan(at: depth)
            card.zPosition = CGFloat(-depth)
            card.opacity = depth < Self.fan.count ? 1 : 0
            if depth == 0 {
                card.position = CGPoint(x: center.x + offset, y: center.y)
                card.transform = Self.transform(angle: -offset * 0.04, scale: 1)
            } else {
                card.position = CGPoint(x: center.x + fan.dx, y: center.y)
                card.transform = Self.transform(angle: fan.angle, scale: fan.scale)
            }
        }
        CATransaction.commit()
    }

    /// Whether there's a card to go to: no wrapping around from the last picture to the first.
    private func canCycle(forward: Bool) -> Bool {
        guard let top = order.first else { return false }
        return forward ? top < attachments.count - 1 : top > 0
    }

    /// Sends the top card to the back (`forward`), or brings the last card to the top.
    private func cycle(forward: Bool) {
        guard order.count > 1, !animating, canCycle(forward: forward) else { return }
        animating = true
        let throwDistance = cardSize.width * 0.8
        let moving = forward ? order[0] : order[order.count - 1]
        let card = cards[moving]
        let side: CGFloat = forward ? (offset > 0 ? 1 : -1) : (offset < 0 ? -1 : 1)
        // Out to the side…
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.16)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        CATransaction.setCompletionBlock { [weak self] in
            guard let self else { return }
            // …then behind the others (or in front), and everything settles into place.
            if forward {
                self.order.append(self.order.removeFirst())
            } else {
                self.order.insert(self.order.removeLast(), at: 0)
            }
            self.offset = 0
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            card.zPosition = forward ? -CGFloat(self.order.count) : 1
            card.opacity = 1
            CATransaction.commit()
            CATransaction.begin()
            CATransaction.setCompletionBlock { [weak self] in self?.animating = false }
            self.placeCards(animated: true, duration: 0.28)
            CATransaction.commit()
        }
        card.position = CGPoint(x: center.x + side * throwDistance, y: center.y)
        card.transform = Self.transform(angle: -side * 8, scale: forward ? 0.95 : 1)
        card.opacity = 1
        CATransaction.commit()
    }

    // MARK: - Swiping

    override func scrollWheel(with event: NSEvent) {
        // A mouse's sideways wheel (or Shift-wheel): one card per notch.
        guard event.hasPreciseScrollingDeltas else {
            if abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY), event.scrollingDeltaX != 0 {
                cycle(forward: event.scrollingDeltaX < 0)
            } else {
                super.scrollWheel(with: event)
            }
            return
        }
        // The momentum after a swipe of ours.
        if event.momentumPhase != [] {
            if swallowingMomentum {
                if event.momentumPhase.contains(.ended) || event.momentumPhase.contains(.cancelled) { swallowingMomentum = false }
                return
            }
            super.scrollWheel(with: event)
            return
        }
        if event.phase.contains(.began) || event.phase.contains(.mayBegin) {
            swallowingMomentum = false
            gesture = .none
        }
        if gesture == .none, event.scrollingDeltaX != 0 || event.scrollingDeltaY != 0 {
            // The first movement decides: sideways is ours, up and down scrolls the chat.
            gesture = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) && !animating ? .mine : .theirs
        }
        guard gesture == .mine else {
            super.scrollWheel(with: event)
            if event.phase.contains(.ended) || event.phase.contains(.cancelled) { gesture = .none }
            return
        }
        // Follow the fingers.
        let delta = event.isDirectionInvertedFromDevice ? event.scrollingDeltaX : -event.scrollingDeltaX
        // Past the first or last picture it only gives a little, like a rubber band.
        let blocked = offset + delta < 0 ? !canCycle(forward: true) : offset + delta > 0 ? !canCycle(forward: false) : false
        offset += blocked ? delta * 0.25 : delta
        if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
            gesture = .none
            swallowingMomentum = true
            if offset <= -Self.commitDistance, canCycle(forward: true) {
                cycle(forward: true)
            } else if offset >= Self.commitDistance, canCycle(forward: false) {
                cycle(forward: false)
            } else {
                offset = 0
                placeCards(animated: true, duration: 0.2)
            }
        } else {
            placeCards(animated: false)
        }
    }

    // MARK: - Clicking and dragging out

    override func mouseDown(with event: NSEvent) {
        guard !animating else { return }
        mouseDownPoint = event.locationInWindow
        downModifiers = event.modifierFlags.intersection([.command, .shift])
        setPressed(true)
    }

    override func mouseUp(with event: NSEvent) {
        setPressed(false)
        if mouseDownPoint != nil {
            mouseDownPoint = nil
            if downModifiers.isEmpty {
                if let top = topAttachment { onOpen?(top) }
            } else {
                onSelect?(downModifiers)
            }
        }
        super.mouseUp(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        guard downModifiers.isEmpty, let start = mouseDownPoint, LinkDrag.isDrag(from: start, to: event),
              let top = topAttachment else {
            super.mouseDragged(with: event)
            return
        }
        mouseDownPoint = nil
        setPressed(false)
        let item = NSDraggingItem(pasteboardWriter: AttachmentFilePromise(attachment: top, message: message))
        item.setDraggingFrame(topCardRect, contents: dragImage(of: top))
        beginDraggingSession(with: [item], event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }

    private func dragImage(of attachment: Attachment) -> NSImage {
        let size = cardSize
        let picture = images[attachment.id]
        return NSImage(size: size, flipped: false) { rect in
            NSBezierPath(roundedRect: rect, xRadius: Self.cornerRadius, yRadius: Self.cornerRadius).addClip()
            if let picture {
                // Aspect fill, like the card.
                let scale = max(rect.width / picture.size.width, rect.height / picture.size.height)
                let drawn = NSSize(width: picture.size.width * scale, height: picture.size.height * scale)
                picture.draw(in: NSRect(x: (rect.width - drawn.width) / 2, y: (rect.height - drawn.height) / 2,
                                        width: drawn.width, height: drawn.height))
            } else {
                NSColor.quaternaryLabelColor.setFill()
                rect.fill()
            }
            return true
        }
    }

    /// Darkens the top card while the mouse is held down on it.
    private func setPressed(_ pressed: Bool) {
        guard let index = order.first else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if pressLayer.superlayer !== cards[index] {
            pressLayer.removeFromSuperlayer()
            pressLayer.frame = CGRect(origin: .zero, size: cardSize)
            cards[index].addSublayer(pressLayer)
        }
        pressLayer.opacity = pressed ? 0.05 : 0
        CATransaction.commit()
    }
}
