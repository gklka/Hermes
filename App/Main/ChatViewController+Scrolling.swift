import AppKit

// MARK: - Scrolling

extension ChatViewController {
    var isScrolledToBottom: Bool {
        scrollView.contentView.bounds.maxY >= tableView.bounds.height - 40
    }

    /// The first message on screen and how far its top is from the top of the visible area.
    struct ScrollAnchor {
        let messageID: String
        let offset: CGFloat
    }

    /// With `changedRow`, the first message below that row (so a row growing at the top of the
    /// screen pushes what's above it up, instead of what's below it down).
    func scrollAnchor(below changedRow: Int? = nil) -> ScrollAnchor? {
        let visible = scrollView.contentView.bounds
        let range = tableView.rows(in: visible)
        let start = max(range.lowerBound, changedRow.map { $0 + 1 } ?? 0)
        guard start < range.upperBound else { return nil }
        for row in start..<range.upperBound where rows.indices.contains(row) {
            if case .message(let message, _) = rows[row] {
                return ScrollAnchor(messageID: message.id, offset: tableView.rect(ofRow: row).minY - visible.minY)
            }
        }
        return nil
    }

    /// Scrolls so the anchor message is back where it was on screen.
    func restore(_ anchor: ScrollAnchor) {
        guard let row = rowIndex(ofMessage: anchor.messageID) else { return }
        let y = tableView.rect(ofRow: row).minY - anchor.offset
        guard abs(y - scrollView.contentView.bounds.minY) > 0.5 else { return }
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: y))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    /// At once; changes at the bottom look smooth because the rows glide (slideMovedRows). Set
    /// exactly (not scrollRowToVisible): when the chat got shorter, the clip view would only
    /// catch up a moment later, a jump in the middle of the animations.
    func scrollToBottom() {
        guard !rows.isEmpty else { return }
        let clip = scrollView.contentView
        // The last row just above the compose bar, which overlaps the bottom (content inset).
        let insets = scrollView.contentInsets
        let bottom = tableView.bounds.height + insets.bottom - clip.bounds.height
        clip.setBoundsOrigin(NSPoint(x: clip.bounds.origin.x, y: max(-insets.top, bottom)))
        scrollView.reflectScrolledClipView(clip)
    }

    /// Gradient themes span the visible chat, so visible bubbles are realigned as it scrolls.
    func alignGradients() {
        guard let threadID, (store.conversation(threadID)?.bubbleColors?.count ?? 0) > 1 else { return }
        for (_, cell) in visibleCells(MessageCellView.self) {
            cell.alignGradient(to: scrollView.contentView)
        }
    }

    /// Near the top, older messages are loaded (from the store, or Messenger's history).
    @objc func scrolled() {
        alignGradients()
        guard let threadID, !isLoadingOlder, searchResults == nil, scrollView.contentView.bounds.minY < 200, !rows.isEmpty else { return }
        isLoadingOlder = true
        Task {
            let started = await store.loadOlderMessages(threadID)
            // Give server backfill a moment before asking again.
            try? await Task.sleep(for: .seconds(started ? 1 : 3))
            isLoadingOlder = false
        }
    }

    // MARK: - Revealing a message

    /// Scrolls to the message and selects it, loading older pages until it shows up.
    /// `stored`: the message is known to be in the database (a search result), so earlier pages
    /// are loaded until it shows up, even if the chat had seemed to have no more history (the
    /// search may have fetched more since).
    func reveal(messageID: String, stored: Bool = false) {
        pendingReveal = messageID
        revealPagesLoaded = 0
        revealPageLimit = stored ? 1000 : 40
        if stored, let threadID {
            store.resetHistoryEnd(threadID)
        }
        revealPendingMessage()
    }

    func revealPendingMessage() {
        guard let id = pendingReveal else { return }
        guard let row = rowIndex(ofMessage: id) else {
            // An older message (e.g. from Spotlight): load earlier pages until it shows up.
            guard let threadID, !store.messages(in: threadID).isEmpty, revealPagesLoaded < revealPageLimit else { return }
            revealPagesLoaded += 1
            Task { await store.loadOlderMessages(threadID) }
            return
        }
        pendingReveal = nil
        // In the middle of the view, with the messages around it.
        let rect = tableView.rect(ofRow: row)
        let visible = scrollView.contentView.bounds
        let y = min(max(0, rect.midY - visible.height / 2), max(0, tableView.bounds.height - visible.height))
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: y))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        selectMessage(id)
    }

    // MARK: - Scroll keys

    enum ScrollKey {
        case pageUp, pageDown, home, end

        /// The key pressed without modifiers, if it's one of these.
        init?(_ event: NSEvent) {
            guard event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty,
                  let character = event.charactersIgnoringModifiers?.unicodeScalars.first else { return nil }
            switch Int(character.value) {
            case NSPageUpFunctionKey: self = .pageUp
            case NSPageDownFunctionKey: self = .pageDown
            case NSHomeFunctionKey: self = .home
            case NSEndFunctionKey: self = .end
            default: return nil
            }
        }
    }

    /// Page Up/Down, Home and End scroll the messages wherever the focus is (also in the
    /// message field). Returns whether the key was one of them.
    func handleScrollKey(_ event: NSEvent) -> Bool {
        guard let key = ScrollKey(event), threadID != nil else { return false }
        scroll(key)
        return true
    }

    func scroll(_ key: ScrollKey) {
        guard threadID != nil, !rows.isEmpty else { return }
        let clip = scrollView.contentView
        let insets = clip.contentInsets
        let page = max(clip.bounds.height - insets.top - insets.bottom - 40, 40)
        var origin = clip.bounds.origin
        switch key {
        case .pageUp: origin.y -= page
        case .pageDown: origin.y += page
        case .home: origin.y = -insets.top
        case .end: origin.y = tableView.frame.height - clip.bounds.height + insets.bottom
        }
        let target = clip.constrainBoundsRect(NSRect(origin: origin, size: clip.bounds.size)).origin
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            clip.animator().setBoundsOrigin(target)
        }
        scrollView.reflectScrolledClipView(clip)
        // Overlay scrollers only appear by themselves for trackpad and mouse scrolling.
        scrollView.flashScrollers()
    }
}
