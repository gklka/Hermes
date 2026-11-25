import AppKit
import ImageIO
import QuickLookUI
import UniformTypeIdentifiers
import VisionKit

/// Shows message attachments with Quick Look's preview view in our own window, so pictures zoom
/// out of the chat and back (Quick Look's own panel animates its window frame instead, which
/// looks broken), and the window opens at the picture's final size even before it's downloaded.
/// ← / → browse the message's attachments; Esc, Space or the close button close it.
final class MediaViewer: NSObject, NSWindowDelegate {
    static let shared = MediaViewer()

    struct Item {
        var url: URL
        var title: String
        /// The picture's size in pixels (shown 1 point per pixel, scaled down to fit the screen);
        /// nil for anything that isn't a picture.
        var pixelSize: CGSize?
    }

    /// For zooming: where item `index`'s picture is in the chat (on screen) and the picture.
    /// Nil when it isn't visible.
    typealias SourceProvider = (_ index: Int) -> (frame: NSRect, image: NSImage)?

    /// Loads item `index` (nil if it's unavailable).
    typealias ItemLoader = (_ index: Int) async -> Item?

    /// nil: not loaded yet.
    private var items: [Item?] = []
    private var index = 0
    /// The item ← / → is heading to while it loads.
    private var pendingIndex: Int?
    private var loader: ItemLoader?
    private var sourceProvider: SourceProvider?
    private var window: ViewerWindow?
    private var previewView: QLPreviewView?
    /// Shows pictures in-process so macOS Live Text (text recognition) works on them; Quick Look's
    /// view renders out of process and doesn't offer it. Used for pictures; QLPreviewView for the rest.
    private var imageView: LiveTextImageView?
    private var isClosing = false

    private static let animationDuration: TimeInterval = 0.28

    var isVisible: Bool { window?.isVisible == true }

