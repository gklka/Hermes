import AppKit

// MARK: - Find in Chat

extension ChatViewController {
    /// How many pages of older history a search may fetch from Messenger.
    private static let searchPageLimit = 50

    /// Edit → Find in Chat.
    func startSearch() {
        guard threadID != nil else { return }
        searchAccessory.isHidden = false
        view.window?.makeFirstResponder(searchBar.searchField)
        searchBar.searchField.currentEditor()?.selectAll(nil)
    }

    func endSearch() {
        let wasSearching = searchResults != nil
        resetSearch()
        if wasSearching { reload(scrollToBottom: true) }
        compose.focus()
    }

    func resetSearch() {
        searchTask?.cancel()
        searchTask = nil
        searchResults = nil
        // Back from results to the chat isn't new messages arriving.
        shownThreadID = nil
        searchBar.searchField.stringValue = ""
        searchBar.status = ""
        searchAccessory.isHidden = true
    }

    /// Searches the stored messages, then fetches older history page by page (where Messenger
    /// has it) and searches again after each, until the start, the page limit, or a new search.
    func searchChanged(_ text: String) {
        searchTask?.cancel()
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let threadID, !text.isEmpty else {
            searchResults = nil
            shownThreadID = nil
            searchBar.status = ""
            reload(scrollToBottom: true)
            return
        }
        searchTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            var pages = 0
            var canFetch = true
            while !Task.isCancelled {
                guard let self, let page = await self.store.searchMessages(in: threadID, text: text),
                      !Task.isCancelled, self.threadID == threadID else { return }
                let fetching = canFetch && page.hasMore && pages < Self.searchPageLimit
                self.showSearchResults(page.messages, fetchingOlder: fetching)
                guard fetching, let result = await self.store.fetchOlderForSearch(threadID) else { return }
                pages += 1
                // No progress: search once more, then stop.
                canFetch = result.fetched > 0
            }
        }
    }

    private func showSearchResults(_ messages: [ChatMessage], fetchingOlder: Bool) {
        searchResults = messages
        // Results don't animate in.
        shownThreadID = nil
        let found = switch messages.count {
        case 0: "No matches"
        case 1: "1 found"
        default: "\(messages.count) found"
        }
        searchBar.status = fetchingOlder ? "\(found) · searching older…" : found
        reload(scrollToBottom: true)
    }
}
