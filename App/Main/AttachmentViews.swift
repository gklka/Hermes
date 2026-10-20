import AppKit
import AVFoundation
import MapKit
import UniformTypeIdentifiers

/// Dragging a link out of a message: other apps get the URL, Finder makes a .webloc named after
/// the title.
enum LinkDrag {
    /// How far (in points) the mouse moves before a click becomes a drag.
    static let threshold: CGFloat = 4

    static func item(url: URL, title: String?, frame: NSRect, image: NSImage) -> NSDraggingItem {
        let pasteboardItem = NSPasteboardItem()
        pasteboardItem.setString(url.absoluteString, forType: .URL)
        pasteboardItem.setString(url.absoluteString, forType: .string)
        if let title, !title.isEmpty {
            pasteboardItem.setString(title, forType: NSPasteboard.PasteboardType("public.url-name"))
        }
        let item = NSDraggingItem(pasteboardWriter: pasteboardItem)
        item.setDraggingFrame(frame, contents: image)
        return item
    }

    /// Whether the mouse went far enough from where it was pressed to start a drag.
    static func isDrag(from start: NSPoint, to event: NSEvent) -> Bool {
        hypot(event.locationInWindow.x - start.x, event.locationInWindow.y - start.y) > threshold
    }
}

/// A link's preview: its picture, title and site, like Messages' link previews. Clicking opens
/// the link; dragging takes it out.
final class LinkCardView: NSView, NSDraggingSource {
    private var url: URL?
    private var title: String?
    private var mouseDownPoint: NSPoint?
    private let picture = NSView()
    private let titleLabel = NSTextField(wrappingLabelWithString: "")
    private let subtitleLabel = NSTextField(wrappingLabelWithString: "")
    private let siteLabel = NSTextField(labelWithString: "")
    private var widthConstraint = NSLayoutConstraint()
    private var pictureHeight = NSLayoutConstraint()

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 16
        layer?.masksToBounds = true

        picture.wantsLayer = true
        picture.layer?.contentsGravity = .resizeAspectFill
        picture.layer?.masksToBounds = true

        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.maximumNumberOfLines = 3
        // Word-wrap across up to the line cap, then "…" on the last line (like the web), instead of
        // truncating on a single line.
        titleLabel.lineBreakMode = .byWordWrapping
        titleLabel.cell?.truncatesLastVisibleLine = true
        subtitleLabel.font = .systemFont(ofSize: 12)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.maximumNumberOfLines = 2
        subtitleLabel.lineBreakMode = .byWordWrapping
        subtitleLabel.cell?.truncatesLastVisibleLine = true
        siteLabel.font = .systemFont(ofSize: 11)
        siteLabel.textColor = .secondaryLabelColor
        siteLabel.lineBreakMode = .byTruncatingTail

        for view in [picture, titleLabel, subtitleLabel, siteLabel] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        widthConstraint = widthAnchor.constraint(equalToConstant: 300)
        pictureHeight = picture.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            widthConstraint, pictureHeight,
            titleLabel.topAnchor.constraint(equalTo: picture.bottomAnchor, constant: 8),
            picture.topAnchor.constraint(equalTo: topAnchor),
            picture.leadingAnchor.constraint(equalTo: leadingAnchor),
            picture.trailingAnchor.constraint(equalTo: trailingAnchor),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),
            subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            subtitleLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            siteLabel.topAnchor.constraint(equalTo: subtitleLabel.bottomAnchor, constant: 2),
            siteLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            siteLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            siteLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -9),
        ])

        addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(clicked)))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Runs of whitespace (including newlines) collapsed to single spaces, trimmed.
    private static func oneBlock(_ text: String) -> String {
        text.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
    }

    func configure(_ preview: LinkPreviews.Preview, width: CGFloat) {
        url = preview.url
        title = preview.title
        widthConstraint.constant = width
        titleLabel.preferredMaxLayoutWidth = width - 24
        subtitleLabel.preferredMaxLayoutWidth = width - 24
        // A shared post stuffs its whole body (with newlines) into the title; collapse it to one
        // block so the line cap truncates it cleanly instead of showing every line.
        titleLabel.stringValue = Self.oneBlock(preview.title)
        let subtitle = preview.subtitle.map(Self.oneBlock) ?? ""
        subtitleLabel.stringValue = subtitle
        subtitleLabel.isHidden = subtitle.isEmpty
        siteLabel.stringValue = preview.site ?? ""
        siteLabel.isHidden = preview.site == nil
        picture.layer?.contents = preview.image
        // Tall pictures are cropped, as on the web.
        if let size = preview.imageSize ?? preview.image?.size, size.width > 0, size.height > 0 {
            pictureHeight.constant = (width * min(size.height / size.width, 1.4)).rounded()
        } else {
            pictureHeight.constant = 0
        }
    }

    override func updateLayer() {
        layer?.backgroundColor = BubbleColors.incoming.cgColor
    }

    override var wantsUpdateLayer: Bool { true }

    @objc private func clicked() {
        if let url { NSWorkspace.shared.open(url) }
    }

    // MARK: - Dragging out

    /// Mouse events come here, not to the labels.
    override func hitTest(_ point: NSPoint) -> NSView? {
        super.hitTest(point) == nil ? nil : self
    }

    override func mouseDown(with event: NSEvent) {
        // Not passed on, so the table doesn't track the drag; clicks go to the click recognizer.
        mouseDownPoint = event.locationInWindow
    }

    override func mouseDragged(with event: NSEvent) {
        guard let url, let start = mouseDownPoint, LinkDrag.isDrag(from: start, to: event) else {
            super.mouseDragged(with: event)
            return
        }
        mouseDownPoint = nil
        let item = LinkDrag.item(url: url, title: title, frame: bounds, image: snapshot())
        beginDraggingSession(with: [item], event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }
}

