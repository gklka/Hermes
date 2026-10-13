import AppKit
import QuickLookUI
import UniformTypeIdentifiers

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

    private var items: [Item] = []
    private var index = 0
    private var sourceProvider: SourceProvider?
    private var window: ViewerWindow?
    private var previewView: QLPreviewView?
    private var isClosing = false

    private static let animationDuration: TimeInterval = 0.28

    var isVisible: Bool { window?.isVisible == true }

    func show(_ items: [Item], at index: Int, over parent: NSWindow?, source: @escaping SourceProvider) {
        guard !items.isEmpty else { return }
        // Replace whatever was showing.
        window?.orderOut(nil)
        previewView?.close()

        self.items = items
        self.index = min(max(0, index), items.count - 1)
        sourceProvider = source
        isClosing = false

        let screen = parent?.screen ?? NSScreen.main
        let frame = Self.windowFrame(for: items[self.index], on: screen)
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

        guard let preview = QLPreviewView(frame: NSRect(origin: .zero, size: frame.size), style: .normal) else { return }
        preview.autoresizingMask = [.width, .height]
        preview.autostarts = true
        preview.shouldCloseWithWindow = false
        let container = HoverView(frame: NSRect(origin: .zero, size: frame.size))
        container.onHover = { [weak self] inside in self?.setTitleBarVisible(inside, animated: true) }
        container.addSubview(preview)
        window.contentView = container
        window.isDragRegion = { [weak self] point in self?.isDragRegion(point) ?? false }
        self.window = window
        previewView = preview
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
        let target = Self.pictureRect(for: items[self.index], in: frame)
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
        guard items.indices.contains(index) else { return }
        items[index].url = url
        if index == self.index, isVisible {
            previewView?.previewItem = url as NSURL
        }
    }

    func close() {
        guard let window, window.isVisible, !isClosing else { return }
        isClosing = true
        let item = items[index]
        let image = sourceProvider?(index)?.image
        let start = Self.pictureRect(for: item, in: window.frame)
        // Fly the sharpest picture we have.
        let flying = NSImage(contentsOf: item.url) ?? image
        let finish = { [weak self] in
            window.orderOut(nil)
            self?.previewView?.close()
            self?.previewView = nil
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
            go(to: index - 1)
        case .right:
            go(to: index + 1)
        }
        return true
    }

    private func go(to newIndex: Int) {
        guard items.indices.contains(newIndex), newIndex != index, let window else { return }
        index = newIndex
        showCurrentItem()
        var frame = Self.windowFrame(for: items[index], on: window.screen)
        // Keep it centered where it is.
        frame.origin = NSPoint(x: window.frame.midX - frame.width / 2, y: window.frame.midY - frame.height / 2)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            window.animator().setFrame(frame, display: true)
        }
    }

    private func showCurrentItem() {
        let item = items[index]
        previewView?.previewItem = item.url as NSURL
        window?.title = items.count > 1 ? "\(item.title) (\(index + 1) of \(items.count))" : item.title
    }

    /// Whether pressing at `point` (window coordinates) moves the window: anywhere on a picture
    /// below the title bar (the title bar moves it by itself and has the buttons). Videos and
    /// documents keep their clicks for their controls and scrolling.
    private func isDragRegion(_ point: NSPoint) -> Bool {
        guard let window, items.indices.contains(index) else { return false }
        let item = items[index]
        guard item.pixelSize != nil, !Self.isVideo(item) else { return false }
        let titleBarHeight = window.frame.height - window.contentLayoutRect.height
        return point.y < window.frame.height - max(titleBarHeight, 28)
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
        var isDragRegion: ((NSPoint) -> Bool)?

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
}
