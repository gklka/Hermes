import AppKit

/// How a call in a chat is described.
enum CallText {
    /// "Audio Call", "Missed Video Call" (a call you missed; one they didn't answer says so below).
    static func title(of call: Attachment.Call, outgoing: Bool) -> String {
        let kind = call.isVideo ? "Video Call" : "Audio Call"
        return call.outcome == .missed && !outgoing ? "Missed \(kind)" : kind
    }

    /// The call's length, "No Answer", or nothing while it's going on.
    static func detail(of call: Attachment.Call, outgoing: Bool) -> String? {
        switch call.outcome {
        case .started: return nil
        case .missed: return outgoing ? "No Answer" : nil
        case .ended:
            if let text = call.durationText, !text.isEmpty { return text }
            guard let seconds = call.duration, seconds > 0 else { return nil }
            return durationFormatter.string(from: TimeInterval(seconds))
        }
    }

    private static let durationFormatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute, .second]
        formatter.unitsStyle = .short
        formatter.maximumUnitCount = 2
        return formatter
    }()
}

/// A call in the chat, like Messenger's: an arrow for its direction (red if you missed it), what
/// kind of call it was and how long, and Call Back.
final class CallCardView: NSView {
    private let message: ChatMessage
    private let call: Attachment.Call

    init(call: Attachment.Call, message: ChatMessage) {
        self.call = call
        self.message = message
        super.init(frame: .zero)
        let outgoing = message.isFromMe
        let missed = call.outcome == .missed && !outgoing

        let background = BubbleView()
        background.color = BubbleColors.incoming

        let symbol = switch (call.isVideo, outgoing) {
        case (false, true): "phone.arrow.up.right.fill"
        case (false, false): "phone.arrow.down.left.fill"
        case (true, true): "arrow.up.right.video.fill"
        case (true, false): "arrow.down.left.video.fill"
        }
        let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage())
        icon.symbolConfiguration = .init(pointSize: 15, weight: .medium)
        icon.contentTintColor = missed ? .white : .labelColor
        let circle = NSView()
        circle.wantsLayer = true
        circle.layer?.cornerRadius = 18
        circle.layer?.backgroundColor = (missed ? NSColor.systemRed : NSColor.quaternaryLabelColor).cgColor
        icon.translatesAutoresizingMaskIntoConstraints = false
        circle.addSubview(icon)

        let titleLabel = NSTextField(labelWithString: CallText.title(of: call, outgoing: outgoing))
        titleLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        let detail = CallText.detail(of: call, outgoing: outgoing)
        let detailLabel = NSTextField(labelWithString: detail ?? "")
        detailLabel.font = .systemFont(ofSize: 12)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.isHidden = detail == nil
        let texts = NSStackView(views: [titleLabel, detailLabel])
        texts.orientation = .vertical
        texts.alignment = .leading
        texts.spacing = 1

        let button = CallBackButton(title: "Call Back", target: self, action: #selector(callBack))

        for view in [background, circle, texts, button] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            background.leadingAnchor.constraint(equalTo: leadingAnchor),
            background.trailingAnchor.constraint(equalTo: trailingAnchor),
            background.topAnchor.constraint(equalTo: topAnchor),
            background.bottomAnchor.constraint(equalTo: bottomAnchor),
            widthAnchor.constraint(equalToConstant: 220),
            circle.widthAnchor.constraint(equalToConstant: 36),
            circle.heightAnchor.constraint(equalToConstant: 36),
            circle.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            circle.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            icon.centerXAnchor.constraint(equalTo: circle.centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: circle.centerYAnchor),
            texts.leadingAnchor.constraint(equalTo: circle.trailingAnchor, constant: 10),
            texts.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),
            texts.centerYAnchor.constraint(equalTo: circle.centerYAnchor),
            button.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            button.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            button.topAnchor.constraint(equalTo: circle.bottomAnchor, constant: 10),
            button.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
            button.heightAnchor.constraint(equalToConstant: 30),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel([CallText.title(of: call, outgoing: outgoing), detail].compactMap { $0 }.joined(separator: ", "))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    @objc private func callBack() {
        CallManager.shared.startCall(threadID: message.threadID, video: call.isVideo)
    }
}

/// A flat rounded button on the card, like Messenger's.
private final class CallBackButton: NSButton {
    convenience init(title: String, target: AnyObject, action: Selector) {
        self.init(frame: .zero)
        self.title = title
        self.target = target
        self.action = action
        isBordered = false
        font = .systemFont(ofSize: 13, weight: .semibold)
        wantsLayer = true
        layer?.cornerRadius = 9
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        let color = isHighlighted ? NSColor.tertiaryLabelColor : NSColor.quaternaryLabelColor
        effectiveAppearance.performAsCurrentDrawingAppearance {
            self.layer?.backgroundColor = color.cgColor
        }
    }
}
