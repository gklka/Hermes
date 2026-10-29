import AppKit

extension NSButton {
    /// A sheet's round Liquid Glass ✕ for its top right corner; Esc presses it too.
    static func glassClose(target: AnyObject, action: Selector) -> NSButton {
        let button = NSButton(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close")!, target: target, action: action)
        button.bezelStyle = .glass
        button.borderShape = .circle
        button.controlSize = .large
        button.keyEquivalent = "\u{1b}"
        button.toolTip = "Close"
        // Keep its round intrinsic size: a long title next to it must not squish it into an oval.
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .vertical)
        button.setContentHuggingPriority(.required, for: .horizontal)
        return button
    }
}

extension NSView {
    /// What the view draws in `rect` (its bounds by default), as an image: for drag images and
    /// for animating views that are gone.
    func snapshot(in rect: NSRect? = nil) -> NSImage {
        let rect = rect ?? bounds
        let image = NSImage(size: rect.size)
        if rect.width > 0, rect.height > 0, let rep = bitmapImageRepForCachingDisplay(in: rect) {
            cacheDisplay(in: rect, to: rep)
            image.addRepresentation(rep)
        }
        return image
    }

    /// A new message or typing bubble arriving: zooms up from its center with a little spring,
    /// fading in.
    func animateAppearance() {
        springScale(from: 0.5, damping: 18, key: "appear.zoom")
        layer?.add(CABasicAnimation.fade(from: 0, to: 1, duration: 0.18, timing: .easeOut), forKey: "appear.fade")
    }

    /// Something in the view changed (e.g. a reaction added to a badge): it bounces.
    func animateBounce() {
        springScale(from: 1.3, damping: 10, key: "bounce")
    }

    /// Springs the view from `scale` to its size, around its center.
    private func springScale(from scale: CGFloat, damping: CGFloat, key: String) {
        wantsLayer = true
        guard let layer else { return }
        // Layer-backed views scale around their corner; move the scaling to the center.
        let center = CGPoint(x: layer.bounds.midX, y: layer.bounds.midY)
        var from = CATransform3DMakeTranslation(center.x, center.y, 0)
        from = CATransform3DScale(from, scale, scale, 1)
        from = CATransform3DTranslate(from, -center.x, -center.y, 0)

        let zoom = CASpringAnimation(keyPath: "transform")
        zoom.fromValue = from
        zoom.toValue = CATransform3DIdentity
        zoom.damping = damping
        zoom.stiffness = 300
        zoom.mass = 1
        zoom.duration = zoom.settlingDuration
        layer.add(zoom, forKey: key)
    }

    /// Fades the view in from transparent (e.g. a row's content that just appeared).
    func fadeIn(duration: TimeInterval, timing: CAMediaTimingFunctionName = .linear, key: String) {
        wantsLayer = true
        layer?.add(CABasicAnimation.fade(from: 0, to: 1, duration: duration, timing: timing), forKey: key)
    }
}

extension CABasicAnimation {
    static func fade(from: Float, to: Float, duration: TimeInterval, timing: CAMediaTimingFunctionName = .linear) -> CABasicAnimation {
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = from
        fade.toValue = to
        fade.duration = duration
        fade.timingFunction = CAMediaTimingFunction(name: timing)
        return fade
    }
}

extension NSPopover {
    /// Shows the controller in a popover that closes when you click elsewhere.
    @discardableResult
    static func show(_ controller: NSViewController, from anchor: NSView, rect: NSRect? = nil,
                     edge: NSRectEdge = .maxY) -> NSPopover {
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = controller
        popover.show(relativeTo: rect ?? anchor.bounds, of: anchor, preferredEdge: edge)
        return popover
    }
}

extension NSAlert {
    /// Asks before a destructive action (in a sheet), then runs it, and says so if it fails.
    static func confirm(_ message: String, detail: String, button: String, in window: NSWindow,
                        perform action: @escaping () async throws -> Void) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = detail
        alert.addButton(withTitle: button).hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            Task {
                do {
                    try await action()
                } catch {
                    let failure = NSAlert()
                    failure.messageText = "\(button) failed"
                    failure.informativeText = error.localizedDescription
                    failure.beginSheetModal(for: window, completionHandler: nil)
                }
            }
        }
    }
}

extension NSTableView {
    /// Brings the table from rows with the `old` IDs to rows with the `new` ones (each unique)
    /// with animated moves, insertions and removals. The rows that stay keep their views.
    func animateRowChanges(from old: [String], to new: [String]) {
        var current = old
        let newSet = Set(new)
        beginUpdates()
        // Each change applies to the rows as they are after the ones before.
        for index in current.indices.reversed() where !newSet.contains(current[index]) {
            current.remove(at: index)
            removeRows(at: [index], withAnimation: .effectFade)
        }
        for (index, id) in new.enumerated() {
            if index < current.count, current[index] == id { continue }
            if let from = current[index...].firstIndex(of: id) {
                current.remove(at: from)
                current.insert(id, at: index)
                moveRow(at: from, to: index)
            } else {
                current.insert(id, at: index)
                insertRows(at: [index], withAnimation: .effectFade)
            }
        }
        endUpdates()
    }
}

/// facebook.com addresses the app opens.
enum Facebook {
    static let origin = "https://www.facebook.com"

    /// A page on facebook.com, by its path ("/messages/").
    static func url(_ path: String) -> URL? {
        URL(string: origin + path)
    }

    static func profileURL(of userID: String) -> URL? {
        url("/\(userID)")
    }
}
