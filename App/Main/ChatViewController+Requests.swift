import AppKit

// MARK: - Message requests

// A request shows Block / Delete / Accept instead of the compose bar, like Messenger's: you
// can't reply before accepting, and the sender doesn't learn you opened it.

extension ChatViewController {
    func setUpRequestBar() {
        requestBar.onAccept = { [weak self] in self?.acceptRequest() }
        requestBar.onDelete = { [weak self] in self?.deleteRequest() }
        requestBar.onBlock = { [weak self] in self?.blockRequest() }
    }

    /// The compose bar, or the request's bar for a request.
    func updateRequestBar() {
        let conversation = threadID.flatMap { store.conversation($0) }
        let isRequest = conversation?.isRequest ?? false
        composeAccessory.isHidden = threadID == nil || isRequest
        requestAccessory.isHidden = !isRequest
        if let conversation, isRequest {
            requestBar.configure(name: senderName(of: conversation), isGroup: conversation.isGroup)
        }
    }

    /// The person who wrote (a 1:1 request's other participant).
    private func senderName(of conversation: Conversation) -> String {
        conversation.participants.first { $0.id != store.account?.id }?.name ?? conversation.name
    }

    private func acceptRequest() {
        guard let threadID else { return }
        Task {
            do {
                try await store.acceptRequest(threadID)
                // It's one of your chats now: the main window's list shows it there.
                (view.window?.windowController as? MainWindowController)?.select(threadID: threadID)
                compose.focus()
            } catch {
                _ = presentError(error)
            }
        }
    }

    private func deleteRequest() {
        guard let threadID, let window = view.window else { return }
        NSAlert.confirm("Delete this message request?", detail: "The chat is deleted, and the sender isn't told.",
                        button: "Delete", in: window) { [store] in
            try await store.deleteThread(threadID)
        }
    }

    private func blockRequest() {
        guard let threadID, let window = view.window, let conversation = store.conversation(threadID),
              let person = conversation.participants.first(where: { $0.id != store.account?.id }) else { return }
        NSAlert.confirm("Block \(person.name)?", detail: "They won't be able to message or call you on Messenger, and the request is deleted.",
                        button: "Block", in: window) { [store] in
            try await store.block(userID: person.id)
            try await store.deleteThread(threadID)
        }
    }
}