/// A shared location: a map snapshot with a pin, the place's name and address below. Clicking
/// opens it in Maps. The map picture is rendered off the main thread, then faded in.
final class LocationCardView: NSView {
    private let location: Attachment.Location
    private let mapImage = NSImageView()
    private let titleLabel = NSTextField(wrappingLabelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private var snapshotter: MKMapSnapshotter?

    init(location: Attachment.Location, maxWidth: CGFloat) {
        self.location = location
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 16
        layer?.masksToBounds = true

        let width = min(300, maxWidth)
        let mapHeight: CGFloat = 150
        mapImage.wantsLayer = true
        mapImage.imageScaling = .scaleProportionallyUpOrDown
        mapImage.layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor

        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.maximumNumberOfLines = 2
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.stringValue = title
        subtitleLabel.font = .systemFont(ofSize: 11)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.lineBreakMode = .byTruncatingTail
        let subtitle = location.address.flatMap { $0.isEmpty ? nil : $0 } ?? coordinateText
        subtitleLabel.stringValue = subtitle

        for view in [mapImage, titleLabel, subtitleLabel] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: width),
            mapImage.topAnchor.constraint(equalTo: topAnchor),
            mapImage.leadingAnchor.constraint(equalTo: leadingAnchor),
            mapImage.trailingAnchor.constraint(equalTo: trailingAnchor),
            mapImage.heightAnchor.constraint(equalToConstant: mapHeight),
            titleLabel.topAnchor.constraint(equalTo: mapImage.bottomAnchor, constant: 8),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),
            subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            subtitleLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            subtitleLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -9),
        ])

        addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(openInMaps)))
        renderMap(width: width, height: mapHeight)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func updateLayer() { layer?.backgroundColor = BubbleColors.incoming.cgColor }
    override var wantsUpdateLayer: Bool { true }

    private var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: location.latitude, longitude: location.longitude)
    }

    private var title: String {
        if let name = location.name, !name.isEmpty { return name }
        return (location.live ?? false) ? "Live Location" : "Shared Location"
    }

    private var coordinateText: String {
        String(format: "%.5f, %.5f", location.latitude, location.longitude)
    }

    private func renderMap(width: CGFloat, height: CGFloat) {
        let options = MKMapSnapshotter.Options()
        options.region = MKCoordinateRegion(center: coordinate, latitudinalMeters: 800, longitudinalMeters: 800)
        options.size = CGSize(width: width, height: height)
        let snapshotter = MKMapSnapshotter(options: options)
        self.snapshotter = snapshotter
        snapshotter.start(with: .main) { [weak self] snapshot, _ in
            guard let self, let snapshot else { return }
            self.mapImage.image = Self.pinned(snapshot, at: self.coordinate)
        }
    }

    /// The snapshot with a pin drawn at the coordinate.
    private static func pinned(_ snapshot: MKMapSnapshotter.Snapshot, at coordinate: CLLocationCoordinate2D) -> NSImage {
        let image = snapshot.image
        guard let pin = NSImage(systemSymbolName: "mappin.circle.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 30, weight: .bold)
                .applying(.init(paletteColors: [.white, .systemRed]))) else { return image }
        let composed = NSImage(size: image.size)
        composed.lockFocus()
        image.draw(at: .zero, from: .zero, operation: .copy, fraction: 1)
        let point = snapshot.point(for: coordinate)
        let size = pin.size
        // The snapshot's points are top-left origin; AppKit drawing is bottom-left.
        pin.draw(at: NSPoint(x: point.x - size.width / 2, y: image.size.height - point.y - size.height / 2),
                 from: .zero, operation: .sourceOver, fraction: 1)
        composed.unlockFocus()
        return composed
    }

    @objc private func openInMaps() {
        let item = MKMapItem(placemark: MKPlacemark(coordinate: coordinate))
        item.name = location.name.flatMap { $0.isEmpty ? nil : $0 } ?? "Shared Location"
        item.openInMaps(launchOptions: nil)
    }
}

