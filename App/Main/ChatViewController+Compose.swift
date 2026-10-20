import AppKit

// The compose bar: sending, replying, editing a sent message, and telling the chat you're typing.

extension ChatViewController: ComposeViewDelegate {
    func composeView(_ view: ComposeView, send text: String, mentions: [Mention], attachments: [URL]) {
        guard let threadID else { return }
        store.clearMarkedUnread(threadID)
        if let message = editTarget {
            finishEditing()
            guard !text.isEmpty, text != message.text else { return }
            saveEdit(of: message, text: text)
            return
        }
        store.send(text: text, mentions: mentions, attachments: attachments, in: threadID, replyTo: replyTarget?.id)
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

    func composeViewAttachFiles(_ view: ComposeView) {
        attachFiles()
    }

    func composeViewCanCreatePoll(_ view: ComposeView) -> Bool {
        threadID.map { store.canCreatePoll(in: $0) } ?? false
    }

    func composeView(_ view: ComposeView, createPoll question: String, options: [String]) {
        guard let threadID else { return }
        Task { [weak self] in
            do {
                try await ChatStore.shared.createPoll(in: threadID, question: question, options: options)
            } catch {
                self?.showPollError("The poll couldn't be created", error)
            }
        }
    }

    /// Added choices aren't voted for (your votes stay as they were); the comment goes as a message.
    func composeView(_ view: ComposeView, addChoices choices: [String], to poll: Poll, comment: String) {
        guard let threadID else { return }
        let selected = poll.options.filter { $0.voted == true }.map(\.id)
        let added = choices.map { NewPollOption(text: $0, voted: false) }
        Task { [weak self] in
            do {
                try await ChatStore.shared.vote(in: poll.id, threadID: threadID, selected: selected, added: added)
                if !comment.isEmpty {
                    ChatStore.shared.send(text: comment, mentions: [], attachments: [], in: threadID, replyTo: nil)
                }
            } catch {
                self?.showPollError("The choices couldn't be added", error)
            }
        }
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
        selectMessage(message.id, dismissable: false)
        compose.showEditing(message.text)
    }

    /// Back to what the compose field held before the edit.
    func finishEditing() {
        editTarget = nil
        selectMessage(nil)
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
