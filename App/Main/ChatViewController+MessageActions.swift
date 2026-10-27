import AppKit
import QuickLookUI

// What you can do with a message: its menu, tapbacks, selecting it, its sender's menu, and
// opening its attachments in Quick Look.

extension ChatViewController: MessageCellDelegate {
    private var selfID: String? { store.account?.id }

    private func myReaction(to message: ChatMessage) -> String? {
        message.reactions.first { $0.senderID == selfID }?.emoji
    }

    // MARK: - The message's menu

    func messageCell(_ cell: MessageCellView, menuFor message: ChatMessage) -> NSMenu? {
        // Right-clicking a message outside a multi-selection collapses to just that one.
        if selectedMessageIDs.count > 1, !selectedMessageIDs.contains(message.id) {
            selectMessage(message.id)
        }
        let selected = selectedMessages()
        if selected.count > 1, selectedMessageIDs.contains(message.id) {
            return multiMessageMenu(for: selected)
        }
        return singleMessageMenu(for: message, cell: cell)
    }

    private func singleMessageMenu(for message: ChatMessage, cell: MessageCellView) -> NSMenu? {
        guard !message.isUnsent, message.status != .pending else { return nil }
        let menu = NSMenu()
        func add(_ title: String, _ action: Selector) {
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
            item.target = self
            item.representedObject = message
        }

        // Tapback rows, like Messages.
        let reactions = NSMenuItem()
        reactions.view = ReactionMenuView(
            current: myReaction(to: message),
            onPick: { [weak self] emoji in self?.toggleReaction(emoji, on: message) },
            onMore: { [weak self, weak cell] in
                guard let self, let cell else { return }
                self.showEmojiInput(for: message, anchor: cell.anchorView)
            }
        )
        menu.addItem(reactions)
        menu.addItem(.separator())

        add("Reply", #selector(replyFromMenu(_:)))
        add(message.isPinned == true ? "Unpin Message" : "Pin Message", #selector(togglePinFromMenu(_:)))
        if !message.text.isEmpty {
            add("Copy", #selector(copyFromMenu(_:)))
        }
        let pictures = message.attachments.filter { Self.isPicture($0) }
        if !pictures.isEmpty {
            add(pictures.count == 1 ? "Copy Image" : "Copy Images", #selector(copyImagesFromMenu(_:)))
        }
        if message.attachments.contains(where: { $0.kind != .link }) {
            add("Save to Downloads", #selector(saveToDownloadsFromMenu(_:)))
        }
        if message.isFromMe {
            if !message.text.isEmpty, message.status != .failed {
                add("Edit", #selector(editFromMenu(_:)))
            }
            menu.addItem(.separator())
            add("Unsend", #selector(unsendFromMenu(_:)))
        }
        return menu
    }

    /// The menu shared by several selected messages: the actions that make sense for a group.
    private func multiMessageMenu(for messages: [ChatMessage]) -> NSMenu {
        let menu = NSMenu()
        func add(_ title: String, _ action: Selector) {
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
            item.target = self
            item.representedObject = messages
        }
        if messages.contains(where: { !$0.text.isEmpty }) {
            add("Copy", #selector(copySelectedFromMenu(_:)))
        }
        let pictures = messages.flatMap { $0.attachments.filter { Self.isPicture($0) } }
        if !pictures.isEmpty {
            add(pictures.count == 1 ? "Copy Image" : "Copy Images", #selector(copyImagesSelectedFromMenu(_:)))
        }
        if messages.contains(where: { message in message.attachments.contains { $0.kind != .link } }) {
            add("Save to Downloads", #selector(saveSelectedToDownloadsFromMenu(_:)))
        }
        let anyUnpinned = messages.contains { $0.isPinned != true }
        add(anyUnpinned ? "Pin Messages" : "Unpin Messages", #selector(togglePinSelectedFromMenu(_:)))
        if messages.allSatisfy(\.isFromMe) {
            menu.addItem(.separator())
            add("Unsend", #selector(unsendSelectedFromMenu(_:)))
        }
        return menu
    }

    @objc private func copySelectedFromMenu(_ sender: NSMenuItem) {
        guard let messages = sender.representedObject as? [ChatMessage] else { return }
        let text = messages.map(\.text).filter { !$0.isEmpty }.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @objc private func copyImagesSelectedFromMenu(_ sender: NSMenuItem) {
        guard let messages = sender.representedObject as? [ChatMessage] else { return }
        copyImages(of: messages)
    }

    @objc private func saveSelectedToDownloadsFromMenu(_ sender: NSMenuItem) {
        guard let messages = sender.representedObject as? [ChatMessage] else { return }
        saveToDownloads(messages)
    }

    @objc private func togglePinSelectedFromMenu(_ sender: NSMenuItem) {
        guard let messages = sender.representedObject as? [ChatMessage] else { return }
        // Pin them all if any is unpinned; otherwise unpin them all.
        let pin = messages.contains { $0.isPinned != true }
        for message in messages { store.setPinned(message, pinned: pin) }
        selectMessage(nil)
    }

    @objc private func unsendSelectedFromMenu(_ sender: NSMenuItem) {
        guard let messages = sender.representedObject as? [ChatMessage] else { return }
        for message in messages where message.isFromMe { store.unsend(message) }
        selectMessage(nil)
    }

    @objc private func replyFromMenu(_ sender: NSMenuItem) {
        guard let message = sender.representedObject as? ChatMessage else { return }
        startReply(to: message)
    }

    @objc private func copyFromMenu(_ sender: NSMenuItem) {
        guard let message = sender.representedObject as? ChatMessage else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(message.text, forType: .string)
    }

    @objc private func togglePinFromMenu(_ sender: NSMenuItem) {
        guard let message = sender.representedObject as? ChatMessage else { return }
        store.setPinned(message, pinned: message.isPinned != true)
    }

    private static func isPicture(_ attachment: Attachment) -> Bool {
        [.image, .gif, .sticker].contains(attachment.kind)
    }

    /// Copies the message's pictures (full size, downloaded if needed).
    @objc private func copyImagesFromMenu(_ sender: NSMenuItem) {
        guard let message = sender.representedObject as? ChatMessage else { return }
        copyImages(of: [message])
    }

    private func copyImages(of messages: [ChatMessage]) {
        Task {
            do {
                var images: [NSImage] = []
                for message in messages {
                    for attachment in message.attachments where Self.isPicture(attachment) {
                        let url = try await store.localFile(for: attachment, in: message)
                        if let image = NSImage(contentsOf: url) { images.append(image) }
                    }
                }
                guard !images.isEmpty else { return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.writeObjects(images)
            } catch {
                _ = presentError(error)
            }
        }
    }

    /// Saves the message's files (pictures, videos, files) to the Downloads folder, under new
    /// names if taken, and bounces the Downloads stack like a browser download.
    @objc private func saveToDownloadsFromMenu(_ sender: NSMenuItem) {
        guard let message = sender.representedObject as? ChatMessage else { return }
        saveToDownloads([message])
    }

    private func saveToDownloads(_ messages: [ChatMessage]) {
        guard let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first else { return }
        Task {
            do {
                for message in messages {
                    for attachment in message.attachments where attachment.kind != .link {
                        let file = try await store.localFile(for: attachment, in: message)
                        let destination = Self.freeURL(in: downloads, for: Self.downloadName(of: attachment, in: message, file: file))
                        try FileManager.default.copyItem(at: file, to: destination)
                        DistributedNotificationCenter.default().post(name: .init("com.apple.DownloadFileFinished"), object: destination.path)
                    }
                }
            } catch {
                _ = presentError(error)
            }
        }
    }

    /// The attachment's own file name, or "Photo 2026-10-16 at 0.08.12.jpg".
    private static func downloadName(of attachment: Attachment, in message: ChatMessage, file: URL) -> String {
        if let filename = attachment.filename, !filename.isEmpty { return filename }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' H.mm.ss"
        let name = "\(attachment.kind.label) \(formatter.string(from: message.date))"
        return file.pathExtension.isEmpty ? name : "\(name).\(file.pathExtension)"
    }

    /// `name` in the folder, or "name 2.ext", "name 3.ext"… if it's taken.
    private static func freeURL(in folder: URL, for name: String) -> URL {
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var url = folder.appendingPathComponent(name)
        var number = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent(ext.isEmpty ? "\(base) \(number)" : "\(base) \(number).\(ext)")
            number += 1
        }
        return url
    }

    @objc private func editFromMenu(_ sender: NSMenuItem) {
        guard let message = sender.representedObject as? ChatMessage else { return }
        startEditing(message)
    }

    @objc private func unsendFromMenu(_ sender: NSMenuItem) {
        guard let message = sender.representedObject as? ChatMessage else { return }
        store.unsend(message)
    }

    // MARK: - Reactions

    private static let reactionChoices = ReactionChoices.standard

    /// Double-clicking a message offers the tapbacks.
    func messageCellDidDoubleClick(_ cell: MessageCellView, message: ChatMessage, bubble: NSView) {
        let picker = TapbackPicker(choices: Self.reactionChoices, current: myReaction(to: message))
        // Anchor to the table view, not the bubble: a chat update (typing indicator, a new
        // message) reloads the table and recreates cells, and AppKit dismisses a popover whose
        // anchor view has left the window. The table view stays put, so the popover survives.
        let rect = tableView.convert(bubble.bounds, from: bubble)
        let popover = NSPopover.show(picker, from: tableView, rect: rect)
        picker.onPick = { [weak self, weak popover] emoji in
            popover?.close()
            self?.toggleReaction(emoji, on: message)
        }
    }

    /// Picking your current reaction again removes it.
    private func toggleReaction(_ emoji: String, on message: ChatMessage) {
        store.react(to: message, with: myReaction(to: message) == emoji ? "" : emoji)
    }

    /// Lets you react with any emoji (the "more" button in the context menu's tapback rows).
    private func showEmojiInput(for message: ChatMessage, anchor: NSView) {
        let input = EmojiInputViewController()
        let popover = NSPopover.show(input, from: anchor)
        input.onPick = { [weak self, weak popover] emoji in
            popover?.close()
            self?.toggleReaction(emoji, on: message)
        }
    }

    /// The tapback badge shows who reacted with what.
    func messageCell(_ cell: MessageCellView, showReactionsOf message: ChatMessage, anchor: NSView) {
        let people = message.reactions.map { reaction -> ReactionsViewController.Entry in
            let participant = store.participant(reaction.senderID, in: message.threadID)
            if reaction.senderID == selfID, let account = store.account {
                // The account itself often has no picture; your contact entry does.
                return .init(emoji: reaction.emoji, name: "You", avatarURL: participant?.avatarURL ?? account.avatarURL)
            }
            return .init(emoji: reaction.emoji, name: participant?.name ?? "Unknown", avatarURL: participant?.avatarURL)
        }
        guard !people.isEmpty else { return }
        NSPopover.show(ReactionsViewController(entries: people), from: anchor)
    }

    // MARK: - The message's row

    func messageCellDidLoadLinkPreview(messageID: String) {
        guard let row = rowIndex(ofMessage: messageID) else {
            // Measured in another chat (heights are kept across chats).
            rowHeights = rowHeights.filter { row, _ in
                if case .message(let message, _) = row { return message.id != messageID }
                return true
            }
            return
        }
        let oldHeight = rowHeights.removeValue(forKey: rows[row])
        guard tableView(tableView, heightOfRow: row) != oldHeight else { return }
        let wasAtBottom = isScrolledToBottom
        // Rows below the screen don't move what's shown.
        let anchor = wasAtBottom ? nil : scrollAnchor(below: row)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            tableView.noteHeightOfRows(withIndexesChanged: IndexSet(integer: row))
        }
        tableView.layoutSubtreeIfNeeded()
        if let anchor {
            restore(anchor)
        } else if wasAtBottom {
            scrollToBottom()
        }
    }

    func messageCellDidToggleEdits(_ message: ChatMessage) {
        if expandedEdits.remove(message.id) == nil {
            expandedEdits.insert(message.id)
        }
        reload()
    }

    func messageCellDidClickFailure(_ message: ChatMessage) {
        guard let window = view.window else { return }
        let alert = NSAlert()
        alert.messageText = "Your message was not delivered."
        alert.informativeText = "You can try sending it again or delete it."
        alert.addButton(withTitle: "Try Again")
        alert.addButton(withTitle: "Delete").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            switch response {
            case .alertFirstButtonReturn:
                self?.store.resend(message)
            case .alertSecondButtonReturn:
                self?.store.discard(message)
            default:
                break
            }
        }
    }

    // MARK: - Selecting a message

    func messageCellDidClick(_ cell: MessageCellView, message: ChatMessage, modifiers: NSEvent.ModifierFlags) {
        guard searchResults == nil else {
            // A found message: back to the chat, at that message.
            endSearch()
            reveal(messageID: message.id, stored: true)
            return
        }
        if modifiers.contains(.shift), let anchor = selectionAnchor, anchor != message.id {
            // Extend the selection to a range, like a list (the anchor stays put).
            setSelection(Set(messageIDs(from: anchor, to: message.id)), anchor: anchor)
        } else if modifiers.contains(.command) {
            // Toggle this one in or out of the selection.
            var ids = selectedMessageIDs
            if ids.contains(message.id) { ids.remove(message.id) } else { ids.insert(message.id) }
            setSelection(ids, anchor: message.id)
        } else {
            selectMessage(message.id)
        }
    }

    /// The loaded messages' IDs in the range between two of them (inclusive), in chat order.
    private func messageIDs(from: String, to: String) -> [String] {
        let order: [String] = rows.compactMap {
            if case .message(let message, _) = $0 { return message.id }
            return nil
        }
        guard let a = order.firstIndex(of: from), let b = order.firstIndex(of: to) else { return [to] }
        return Array(order[min(a, b)...max(a, b)])
    }

    /// The selected messages, in chat order (for the actions a multi-selection offers).
    func selectedMessages() -> [ChatMessage] {
        guard let threadID else { return [] }
        return store.messages(in: threadID).filter { selectedMessageIDs.contains($0.id) }
    }

    func messageCell(_ cell: MessageCellView, revealReplyTarget messageID: String) {
        if searchResults != nil { endSearch() }
        // The quoted message is older history in the database; load back to it if needed.
        reveal(messageID: messageID, stored: true)
    }

    /// Selects exactly this message (or clears the selection with nil). `dismissable` false keeps
    /// the highlight until it's cleared in code (clicks don't drop it), used to mark the message
    /// being edited.
    func selectMessage(_ id: String?, dismissable: Bool = true) {
        setSelection(id.map { [$0] } ?? [], anchor: id, dismissable: dismissable)
    }

    /// Sets the selected messages, highlights their on-screen cells, and (for a dismissable
    /// selection) watches for a click elsewhere to clear it.
    func setSelection(_ ids: Set<String>, anchor: String?, dismissable: Bool = true) {
        if ids != selectedMessageIDs {
            selectedMessageIDs = ids
            for (_, cell) in visibleCells(MessageCellView.self) {
                let selected = cell.message.map { ids.contains($0.id) } ?? false
                cell.isMessageSelected = selected
                cell.setTextSelectable(selected && ids.count == 1)
            }
        }
        selectionAnchor = anchor
        if let deselectMonitor {
            NSEvent.removeMonitor(deselectMonitor)
            self.deselectMonitor = nil
        }
        if !ids.isEmpty, dismissable {
            deselectMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
                self?.deselectUnlessInSelection(event)
                return event
            }
        }
    }

    /// A click on any message's bubble is left to the cell (it selects, extends or toggles);
    /// a click anywhere else clears the selection.
    private func deselectUnlessInSelection(_ event: NSEvent) {
        guard !selectedMessageIDs.isEmpty else { return }
        if event.window === view.window {
            for (_, cell) in visibleCells(MessageCellView.self) where cell.hitsMessageContent(event.locationInWindow) {
                return
            }
        }
        selectMessage(nil)
    }

    // MARK: - The sender's menu

    private struct Sender {
        let id: String
        let name: String
        /// The message whose avatar was clicked (its cell anchors the contact card).
        let messageID: String
    }

    func messageCell(_ cell: MessageCellView, menuForSenderOf message: ChatMessage) -> NSMenu? {
        guard !message.isFromMe else { return nil }
        let sender = Sender(id: message.senderID, name: store.participant(message.senderID, in: message.threadID)?.name ?? "Unknown",
                            messageID: message.id)
        let menu = NSMenu()
        @discardableResult
        func add(_ title: String, symbol: String, action: Selector) -> NSMenuItem {
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
            item.target = self
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            item.representedObject = sender
            return item
        }
        add("Message", symbol: "message", action: #selector(messageSender(_:)))
        add("View Profile", symbol: "person.crop.circle", action: #selector(viewSenderProfile(_:)))
        // Enabled when the person is among the contacts (or before access was asked for).
        let contacts = ContactCards.shared
        let card = add("Show Contact Card", symbol: "person.text.rectangle", action: #selector(showSenderContactCard(_:)))
        if !contacts.canAsk, contacts.match(userID: sender.id, name: sender.name) == nil {
            card.action = nil
        }
        menu.addItem(.separator())
        add("Block…", symbol: "person.crop.circle.badge.xmark", action: #selector(blockSender(_:)))
        return menu
    }

    /// Opens your 1:1 chat with them, in the main window.
    @objc private func messageSender(_ sender: NSMenuItem) {
        guard let person = sender.representedObject as? Sender else { return }
        Task {
            do {
                let conversation = try await store.openDirectChat(with: person.id)
                (NSApp.delegate as? AppDelegate)?.openChat(conversation.id)
            } catch {
                _ = presentError(error)
            }
        }
    }

    @objc private func viewSenderProfile(_ sender: NSMenuItem) {
        guard let person = sender.representedObject as? Sender, let url = Facebook.profileURL(of: person.id) else { return }
        NSWorkspace.shared.open(url)
    }

    /// Their card from the Contacts app, next to the clicked avatar.
    @objc private func showSenderContactCard(_ sender: NSMenuItem) {
        guard let person = sender.representedObject as? Sender else { return }
        Task {
            guard let identifier = await ContactCards.shared.findMatch(userID: person.id, name: person.name) else {
                NSSound.beep()
                return
            }
            let cell = visibleCells(MessageCellView.self).first { $0.cell.message?.id == person.messageID }?.cell
            guard let anchor = cell?.avatarView ?? cell else { return }
            ContactCards.shared.showCard(identifier, relativeTo: anchor.bounds, of: anchor)
        }
    }

    @objc private func blockSender(_ sender: NSMenuItem) {
        guard let person = sender.representedObject as? Sender, let window = view.window else { return }
        NSAlert.confirm("Block \(person.name)?", detail: "They won't be able to message or call you on Messenger.",
                        button: "Block", in: window) { [store] in
            try await store.block(userID: person.id)
        }
    }

    // MARK: - Quick Look

    func messageCell(_ cell: MessageCellView, open attachment: Attachment, of message: ChatMessage) {
        if attachment.kind == .link {
            if let string = attachment.url, let url = URL(string: string) {
                NSWorkspace.shared.open(url)
            }
            return
        }
        // Pictures and videos use the in-chat viewer (zoom from the bubble); anything else (files,
        // docs, audio, PDFs…) opens in the system Quick Look panel.
        if [.image, .gif, .sticker, .video].contains(attachment.kind) {
            Task { await showQuickLook(of: message, startingAt: attachment, from: cell) }
        } else {
            Task { await showFileQuickLook(attachment, of: message) }
        }
    }

    /// Downloads the file (if needed) and shows it in the system Quick Look panel.
    private func showFileQuickLook(_ attachment: Attachment, of message: ChatMessage) async {
        do {
            let url = try await store.localFile(for: attachment, in: message)
            quickLookFiles = [url]
            guard let panel = QLPreviewPanel.shared() else { return }
            view.window?.makeFirstResponder(view)
            if panel.isVisible {
                panel.reloadData()
            } else {
                panel.makeKeyAndOrderFront(nil)
            }
        } catch {
            _ = presentError(error)
        }
    }

    /// Quick Look with all of the message's attachments, starting at the clicked one. Pictures
    /// not downloaded yet show the low-res version from the chat until the full one arrives.
    private func showQuickLook(of message: ChatMessage, startingAt clicked: Attachment, from cell: MessageCellView) async {
        var items: [MediaViewer.Item] = []
        var ids: [String] = []
        var stillDownloading: [Attachment] = []
        var startIndex = 0
        for attachment in message.attachments where attachment.kind != .link {
            do {
                let (item, isPreview) = try await quickLookItem(for: attachment, of: message, in: cell)
                if attachment.id == clicked.id { startIndex = items.count }
                items.append(item)
                ids.append(attachment.id)
                if isPreview { stillDownloading.append(attachment) }
            } catch {
                if attachment.id == clicked.id {
                    _ = presentError(error)
                    return
                }
                CoreBridge.shared.log("Quick Look: attachment \(attachment.id) unavailable: \(error)")
            }
        }
        previewCell = cell
        previewMessageID = message.id
        previewAttachmentIDs = ids
        let session = UUID()
        previewSession = session
        MediaViewer.shared.show(items, at: startIndex, over: view.window) { [weak self] index in
            self?.zoomSource(forItemAt: index)
        }

        for attachment in stillDownloading {
            do {
                let url = try await store.localFile(for: attachment, in: message)
                if session == previewSession, let index = previewAttachmentIDs.firstIndex(of: attachment.id) {
                    MediaViewer.shared.replaceItem(at: index, with: url)
                }
            } catch {
                CoreBridge.shared.log("Quick Look: full-size \(attachment.id) unavailable, keeping the preview: \(error)")
            }
        }
    }

    /// What Quick Look shows for the attachment: its downloaded file; for a picture not
    /// downloaded yet, the chat's picture at the full picture's size (`isPreview`: replaced once
    /// it's downloaded); otherwise the file, downloaded now.
    private func quickLookItem(for attachment: Attachment, of message: ChatMessage, in cell: MessageCellView) async throws -> (item: MediaViewer.Item, isPreview: Bool) {
        let isPicture = [.image, .gif, .sticker].contains(attachment.kind)
        let title = attachment.filename.flatMap { $0.isEmpty ? nil : $0 } ?? attachment.kind.label
        func fileItem(_ url: URL) -> MediaViewer.Item {
            MediaViewer.Item(url: url, title: title, pixelSize: isPicture ? ImageSize.ofFile(url) : Self.videoSize(of: attachment))
        }
        if let downloaded = store.downloadedFile(for: attachment, in: message) {
            return (fileItem(downloaded), false)
        }
        if isPicture, let image = cell.attachmentView(for: attachment.id)?.displayedImage?.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            let size = await finalPixelSize(of: attachment, in: message, thumbnail: image)
            if let preview = await ImageSize.writeQuickLookPreview(image, finalSize: size, attachmentID: attachment.id) {
                return (MediaViewer.Item(url: preview, title: title, pixelSize: size), true)
            }
        }
        return (fileItem(try await store.localFile(for: attachment, in: message)), false)
    }

    /// A video's window size: its reported shape (the preview's), at least 960 points on the long side.
    private static func videoSize(of attachment: Attachment) -> CGSize? {
        guard attachment.kind == .video, let width = attachment.width, let height = attachment.height,
              width > 0, height > 0 else { return nil }
        let scale = max(1, 960 / CGFloat(max(width, height)))
        return CGSize(width: CGFloat(width) * scale, height: CGFloat(height) * scale)
    }

    /// The full-size picture's pixel size, so the preview opens Quick Look at its final size.
    /// Encrypted chats report it; regular chats only report the preview's size, so it's read from
    /// the full image's header, or else guessed from the thumbnail's shape.
    private func finalPixelSize(of attachment: Attachment, in message: ChatMessage, thumbnail: CGImage) async -> CGSize {
        let reported = CGSize(width: attachment.width ?? 0, height: attachment.height ?? 0)
        let hasReported = reported.width > 0 && reported.height > 0
        let encrypted = store.conversation(message.threadID)?.isEncrypted ?? false
        if encrypted && hasReported {
            return reported
        }
        if !encrypted, let string = attachment.url, let url = URL(string: string), url.scheme?.hasPrefix("http") == true,
           let probed = await ImageSize.probe(url) {
            return probed
        }
        // Guess: the thumbnail's shape at Messenger's usual full size (2048 px on the long side).
        let shape = hasReported ? reported : CGSize(width: thumbnail.width, height: thumbnail.height)
        let longSide = max(2048, max(reported.width, reported.height))
        let scale = longSide / max(shape.width, shape.height)
        return CGSize(width: (shape.width * scale).rounded(), height: (shape.height * scale).rounded())
    }

    /// Where Quick Look item `index`'s picture is in the chat (on screen), while it's visible.
    private func zoomSource(forItemAt index: Int) -> (frame: NSRect, image: NSImage)? {
        guard previewAttachmentIDs.indices.contains(index),
              let cell = previewCell, cell.message?.id == previewMessageID,
              let view = cell.attachmentView(for: previewAttachmentIDs[index]), let window = view.window,
              let image = view.displayedImage else { return nil }
        // Only while it's visible in the message list (cells are reused once scrolled away).
        let rect = view.convert(view.bounds, to: scrollView.contentView)
        guard scrollView.contentView.bounds.intersects(rect) else { return nil }
        return (window.convertToScreen(view.convert(view.bounds, to: nil)), image)
    }
}

// MARK: - System Quick Look (non-media attachments)

extension ChatViewController: QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool {
        !quickLookFiles.isEmpty
    }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = self
        panel.delegate = self
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {}

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        quickLookFiles.count
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        quickLookFiles[index] as NSURL
    }
}
