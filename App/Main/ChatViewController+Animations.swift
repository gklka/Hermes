import AppKit

// How the chat animates what changed in a reload (see `reload`): new messages zoom in, rows
// that moved glide to their new place, the status under your last message crossfades, read
// pictures fly to the message they're under now, and the typing bubble turns into the message
// that arrives.

extension ChatViewController {
    // MARK: - Row identity

    static let typingKey = "typing"

    /// What identifies a message or the typing bubble across reloads. A message keeps its key
    /// when the server confirms it (its local echo's ID), so a sent message animates once.
    static func rowKey(_ row: Row) -> String? {
        switch row {
        case .message(let message, _): message.pendingID ?? message.id
        case .typing: typingKey
        default: nil
        }
    }

    static func isIncoming(_ row: Row, in keys: Set<String>) -> Bool {
        guard case .message(let message, _) = row, !message.isFromMe, !message.isSystem,
              let key = rowKey(row) else { return false }
        return keys.contains(key)
    }

    // MARK: - Arriving

    /// The rows newly added at the end: a few at most (a burst is a load or sync, not arrivals),
    /// in the chat that was already showing, outside search.
    static func appended(_ rows: [Row], after shown: Set<String>, sameChat: Bool) -> Set<String> {
        guard sameChat, !shown.isEmpty else { return [] }
        var keys: Set<String> = []
        for row in rows.reversed() {
            // Captions ("Sent") and read pictures change with every receipt; they don't zoom in.
            guard let key = rowKey(row) else { continue }
            // The typing bubble stays last (it lingers), so a message arriving lands above it.
            if case .typing = row {
                if !shown.contains(key) { keys.insert(key) }
                continue
            }
            if shown.contains(key) { break }
            keys.insert(key)
            if keys.count > 3 { return [] }
        }
        return keys
    }

    /// A row that's new in this reload zooms in once its cell is on screen.
    func animateIfArriving(_ rowView: NSTableRowView, at row: Int) {
        guard !appearing.isEmpty, row < rows.count, let key = Self.rowKey(rows[row]),
              appearing.remove(key) != nil,
              let cell = rowView.view(atColumn: 0) as? MessageCellView else { return }
        // Once laid out, so it starts from the bubble's real geometry.
        DispatchQueue.main.async { cell.animateArrival() }
    }

    // MARK: - Status under your last message

    /// The status rows by index, keyed by status and message ("Sent" under a newer message is a
    /// new status).
    static func statusKeys(in rows: [Row]) -> [Int: String] {
        var keys: [Int: String] = [:]
        var messageID = ""
        for (index, row) in rows.enumerated() {
            switch row {
            case .message(let message, _): messageID = message.pendingID ?? message.id
            // Trailing captions are only the status under your last message.
            case .caption(let text, .trailing): keys[index] = "status:\(text):\(messageID)"
            case .notDelivered: keys[index] = "status:notDelivered:\(messageID)"
            default: break
            }
        }
        return keys
    }

    /// The statuses on screen, with a picture of each (to fade out once their row is gone), in
    /// the overlay's coordinates (which don't scroll).
    func statusSnapshots() -> [String: (frame: CGRect, image: NSImage)] {
        let keys = Self.statusKeys(in: rows)
        var snapshots: [String: (frame: CGRect, image: NSImage)] = [:]
        for (row, cell) in visibleCells(NSView.self) where cell.bounds.width > 0 {
            guard let key = keys[row] else { continue }
            snapshots[key] = (cell.convert(cell.bounds, to: animationOverlay), cell.snapshot())
        }
        return snapshots
    }

