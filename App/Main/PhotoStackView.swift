import AppKit

/// Several photos (and videos) of one message as a fanned stack, like Messages: a "5 Photos"
/// label over a pile of cards. The ones still to come fan out to the right, the ones seen to the
/// left, so you can tell how much is left. A sideways two-finger swipe (or a horizontal wheel)
/// moves to the next or previous picture; a click opens the top one.
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
        label.image = NSImage(systemSymbolName: "square.grid.2x2.fill", accessibilityDescription: nil)
        label.symbolConfiguration = .init(pointSize: 10, weight: .semibold)
        label.imagePosition = .imageLeading
        label.imageHugsTitle = true
        label.isBordered = false
        label.contentTintColor = .controlAccentColor
        label.attributedTitle = NSAttributedString(string: "\(attachments.count) \(noun)", attributes: [
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
/// freely (AppKit doesn't manage layer-hosting views' sublayers). Only the cards near the top one
/// exist; the others are made (and dropped) as you go, so a thousand pictures stay cheap.
final class PhotoDeckView: NSView, NSDraggingSource {
    var onOpen: ((Attachment) -> Void)?
    var onSelect: ((NSEvent.ModifierFlags) -> Void)?

    private let attachments: [Attachment]
    private let message: ChatMessage
    private let cardSize: CGSize
    /// The cards that exist, by index in `attachments`.
    private var cards: [Int: CALayer] = [:]
    private var images: [String: NSImage] = [:]
    /// The top card's index.
    private var current = 0
    private let pressLayer = CALayer()

    private static let cornerRadius: CGFloat = 16
    /// Room around the top card for the fanned cards.
    private static let inset = NSEdgeInsets(top: 8, left: 26, bottom: 8, right: 26)
    /// Cards fanned out on each side; the ones further away hide behind the last of them.
    private static let fanned = 4
    /// Cards kept on each side (the hidden extra ones fade in as they come closer).
    private static let kept = 6
    /// Per card away from the top: turn (degrees, clockwise on the right like Messages), sideways shift, shrink.
    private static let turnStep: CGFloat = 2.2
    private static let shiftStep: CGFloat = 7
    private static let shrinkStep: CGFloat = 0.05

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
        root.isGeometryFlipped = false
        layer = root
        wantsLayer = true

        pressLayer.backgroundColor = NSColor.black.cgColor
        pressLayer.opacity = 0
        pressLayer.zPosition = 1000
        pressLayer.frame = CGRect(origin: .zero, size: cardSize)

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: cardSize.width + Self.inset.left + Self.inset.right),
            heightAnchor.constraint(equalToConstant: cardSize.height + Self.inset.top + Self.inset.bottom),
        ])
        syncCards()
        placeCards(animated: false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    var topAttachment: Attachment? { attachments.indices.contains(current) ? attachments[current] : nil }

    func image(for attachmentID: String) -> NSImage? {
        if let image = images[attachmentID] { return image }
        guard let attachment = attachments.first(where: { $0.id == attachmentID }) else { return nil }
        if attachment.kind == .video {
            return attachment.previewURL.flatMap(URL.init(string:)).flatMap { ImageCache.shared.cached($0) }
        }
        return ImageCache.shared.cached(ImageCache.key(for: attachment, in: message))
    }

    /// The top card's frame (unturned), in this view's coordinates.
    var topCardRect: NSRect {
        NSRect(x: Self.inset.left, y: Self.inset.bottom, width: cardSize.width, height: cardSize.height)
    }

    func bringToTop(_ attachmentID: String) {
        guard let index = attachments.firstIndex(where: { $0.id == attachmentID }), index != current else { return }
        current = index
        offset = 0
        syncCards()
        placeCards(animated: false)
    }

    // MARK: - Cards

    /// Makes the cards near the top one and drops the rest.
    private func syncCards() {
        guard !attachments.isEmpty else { return }
        let range = max(0, current - Self.kept)...min(attachments.count - 1, current + Self.kept)
        for index in cards.keys where !range.contains(index) {
            cards[index]?.removeFromSuperlayer()
            cards[index] = nil
            images[attachments[index].id] = nil
        }
        for index in range where cards[index] == nil {
            let card = makeCard(for: attachments[index])
            cards[index] = card
            // Placed before it's shown, so it doesn't animate there.
            place(card, at: index)
            layer?.addSublayer(card)
            load(attachments[index], into: index)
        }
    }

    private func makeCard(for attachment: Attachment) -> CALayer {
        let card = CALayer()
        card.cornerRadius = Self.cornerRadius
        card.cornerCurve = .continuous
        card.masksToBounds = true
        card.contentsGravity = .resizeAspectFill
        card.bounds = CGRect(origin: .zero, size: cardSize)
        // Turned and shrunk around its middle.
        card.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        card.borderWidth = 0.5
        card.contentsScale = window?.backingScaleFactor ?? 2
        // Stacking order switches at once (an animated one would pass cards through each other).
        card.actions = ["zPosition": NSNull(), "contents": NSNull()]
        effectiveAppearance.performAsCurrentDrawingAppearance {
            card.backgroundColor = NSColor.quaternaryLabelColor.cgColor
            card.borderColor = NSColor.separatorColor.cgColor
        }
        if attachment.kind == .video { addPlayIcon(to: card) }
        return card
    }

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
        // The card may be gone by now (moved far away).
        guard let image, let card = cards[index] else { return }
        images[attachments[index].id] = image
        card.contents = image
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
        icon.contentsScale = card.contentsScale
        card.addSublayer(icon)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        effectiveAppearance.performAsCurrentDrawingAppearance {
            for card in cards.values {
                card.backgroundColor = NSColor.quaternaryLabelColor.cgColor
                card.borderColor = NSColor.separatorColor.cgColor
            }
        }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let scale = window?.backingScaleFactor ?? 2
        for card in cards.values {
            card.contentsScale = scale
            card.sublayers?.forEach { $0.contentsScale = scale }
        }
    }

    // MARK: - Placing the cards

    /// The top card's middle (the cards turn around their middles).
    private var pivot: CGPoint {
        CGPoint(x: Self.inset.left + cardSize.width / 2, y: Self.inset.bottom + cardSize.height / 2)
    }

    private static func transform(angle: CGFloat, scale: CGFloat) -> CATransform3D {
        CATransform3DScale(CATransform3DMakeRotation(angle * .pi / 180, 0, 0, 1), scale, scale, 1)
    }

    /// A card's place: the top one (shifted by `offset` while swiping), the coming ones fanned to
    /// the right, the seen ones to the left, each a bit more turned than the one before it.
    private func place(_ card: CALayer, at index: Int) {
        let distance = index - current
        let pulling = offset > 0 && canMove(forward: false)
        if distance == -1, pulling {
            // Swiping back: the previous card is drawn out of the seen pile to the left, under the
            // top card (the reverse of a card going onto the pile), following the fingers. It's the
            // one at the very back.
            let progress = min(1, offset / throwDistance)
            let step = seenStep(distance)
            card.position = CGPoint(x: pivot.x - step * Self.shiftStep - offset, y: pivot.y)
            let angle = step * Self.turnStep + (8 - step * Self.turnStep) * progress
            let scale = (1 - step * Self.shrinkStep) + (0.97 - (1 - step * Self.shrinkStep)) * progress
            card.transform = Self.transform(angle: angle, scale: scale)
            card.opacity = 1
            card.zPosition = Self.seenZ(distance)
            return
        }
        if distance == 0 {
            // It follows the fingers forward, and past the first picture (as a rubber band).
            let shift = pulling ? 0 : offset
            card.position = CGPoint(x: pivot.x + shift, y: pivot.y)
            card.transform = Self.transform(angle: -shift * 0.04, scale: 1)
            card.opacity = 1
            card.zPosition = 0
            return
        }
        if distance > 0 {
            // Still to come: under the top card in order, each a bit more fanned out to the right.
            let step = CGFloat(min(distance, Self.fanned))
            card.position = CGPoint(x: pivot.x + step * Self.shiftStep, y: pivot.y)
            card.transform = Self.transform(angle: -step * Self.turnStep, scale: 1 - step * Self.shrinkStep)
            card.opacity = distance <= Self.fanned ? 1 : 0
            card.zPosition = -CGFloat(distance)
            return
        }
        // Seen: at the back of the stack, the latest one at the very back and the most fanned out to the left.
        let step = seenStep(distance)
        card.position = CGPoint(x: pivot.x - step * Self.shiftStep, y: pivot.y)
        card.transform = Self.transform(angle: step * Self.turnStep, scale: 1 - step * Self.shrinkStep)
        card.opacity = -distance <= Self.fanned ? 1 : 0
        card.zPosition = Self.seenZ(distance)
    }

    /// How fanned out a seen card is: the latest (at the back) the most, older ones (above it) less.
    private func seenStep(_ distance: Int) -> CGFloat {
        let shown = min(current, Self.fanned)
        return CGFloat(max(1, shown + 1 + distance))
    }

    /// Seen cards are under all the coming ones; the latest seen is the lowest.
    private static func seenZ(_ distance: Int) -> CGFloat {
        -10_000 - CGFloat(distance)
    }

    private func placeCards(animated: Bool, duration: CFTimeInterval = 0.3) {
        CATransaction.begin()
        CATransaction.setDisableActions(!animated)
        CATransaction.setAnimationDuration(duration)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        for (index, card) in cards { place(card, at: index) }
        CATransaction.commit()
    }

    /// Whether there's a card to go to: no wrapping around from the last picture to the first.
    private func canMove(forward: Bool) -> Bool {
        forward ? current < attachments.count - 1 : current > 0
    }

    /// How far a card goes out to the side when it's thrown onto (or taken off) the seen pile: clear
    /// of the top card, so it can change sides (over / under) without showing it.
    private var throwDistance: CGFloat { cardSize.width + 16 }

    /// Moves to the next picture (the top card goes onto the seen pile on the left) or the previous
    /// one (it comes back from there).
    private func move(forward: Bool) {
        guard !animating, canMove(forward: forward) else { return }
        let target = current + (forward ? 1 : -1)
        guard let card = cards[forward ? current : target] else {
            current = target
            offset = 0
            syncCards()
            placeCards(animated: true)
            return
        }
        animating = true
        // Then everything settles into its new place: forward, the old top card goes under, onto
        // the seen pile; back, the drawn-out card goes over, onto the top.
        let settle = { [weak self] in
            guard let self else { return }
            card.zPosition = forward ? -20_000 : 1
            self.current = target
            self.offset = 0
            self.syncCards()
            CATransaction.begin()
            CATransaction.setCompletionBlock { [weak self] in self?.animating = false }
            self.placeCards(animated: true, duration: 0.28)
            CATransaction.commit()
        }
        // Already dragged all the way out: it changes sides right away, then flies into place.
        if forward ? -offset >= throwDistance : offset >= throwDistance {
            settle()
            return
        }
        // First (the rest of the way) out to the left: over the stack going forward, from under it
        // going back; it changes sides only out there.
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.16)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        CATransaction.setCompletionBlock(settle)
        if forward { card.zPosition = 1 }
        card.position = CGPoint(x: pivot.x - throwDistance, y: pivot.y)
        card.transform = Self.transform(angle: 8, scale: 0.97)
        card.opacity = 1
        CATransaction.commit()
    }

    // MARK: - Swiping

    override func scrollWheel(with event: NSEvent) {
        // A mouse's sideways wheel (or Shift-wheel): one card per notch.
        guard event.hasPreciseScrollingDeltas else {
            if abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY), event.scrollingDeltaX != 0 {
                move(forward: event.scrollingDeltaX < 0)
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
        let next = offset + delta
        let blocked = next < 0 ? !canMove(forward: true) : next > 0 ? !canMove(forward: false) : false
        offset += blocked ? delta * 0.25 : delta
        if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
            gesture = .none
            swallowingMomentum = true
            if offset <= -Self.commitDistance, canMove(forward: true) {
                move(forward: true)
            } else if offset >= Self.commitDistance, canMove(forward: false) {
                move(forward: false)
            } else {
                offset = 0
                placeCards(animated: true, duration: 0.2)
            }
        } else {
            // Forward the top card follows the fingers; back, the previous card is drawn out.
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            for index in [current - 1, current] {
                if let card = cards[index] { place(card, at: index) }
            }
            CATransaction.commit()
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
        let picture = image(for: attachment.id)
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
        guard let card = cards[current] else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if pressLayer.superlayer !== card {
            pressLayer.removeFromSuperlayer()
            card.addSublayer(pressLayer)
        }
        pressLayer.opacity = pressed ? 0.05 : 0
        CATransaction.commit()
    }
}