/// Image / video / file / link attachment. Can be dragged out to Finder or other apps.
final class AttachmentView: NSView, NSDraggingSource {
    var onOpen: (() -> Void)?
    private var mouseDownPoint: NSPoint?

    private let attachment: Attachment
    private let message: ChatMessage
    private let imageView = DisplayImageView()
    private lazy var gifView = LoopingVideoView()

    private static let cornerRadius: CGFloat = 16

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
                title: attachment.filename ?? attachment.kind.label,
                subtitle: nil,
                maxWidth: maxWidth
            )
        case .link:
            setUpPill(
                symbol: "link",
                title: attachment.title ?? attachment.url ?? attachment.kind.label,
                subtitle: attachment.url.flatMap { URL(string: $0)?.host() },
                maxWidth: maxWidth
            )
        case .call:
            // Shown by CallCardView; this is a fallback.
            setUpPill(symbol: "phone", title: attachment.title ?? attachment.kind.label, subtitle: nil, maxWidth: maxWidth)
        case .poll:
            // Shown by PollBubblesView; this is a fallback.
            setUpPill(symbol: "chart.bar.xaxis", title: attachment.title ?? attachment.kind.label, subtitle: nil, maxWidth: maxWidth)
        case .location:
            // Shown by LocationCardView; this is a fallback.
            setUpPill(symbol: "mappin.circle.fill", title: attachment.location?.name ?? attachment.kind.label, subtitle: nil, maxWidth: maxWidth)
        }

        addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(clicked)))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    @objc private func clicked() {
        onOpen?()
    }

    var attachmentID: String { attachment.id }

    /// The picture shown in the chat (images, GIFs, stickers, video previews); Quick Look zooms from it.
    var displayedImage: NSImage? { imageView.superview == nil ? nil : imageView.image }

    // MARK: - Dragging out

    /// Receive mouse events here rather than in the image view, which would track the drag itself.
    override func hitTest(_ point: NSPoint) -> NSView? {
        super.hitTest(point) == nil ? nil : self
    }

    override func mouseDown(with event: NSEvent) {
        // Don't pass it on: the table view would run its own tracking loop and eat the drag.
        // Clicks still work through the click gesture recognizer.
        mouseDownPoint = event.locationInWindow
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = mouseDownPoint, LinkDrag.isDrag(from: start, to: event) else {
            super.mouseDragged(with: event)
            return
        }
        mouseDownPoint = nil
        let item: NSDraggingItem
        if attachment.kind == .link {
            guard let url = attachment.url.flatMap(URL.init(string:)) else { return }
            item = LinkDrag.item(url: url, title: attachment.title, frame: bounds, image: dragImage())
        } else {
            item = NSDraggingItem(pasteboardWriter: AttachmentFilePromise(attachment: attachment, message: message))
            item.setDraggingFrame(bounds, contents: dragImage())
        }
        beginDraggingSession(with: [item], event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }

    /// The picture with its rounded corners, or what the view shows.
    private func dragImage() -> NSImage {
        guard let picture = displayedImage else { return snapshot() }
        return NSImage(size: bounds.size, flipped: false) { rect in
            NSBezierPath(roundedRect: rect, xRadius: Self.cornerRadius, yRadius: Self.cornerRadius).addClip()
            picture.draw(in: rect)
            return true
        }
    }

    // MARK: - Content

    /// Photos, GIFs, stickers and videos: the picture, fitted into the bubble's width (stickers
    /// are smaller), with a play button on videos.
    private func setUpVisual(maxWidth: CGFloat) {
        let maxHeight: CGFloat = 320
        var size = CGSize(width: attachment.width ?? 0, height: attachment.height ?? 0)
        if size.width <= 0 || size.height <= 0 {
            size = CGSize(width: 220, height: 220)
        }
        let box = attachment.kind == .sticker ? CGSize(width: 140, height: 140) : CGSize(width: maxWidth, height: maxHeight)
        let scale = min(1, box.width / size.width, box.height / size.height)
        size = CGSize(width: max(60, size.width * scale), height: max(60, size.height * scale))

        // Messenger and WhatsApp deliver "GIFs" as looping, silent MP4s, which NSImageView can't
        // show — they play in a video layer instead.
        let content: NSView
        if attachment.kind == .gif {
            content = gifView
        } else {
            imageView.imageScaling = .scaleProportionallyUpOrDown
            imageView.animates = true
            imageView.wantsLayer = true
            content = imageView
        }
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)

        if attachment.kind != .sticker {
            layer?.cornerRadius = Self.cornerRadius
            layer?.cornerCurve = .continuous
            layer?.masksToBounds = true
            layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor
            imageView.imageScaling = .scaleAxesIndependently
        }
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: size.width),
            heightAnchor.constraint(equalToConstant: size.height),
            content.leadingAnchor.constraint(equalTo: leadingAnchor),
            content.trailingAnchor.constraint(equalTo: trailingAnchor),
            content.topAnchor.constraint(equalTo: topAnchor),
            content.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        if attachment.kind == .gif {
            Task { [weak self] in
                guard let self, let url = try? await ChatStore.shared.localFile(for: self.attachment, in: self.message) else { return }
                self.gifView.load(url)
            }
            return
        }

        if attachment.kind == .video {
            addPlayButton()
            // Facebook gives video thumbnails; encrypted videos have none.
            if let preview = attachment.previewURL, let url = URL(string: preview) {
                if let cached = ImageCache.shared.cached(url) {
                    imageView.image = cached
                    return
                }
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

    private func addPlayButton() {
        let play = DisplayImageView(image: NSImage(systemSymbolName: "play.circle.fill", accessibilityDescription: "Play") ?? NSImage())
        play.symbolConfiguration = .init(pointSize: 40, weight: .regular)
        play.contentTintColor = .white
        play.translatesAutoresizingMaskIntoConstraints = false
        addSubview(play)
        NSLayoutConstraint.activate([
            play.centerXAnchor.constraint(equalTo: centerXAnchor),
            play.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    /// Files, voice messages and links: an icon and a title in a gray pill.
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

/// Drags an attachment out as a file. It's a promise, so attachments that aren't downloaded
/// (or decrypted) yet are fetched when dropped.
final class AttachmentFilePromise: NSFilePromiseProvider, NSFilePromiseProviderDelegate {
    private let attachment: Attachment
    private let message: ChatMessage

    init(attachment: Attachment, message: ChatMessage) {
        self.attachment = attachment
        self.message = message
        super.init()
        fileType = Self.type(of: attachment).identifier
        delegate = self
    }

    private static func type(of attachment: Attachment) -> UTType {
        if let mime = attachment.mimeType, let type = UTType(mimeType: mime) {
            return type
        }
        if let ext = attachment.filename.map({ ($0 as NSString).pathExtension }), !ext.isEmpty,
           let type = UTType(filenameExtension: ext) {
            return type
        }
        switch attachment.kind {
        case .image, .sticker: return .jpeg
        case .gif: return .gif
        case .video: return .mpeg4Movie
        case .audio: return .mpeg4Audio
        case .file, .link, .call, .poll, .location: return .data
        }
    }

    /// The attachment's own name, or e.g. "Photo 2026-10-14 at 09.41.00.jpg".
    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
        let ext = UTType(fileType)?.preferredFilenameExtension
        if let name = attachment.filename, !name.isEmpty {
            guard (name as NSString).pathExtension.isEmpty, let ext else { return name }
            return "\(name).\(ext)"
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let name = "\(attachment.kind.label) \(formatter.string(from: message.date))"
        return ext.map { "\(name).\($0)" } ?? name
    }

    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, writePromiseTo url: URL,
                             completionHandler: @escaping (Error?) -> Void) {
        Task {
            do {
                let source = try await ChatStore.shared.localFile(for: attachment, in: message)
                try FileManager.default.copyItem(at: source, to: url)
                completionHandler(nil)
            } catch {
                CoreBridge.shared.log("Dragging out \(attachment.id) failed: \(error)")
                completionHandler(error)
            }
        }
    }
}