    /// New statuses fade in; ones that went fade out where they were (so "Sending…" → "Sent"
    /// crossfades).
    func fadeStatuses(appeared: Set<String>, gone: [String: (frame: CGRect, image: NSImage)]) {
        let duration: TimeInterval = 0.35
        let keys = Self.statusKeys(in: rows)
        for (row, cell) in visibleCells(NSView.self) {
            guard let key = keys[row], appeared.contains(key) else { continue }
            cell.fadeIn(duration: duration, timing: .easeOut, key: "status.fade")
        }
        for (_, snapshot) in gone {
            let ghost = NSImageView(frame: snapshot.frame)
            ghost.image = snapshot.image
            ghost.imageScaling = .scaleNone
            animationOverlay.addSubview(ghost)
            NSAnimationContext.runAnimationGroup { context in
                context.duration = duration
                context.timingFunction = CAMediaTimingFunction(name: .easeIn)
                ghost.animator().alphaValue = 0
            } completionHandler: {
                ghost.removeFromSuperview()
            }
        }
    }

    // MARK: - Moving rows

    /// What identifies a row across reloads, for sliding it: messages and the typing bubble by
    /// their key, statuses by status and message, date separators by their text. (Read pictures
    /// fly on their own.)
    private static func slideKeys(in rows: [Row]) -> [Int: String] {
        var keys = statusKeys(in: rows)
        for (index, row) in rows.enumerated() {
            if let key = rowKey(row) {
                keys[index] = key
            } else if case .separator(let text) = row {
                keys[index] = "separator:\(text)"
            }
        }
        return keys
    }

    /// Where the visible rows are on screen (their top in the clip view), by slide key.
    func rowPositionsOnScreen() -> [String: CGFloat] {
        var positions: [String: CGFloat] = [:]
        let keys = Self.slideKeys(in: rows)
        let top = scrollView.contentView.bounds.minY
        for row in visibleRowIndices {
            if let key = keys[row] {
                positions[key] = tableView.rect(ofRow: row).minY - top
            }
        }
        return positions
    }

    /// After a reload (and the jump to the new bottom), each visible row that's somewhere else on
    /// screen glides there from where it was, so rows added or removed (a message, the typing
    /// bubble, "Sent", a read picture) move the others smoothly instead of making them jump.
    func slideMovedRows(from before: [String: CGFloat]) {
        guard !before.isEmpty else { return }
        let keys = Self.slideKeys(in: rows)
        let top = scrollView.contentView.bounds.minY
        for row in visibleRowIndices {
            guard let key = keys[row], !appearing.contains(key), let old = before[key],
                  let rowView = tableView.rowView(atRow: row, makeIfNecessary: false) else { continue }
            let frame = rowView.frame
            let offset = old - (frame.minY - top)
            guard abs(offset) > 0.5 else { continue }
            rowView.wantsLayer = true
            // A layer-backed view's layer position is its frame's origin.
            let slide = CABasicAnimation(keyPath: "position")
            slide.fromValue = NSValue(point: NSPoint(x: frame.minX, y: frame.minY + offset))
            slide.toValue = NSValue(point: frame.origin)
            slide.duration = 0.3
            slide.timingFunction = CAMediaTimingFunction(name: .easeOut)
            rowView.layer?.add(slide, forKey: "row.slide")
        }
    }

    // MARK: - Read pictures

    static func readerPositions(in rows: [Row]) -> [String: String] {
        var positions: [String: String] = [:]
        var messageID: String?
        for row in rows {
            switch row {
            case .message(let message, _): messageID = message.id
            case .readers(let readers): for reader in readers { positions[reader.id] = messageID }
            default: break
            }
        }
        return positions
    }

    /// The read pictures on screen, by person ID, in the overlay's coordinates (which don't
    /// scroll, so they're still right after the jump to the new bottom).
    func readerFramesOnScreen() -> [String: CGRect] {
        var frames: [String: CGRect] = [:]
        for (_, cell) in visibleCells(ReadersCellView.self) {
            for (reader, view) in cell.avatars {
                frames[reader.id] = view.convert(view.bounds, to: animationOverlay)
            }
        }
        return frames
    }

