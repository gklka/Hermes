import AppKit

// The compose bar: sending, replying, editing a sent message, and telling the chat you're typing.

extension ChatViewController: ComposeViewDelegate {
    func composeView(_ view: ComposeView, send text: String, attachments: [URL]) {
        guard let threadID else { return }
        store.clearMarkedUnread(threadID)
        if let message = editTarget {
            finishEditing()
            guard !text.isEmpty, text != message.text else { return }
            saveEdit(of: message, text: text)
            return
        }
        store.send(text: text, attachments: attachments, in: threadID, replyTo: replyTarget?.id)
        replyTarget = nil
        compose.hideReply()
        stopTyping()
        drafts[threadID] = nil
    }

    func composeViewTextDidChange(_ view: ComposeView) {
        guard let threadID else { return }
        if view.text.isEmpty {
            stopTyping()
            return
        }
        if !isTypingSent {
            isTypingSent = true
            store.setTyping(true, in: threadID)
        }
        // Typing stops being shown a few seconds after the last keystroke.
        typingStopTimer?.invalidate()
        typingStopTimer = Timer.scheduledTimer(withTimeInterval: 4, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.stopTyping() }
        }
    }

    func composeViewCancelReply(_ view: ComposeView) {
        if editTarget != nil {
            finishEditing()
            return
        }
        replyTarget = nil
        compose.hideReply()
    }

    func stopTyping() {
        typingStopTimer?.invalidate()
        typingStopTimer = nil
        guard isTypingSent, let threadID else { return }
        isTypingSent = false
        store.setTyping(false, in: threadID)
    }

    /// ⌘L: sends the chat's quick reaction (like the compose button does when it's empty).
    func sendLike() {
        compose.sendQuickReaction()
    }

    /// File → Attach Files…: stages the chosen files in the compose field.
    func attachFiles() {
        guard threadID != nil, let window = view.window else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK else { return }
            self?.compose.addFiles(panel.urls)
        }
    }

    /// The message's quote shows above the compose field; the next message replies to it.
    func startReply(to message: ChatMessage) {
        replyTarget = message
        let name = store.participantName(message.senderID, in: message.threadID)
        compose.showReply(to: name, text: message.text.isEmpty ? "Attachment" : message.text)
    }

    // MARK: - Editing

    /// ⌘E: edits the selected message if it's yours, otherwise the last one you sent.
    func editMessage() {
        guard let threadID else { return }
        let mine = store.messages(in: threadID).filter {
            $0.isFromMe && !$0.isUnsent && !$0.isSystem && $0.status != .pending && $0.status != .failed && !$0.text.isEmpty
        }
        guard let message = mine.first(where: { $0.id == selectedMessageID }) ?? mine.last else {
            NSSound.beep()
            return
        }
        startEditing(message)
    }

    /// The message's text goes into the compose field; sending saves the edit.
    func startEditing(_ message: ChatMessage) {
        if editTarget == nil {
            draftBeforeEditing = compose.draft
        }
        editTarget = message
        replyTarget = nil
        selectMessage(nil)
        compose.showEditing(message.text)
    }

    /// Back to what the compose field held before the edit.
    func finishEditing() {
        editTarget = nil
        compose.hideReply()
        compose.draft = draftBeforeEditing ?? NSAttributedString()
        draftBeforeEditing = nil
    }

    private func saveEdit(of message: ChatMessage, text: String) {
        Task {
            do {
                try await store.edit(message, text: text)
            } catch {
                guard let window = view.window else { return }
                let alert = NSAlert()
                alert.messageText = "The message couldn't be edited."
                alert.informativeText = "Messenger only allows editing a message for 15 minutes after sending it, and only five times.\n\n\(error.localizedDescription)"
                alert.beginSheetModal(for: window, completionHandler: nil)
            }
        }
    }
}