    /// Shows `first` (item `index` of `count`); the others are loaded with `load` when ← / →
    /// reach them.
    func show(_ first: Item, at index: Int, count: Int, over parent: NSWindow?,
              load: @escaping ItemLoader, source: @escaping SourceProvider) {
        guard count > 0, (0..<count).contains(index) else { return }
        // Replace whatever was showing.
        window?.orderOut(nil)
        previewView?.close()

        items = Array(repeating: nil, count: count)
        items[index] = first
        self.index = index
        pendingIndex = nil
        loader = load
        sourceProvider = source
        isClosing = false

        let screen = parent?.screen ?? NSScreen.main
        let frame = Self.windowFrame(for: first, on: screen)
        let window = ViewerWindow(
            contentRect: frame,
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        // Just the buttons over the picture; the title still names the window (Window menu, etc.).
        window.titleVisibility = .hidden
        window.backgroundColor = .black
        window.delegate = self
        window.onKey = { [weak self] key in self?.handle(key) ?? false }
        window.onZoom = { [weak self] zoom in
            guard let self, let item = self.items[self.index], Self.isImage(item), let imageView = self.imageView else { return false }
            imageView.zoom(zoom)
            return true
        }

        guard let preview = QLPreviewView(frame: NSRect(origin: .zero, size: frame.size), style: .normal) else { return }
        preview.autoresizingMask = [.width, .height]
        preview.autostarts = true
        preview.shouldCloseWithWindow = false
        let container = HoverView(frame: NSRect(origin: .zero, size: frame.size))
        container.onHover = { [weak self] inside in self?.setTitleBarVisible(inside, animated: true) }
        container.addSubview(preview)
        let image = LiveTextImageView(frame: NSRect(origin: .zero, size: frame.size))
        image.autoresizingMask = [.width, .height]
        image.isHidden = true
        container.addSubview(image)
        window.contentView = container
        window.isDragRegion = { [weak self] point in self?.isDragRegion(point) ?? false }
        self.window = window
        previewView = preview
        imageView = image
        showCurrentItem()
        // The traffic lights and title only show while the pointer is over the window.
        let mouse = window.mouseLocationOutsideOfEventStream
        setTitleBarVisible(container.bounds.contains(container.convert(mouse, from: nil)), animated: false)

        // The window renders (transparent) while the picture flies from the chat to it.
        window.alphaValue = 0
        window.makeKeyAndOrderFront(nil)
        guard let source = source(self.index) else {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = Self.animationDuration
                window.animator().alphaValue = 1
            }
            return
        }
        let target = Self.pictureRect(for: first, in: frame)
        preload(around: index)
        let overlay = Self.overlay(showing: source.image, frame: source.frame)
        overlay.orderFront(nil)
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = Self.animationDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            overlay.animator().setFrame(target, display: true)
        }, completionHandler: {
            window.alphaValue = 1
            // Let the window draw at full opacity before the flying picture goes away.
            DispatchQueue.main.async { overlay.orderOut(nil) }
        })
    }

    /// Swaps an item's file (the full-size picture replacing the low-res preview).
    func replaceItem(at index: Int, with url: URL) {
        guard items.indices.contains(index), var item = items[index] else { return }
        item.url = url
        items[index] = item
        if index == self.index, isVisible {
            if Self.isImage(item) {
                imageView?.show(url)
            } else {
                previewView?.previewItem = url as NSURL
            }
        }
    }

    func close() {
        guard let window, window.isVisible, !isClosing, let item = items[index] else { return }
        isClosing = true
        pendingIndex = nil
        let image = sourceProvider?(index)?.image
        let start = Self.pictureRect(for: item, in: window.frame)
        // Fly the sharpest picture we have.
        let flying = NSImage(contentsOf: item.url) ?? image
        let finish = { [weak self] in
            window.orderOut(nil)
            self?.previewView?.close()
            self?.previewView = nil
            self?.imageView = nil
            self?.window = nil
            self?.isClosing = false
        }
        guard let flying else {
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = Self.animationDuration
                window.animator().alphaValue = 0
            }, completionHandler: finish)
            return
        }
        let overlay = Self.overlay(showing: flying, frame: start)
        overlay.orderFront(nil)
        window.orderOut(nil)
        let destination = sourceProvider?(index)?.frame
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = Self.animationDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            if let destination {
                overlay.animator().setFrame(destination, display: true)
            } else {
                overlay.animator().alphaValue = 0
            }
        }, completionHandler: {
            overlay.orderOut(nil)
            finish()
        })
    }

    // MARK: - Browsing

    private enum Key { case escape, space, left, right }

    private func handle(_ key: Key) -> Bool {
        switch key {
        case .escape, .space:
            close()
        case .left:
            step(by: -1)
        case .right:
            step(by: 1)
        }
        return true
    }

    /// Goes to the previous or next item (counting from the one still loading, so holding an
    /// arrow key keeps going), skipping items that can't be loaded.
    private func step(by delta: Int) {
        let target = (pendingIndex ?? index) + delta
        guard items.indices.contains(target) else {
            pendingIndex = nil
            return
        }
        if items[target] != nil {
            pendingIndex = nil
            show(at: target)
            return
        }
        pendingIndex = target
        Task { @MainActor [weak self] in
            guard let self, let item = await self.loader?(target) else {
                // Unavailable: on to the next one, if still heading there.
                guard let self, self.pendingIndex == target, !self.isClosing else { return }
                self.step(by: delta)
                return
            }
            self.items[target] = item
            guard self.pendingIndex == target, !self.isClosing else { return }
            self.pendingIndex = nil
            self.show(at: target)
        }
    }

    /// Loads the neighbors ahead of time, so ← / → switch right away.
    private func preload(around center: Int) {
        for neighbor in [center - 1, center + 1] where items.indices.contains(neighbor) && items[neighbor] == nil {
            Task { @MainActor [weak self] in
                guard let self, let item = await self.loader?(neighbor), self.items.indices.contains(neighbor),
                      self.items[neighbor] == nil else { return }
                self.items[neighbor] = item
            }
        }
    }

    private func show(at newIndex: Int) {
        guard items.indices.contains(newIndex), newIndex != index, let item = items[newIndex], let window else { return }
        index = newIndex
        showCurrentItem()
        preload(around: newIndex)
        var frame = Self.windowFrame(for: item, on: window.screen)
        // Keep it centered where it is.
        frame.origin = NSPoint(x: window.frame.midX - frame.width / 2, y: window.frame.midY - frame.height / 2)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            window.animator().setFrame(frame, display: true)
        }
    }

    private func showCurrentItem() {
        guard let item = items[index] else { return }
        if Self.isImage(item) {
            imageView?.show(item.url)
            imageView?.isHidden = false
            previewView?.isHidden = true
            previewView?.previewItem = nil
        } else {
            previewView?.previewItem = item.url as NSURL
            previewView?.isHidden = false
            imageView?.isHidden = true
            imageView?.show(nil)
        }
        window?.title = items.count > 1 ? "\(item.title) (\(index + 1) of \(items.count))" : item.title
    }

    /// Whether pressing at `point` (window coordinates) moves the window: anywhere on a picture
    /// below the title bar (the title bar moves it by itself and has the buttons). Videos and
    /// documents keep their clicks for their controls and scrolling.
    private func isDragRegion(_ point: NSPoint) -> Bool {
        // Pictures are no longer draggable by their content: Live Text needs those clicks for
        // selecting text. Move the window by its title bar (shown on hover) instead, like Preview.
        return false
    }

    private func setTitleBarVisible(_ visible: Bool, animated: Bool) {
        // The buttons' superview is the title bar view (buttons and title).
        guard let titleBar = window?.standardWindowButton(.closeButton)?.superview else { return }
        let alpha: CGFloat = visible ? 1 : 0
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                titleBar.animator().alphaValue = alpha
            }
        } else {
            titleBar.alphaValue = alpha
        }
    }

    private static func isVideo(_ item: Item) -> Bool {
        UTType(filenameExtension: item.url.pathExtension)?.conforms(to: .movie) == true
    }

    /// A still picture we render ourselves (so Live Text works) — it has a pixel size and isn't a video.
    private static func isImage(_ item: Item) -> Bool {
        item.pixelSize != nil && !isVideo(item)
    }

    // MARK: - NSWindowDelegate

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        close()
        return false
    }

    // MARK: - Geometry

    /// The window for an item: the picture's size (1 point per pixel), scaled down to fit the
    /// screen, centered on it.
    private static func windowFrame(for item: Item, on screen: NSScreen?) -> NSRect {
        let visible = (screen ?? NSScreen.main)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let available = visible.insetBy(dx: 60, dy: 60).size
        var size = item.pixelSize ?? CGSize(width: 900, height: 700)
        let scale = min(1, available.width / size.width, available.height / size.height)
        size = CGSize(width: max(320, (size.width * scale).rounded()), height: max(240, (size.height * scale).rounded()))
        return NSRect(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2, width: size.width, height: size.height)
    }

    /// Where the picture appears in a window frame (aspect fit), for the flying animation.
    private static func pictureRect(for item: Item, in frame: NSRect) -> NSRect {
        guard let size = item.pixelSize, size.width > 0, size.height > 0 else { return frame }
        let scale = min(frame.width / size.width, frame.height / size.height)
        let width = size.width * scale, height = size.height * scale
        return NSRect(x: frame.midX - width / 2, y: frame.midY - height / 2, width: width, height: height)
    }

    /// A borderless window showing just a picture, flown between the chat and the viewer.
    private static func overlay(showing image: NSImage, frame: NSRect) -> NSWindow {
        let overlay = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        overlay.isReleasedWhenClosed = false
        overlay.isOpaque = false
        overlay.backgroundColor = .clear
        overlay.hasShadow = true
        overlay.ignoresMouseEvents = true
        overlay.level = .floating
        let imageView = DisplayImageView(frame: NSRect(origin: .zero, size: frame.size))
        imageView.image = image
        imageView.imageScaling = .scaleAxesIndependently
        imageView.autoresizingMask = [.width, .height]
        imageView.wantsLayer = true
        // The viewer's background from the start, so transparent pictures don't fly as cutouts
        // (with a shadow following their outline).
        imageView.layer?.backgroundColor = NSColor.black.cgColor
        imageView.layer?.cornerRadius = 12
        imageView.layer?.cornerCurve = .continuous
        imageView.layer?.masksToBounds = true
        overlay.contentView = imageView
        return overlay
    }

    // MARK: - Window

    /// Reports when the pointer enters or leaves the window's content.
    private final class HoverView: NSView {
        var onHover: ((Bool) -> Void)?

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(
                rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil
            ))
        }

        override func mouseEntered(with event: NSEvent) { onHover?(true) }
        override func mouseExited(with event: NSEvent) { onHover?(false) }
    }

    /// Handles the viewer's keys and window dragging before Quick Look's view gets the events
    /// (its content is shown by another process, so views layered on top don't get the clicks).
    private final class ViewerWindow: NSWindow {
        var onKey: ((Key) -> Bool)?
        var onZoom: ((LiveTextImageView.Zoom) -> Bool)?
        var isDragRegion: ((NSPoint) -> Bool)?

        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            if event.type == .keyDown, event.modifierFlags.intersection([.command, .control, .option]) == .command {
                let zoom: LiveTextImageView.Zoom? = switch event.charactersIgnoringModifiers {
                case "=", "+": .zoomIn
                case "-": .zoomOut
                case "0": .actualSize
                default: nil
                }
                if let zoom, onZoom?(zoom) == true { return true }
            }
            return super.performKeyEquivalent(with: event)
        }

        override func sendEvent(_ event: NSEvent) {
            if event.type == .leftMouseDown {
                // The click's own position can be off (it lands on Quick Look's view), which
                // made the window jump, so use the pointer's real position.
                let point = convertPoint(fromScreen: NSEvent.mouseLocation)
                if isDragRegion?(point) == true, let drag = NSEvent.mouseEvent(
                    with: .leftMouseDown, location: point, modifierFlags: event.modifierFlags, timestamp: event.timestamp,
                    windowNumber: windowNumber, context: nil, eventNumber: event.eventNumber, clickCount: event.clickCount,
                    pressure: event.pressure
                ) {
                    performDrag(with: drag)
                    return
                }
            }
            if event.type == .keyDown, event.modifierFlags.intersection([.command, .control, .option]).isEmpty {
                let key: Key? = switch event.keyCode {
                case 53: .escape
                case 49: .space
                case 123: .left
                case 124: .right
                default: nil
                }
                if let key, onKey?(key) == true { return }
            }
            super.sendEvent(event)
        }
    }

    /// Shows a still picture (aspect-fit) with a VisionKit Live Text overlay, so text in the picture
    /// can be selected, copied and looked up — the way Preview and Quick Look's panel do.
    private final class LiveTextImageView: NSView, ImageAnalysisOverlayViewDelegate {
        /// Zooms (pinch, ⌘+ / ⌘- / ⌘0) and pans the picture. Its document is the picture at its
        /// own size; the magnification is the picture's scale on screen. Fitting the window
        /// (following its size) until zoomed in; zoomed in, the scale and the picture's place on
        /// screen stay put while the window is resized.
        private let scrollView = NSScrollView()
        private let content = NSView()
        /// The scale that fits the picture in the window, as of the last layout.
        private var fitScale: CGFloat = 1
        /// Where the visible area was on screen, as of the last layout (to keep the picture in
        /// place when the window is resized from an edge).
        private var lastClipScreenRect: NSRect?
        private let imageView = DisplayImageView()
        private let overlay = ImageAnalysisOverlayView()
        private let analyzer = ImageAnalyzer()
        /// Guards against a slow analysis landing after the picture has already changed.
        private var analysisToken = 0

        private static let maxZoom: CGFloat = 8
        private static let zoomStep: CGFloat = 1.5

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            scrollView.frame = bounds
            scrollView.autoresizingMask = [.width, .height]
            scrollView.drawsBackground = false
            // The picture goes under the (hidden) title bar, as before: no inset for it.
            scrollView.automaticallyAdjustsContentInsets = false
            scrollView.contentInsets = NSEdgeInsetsZero
            scrollView.hasHorizontalScroller = true
            scrollView.hasVerticalScroller = true
            scrollView.autohidesScrollers = true
            scrollView.scrollerStyle = .overlay
            scrollView.allowsMagnification = true
            addSubview(scrollView)

            let clip = CenteringClipView()
            clip.drawsBackground = false
            scrollView.contentView = clip
            content.frame = NSRect(origin: .zero, size: scrollView.contentSize)
            scrollView.documentView = content
            NotificationCenter.default.addObserver(
                self, selector: #selector(magnifyEnded(_:)), name: NSScrollView.didEndLiveMagnifyNotification, object: scrollView
            )

            imageView.imageScaling = .scaleAxesIndependently
            imageView.autoresizingMask = [.width, .height]
            imageView.frame = content.bounds
            content.addSubview(imageView)

            overlay.autoresizingMask = [.width, .height]
            overlay.frame = content.bounds
            overlay.delegate = self
            overlay.preferredInteractionTypes = .automatic
            content.addSubview(overlay)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError() }

        /// Whether the picture fits the window (not zoomed in).
        private var isFitting: Bool { scrollView.magnification <= fitScale * 1.001 }

        /// A new picture: fit it at the next layout.
        private var forceFit = true

        /// The zoomed-in picture's scale and place when a resize started.
        private struct ResizeStart {
            var magnification: CGFloat
            var origin: NSPoint
            var screen: NSRect
        }

        /// Set while the window is being resized by dragging, if the picture was zoomed in: the
        /// whole drag is measured from it, so shrinking the window again within the same drag
        /// brings back the scale and place the picture had before.
        private var liveResizeStart: ResizeStart?

        override func viewWillStartLiveResize() {
            super.viewWillStartLiveResize()
            liveResizeStart = isFitting ? nil : currentResizeStart
        }

        override func viewDidEndLiveResize() {
            super.viewDidEndLiveResize()
            liveResizeStart = nil
        }

        private var currentResizeStart: ResizeStart? {
            lastClipScreenRect.map {
                ResizeStart(magnification: scrollView.magnification, origin: scrollView.contentView.bounds.origin, screen: $0)
            }
        }

        override func layout() {
            let wasFitting = isFitting || forceFit
            forceFit = false
            // A drag measures from where it started; any other resize from the last layout.
            let start = inLiveResize ? liveResizeStart : (wasFitting ? nil : currentResizeStart)
            super.layout()
            let clip = scrollView.contentView
            let screen = window.map { $0.convertToScreen(clip.convert(clip.bounds, to: nil)) }
            defer { lastClipScreenRect = screen }
            let picture = content.frame.size
            let size = scrollView.contentSize
            guard picture.width > 0, picture.height > 0, size.width > 0, size.height > 0 else { return }
            fitScale = min(size.width / picture.width, size.height / picture.height)
            scrollView.minMagnification = fitScale
            scrollView.maxMagnification = fitScale * Self.maxZoom

            func fit() {
                scrollView.magnification = fitScale
                clip.scroll(to: clip.constrainBoundsRect(clip.bounds).origin)
                scrollView.reflectScrolledClipView(clip)
            }
            guard let start, let screen, start.magnification > fitScale * 1.001 else {
                fit()
                return
            }
            // Zoomed in. Once the window is bigger than the zoomed picture along a side where it
            // was cropped, fit the picture to the window instead.
            let shown = NSSize(width: picture.width * start.magnification, height: picture.height * start.magnification)
            let croppedX = start.screen.width < shown.width - 0.5, croppedY = start.screen.height < shown.height - 0.5
            if (croppedX && size.width > shown.width + 0.5) || (croppedY && size.height > shown.height + 0.5) {
                fit()
                return
            }
            // Otherwise the same scale, and the picture stays where it was on screen, so resizing
            // from an edge crops it on that side (until its edge reaches the window's).
            scrollView.magnification = start.magnification
            let origin = NSPoint(
                x: start.origin.x + (screen.minX - start.screen.minX) / start.magnification,
                y: start.origin.y + (screen.minY - start.screen.minY) / start.magnification
            )
            clip.scroll(to: clip.constrainBoundsRect(NSRect(origin: origin, size: clip.bounds.size)).origin)
            scrollView.reflectScrolledClipView(clip)
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            NotificationCenter.default.removeObserver(self, name: NSWindow.didMoveNotification, object: nil)
            if let window {
                NotificationCenter.default.addObserver(
                    self, selector: #selector(windowMoved(_:)), name: NSWindow.didMoveNotification, object: window
                )
            }
        }

        /// The window moved (not resized; `layout` handles that): the picture moved with it.
        @objc private func windowMoved(_ notification: Notification) {
            guard let window, let old = lastClipScreenRect else { return }
            let clip = scrollView.contentView
            let screen = window.convertToScreen(clip.convert(clip.bounds, to: nil))
            if screen.size == old.size { lastClipScreenRect = screen }
        }

        /// A pinch back to (or past) fitting: fit, following the window's size again.
        @objc private func magnifyEnded(_ notification: Notification) {
            guard isFitting else { return }
            scrollView.magnification = fitScale
            let clip = scrollView.contentView
            clip.scroll(to: clip.constrainBoundsRect(clip.bounds).origin)
            scrollView.reflectScrolledClipView(clip)
        }

        /// Keeps the picture's edges at the window's edges (no scrolling past them), and the
        /// picture centered on a side where it's smaller than the window.
        private final class CenteringClipView: NSClipView {
            override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
                var rect = super.constrainBoundsRect(proposedBounds)
                guard let document = documentView?.frame, !document.isEmpty else { return rect }
                func clamp(_ origin: CGFloat, length: CGFloat, extent: CGFloat) -> CGFloat {
                    length >= extent ? -(length - extent) / 2 : min(max(origin, 0), extent - length)
                }
                rect.origin.x = clamp(rect.origin.x, length: rect.width, extent: document.width)
                rect.origin.y = clamp(rect.origin.y, length: rect.height, extent: document.height)
                return rect
            }
        }

        enum Zoom { case zoomIn, zoomOut, actualSize }

        func zoom(_ zoom: Zoom) {
            let current = scrollView.magnification
            let target: CGFloat = switch zoom {
            case .zoomIn: min(fitScale * Self.maxZoom, current * Self.zoomStep)
            case .zoomOut: max(fitScale, current / Self.zoomStep)
            case .actualSize: fitScale
            }
            guard abs(target - current) > 0.0001 else { return }
            let visible = scrollView.contentView.bounds
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                scrollView.animator().setMagnification(target, centeredAt: NSPoint(x: visible.midX, y: visible.midY))
            }
        }

        /// Loads (or, with nil, clears) the picture and re-runs text recognition on it.
        func show(_ url: URL?) {
            analysisToken += 1
            let token = analysisToken
            overlay.analysis = nil
            guard let url, let image = NSImage(contentsOf: url) else {
                imageView.image = nil
                return
            }
            // A new picture (or its full-size version) starts fitting the window.
            imageView.image = image
            content.setFrameSize(image.size)
            forceFit = true
            needsLayout = true
            layoutSubtreeIfNeeded()
            var rect = NSRect(origin: .zero, size: image.size)
            guard let cg = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { return }
            Task { [weak self] in
                guard let analyzer = self?.analyzer else { return }
                let config = ImageAnalyzer.Configuration([.text, .machineReadableCode])
                let analysis = try? await analyzer.analyze(cg, orientation: .up, configuration: config)
                await MainActor.run {
                    guard let self, token == self.analysisToken else { return }
                    self.overlay.analysis = analysis
                }
            }
        }

        /// Where the picture actually sits inside the overlay (aspect-fit letterboxing), in unit
        /// coordinates, so the selection boxes line up with the text.
        func contentsRect(for overlayView: ImageAnalysisOverlayView) -> CGRect {
            let full = CGRect(x: 0, y: 0, width: 1, height: 1)
            guard let size = imageView.image?.size, size.width > 0, size.height > 0 else { return full }
            let bounds = overlayView.bounds.size
            guard bounds.width > 0, bounds.height > 0 else { return full }
            let scale = min(bounds.width / size.width, bounds.height / size.height)
            let w = size.width * scale, h = size.height * scale
            return CGRect(x: (bounds.width - w) / 2 / bounds.width, y: (bounds.height - h) / 2 / bounds.height,
                          width: w / bounds.width, height: h / bounds.height)
        }
    }
}