    /// A person read further: their picture slides from the message it was under to the new
    /// one (a copy flies over the chat while the real one waits), or fades in if the old place
    /// wasn't on screen.
    func slideReaders(_ moved: Set<String>, from before: [String: CGRect]) {
        for (_, cell) in visibleCells(ReadersCellView.self) {
            for (reader, view) in cell.avatars where moved.contains(reader.id) {
                guard let start = before[reader.id] else {
                    view.fadeIn(duration: 0.25, key: "readers.fade")
                    continue
                }
                let end = view.convert(view.bounds, to: animationOverlay)
                guard start != end else { continue }
                let flying = AvatarView(frame: start)
                flying.configure(name: reader.name, url: reader.avatarURL)
                animationOverlay.addSubview(flying)
                // The real one shows up as the copy lands, also if reloads rebuild its row meanwhile.
                let flight = UUID()
                flyingReaders[reader.id] = flight
                view.alphaValue = 0
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.4
                    context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                    flying.animator().frame = end
                } completionHandler: { [weak self] in
                    flying.removeFromSuperview()
                    self?.landed(reader.id, flight: flight)
                }
            }
        }
    }

    private func landed(_ readerID: String, flight: UUID) {
        guard flyingReaders[readerID] == flight else { return }
        flyingReaders[readerID] = nil
        for (_, cell) in visibleCells(ReadersCellView.self) {
            for (reader, view) in cell.avatars where reader.id == readerID {
                view.alphaValue = 1
            }
        }
    }

    // MARK: - Typing bubble

    private static let typingLinger: TimeInterval = 2
    private static let typingTransition: TimeInterval = 0.35

    var isTypingLingering: Bool {
        typingLingerUntil.map { $0 > Date() } ?? false
    }

    /// Typing started or stopped in the open chat.
    func typingChanged() {
        guard let threadID else { return }
        if !(store.typing[threadID]?.isEmpty ?? true) {
            endTypingLinger()
        } else if shownKeys.contains(Self.typingKey), typingLingerUntil == nil {
            typingLingerUntil = Date().addingTimeInterval(Self.typingLinger)
            typingLingerTimer = Timer.scheduledTimer(withTimeInterval: Self.typingLinger, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.endTypingLinger()
                    self?.reload()
                }
            }
        }
    }

    func endTypingLinger() {
        typingLingerTimer?.invalidate()
        typingLingerTimer = nil
        typingLingerUntil = nil
    }

    /// The typing bubble's cell, if it's on screen.
    func typingCellOnScreen() -> MessageCellView? {
        guard let row = rows.firstIndex(where: { if case .typing = $0 { return true }; return false }) else { return nil }
        let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? MessageCellView
        return cell?.isTyping == true ? cell : nil
    }

    /// The message takes the typing bubble's row, in the same cell: the row gets the message's
    /// height and the cell animates from typing to the message (see `transitionFromTyping`).
    func finishTypingTransition(at index: Int, into row: Row) {
        guard index < rows.count, case .message(let message, let layout) = row,
              let cell = tableView.view(atColumn: 0, row: index, makeIfNecessary: false) as? MessageCellView,
              let typing = cell.typingBubble else {
            // Not on screen after all: just show it.
            rows[index] = row
            tableView.reloadData(forRowIndexes: IndexSet(integer: index), columnIndexes: IndexSet(integer: 0))
            tableView.noteHeightOfRows(withIndexesChanged: IndexSet(integer: index))
            return
        }
        rows[index] = row
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            tableView.noteHeightOfRows(withIndexesChanged: IndexSet(integer: index))
        }
        tableView.layoutSubtreeIfNeeded()
        cell.delegate = self
        cell.transitionFromTyping(typing, to: message, layout: layout, store: store, duration: Self.typingTransition)
        if let key = Self.rowKey(row) {
            appearing.remove(key)
            transitioning = (key, cell, Date().addingTimeInterval(Self.typingTransition + 0.1))
        }
    }

    /// The cell still animating from typing into this row's message, if it's this row.
    func transitioningCell(for row: Row) -> MessageCellView? {
        guard let transitioning, Date() < transitioning.until else {
            self.transitioning = nil
            return nil
        }
        return Self.rowKey(row) == transitioning.key ? transitioning.cell : nil
    }
}
