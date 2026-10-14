import Foundation

/// Runs an action once a burst of calls has settled: chat updates come in bursts while
/// syncing, and the Spotlight index and the share sheet's chats only need the result.
final class Debouncer {
    private let delay: Duration
    private var pending: Task<Void, Never>?

    init(delay: Duration) {
        self.delay = delay
    }

    /// Runs `action` after the delay, unless called again before that.
    func schedule(_ action: @escaping () async -> Void) {
        pending?.cancel()
        pending = Task { [delay] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await action()
        }
    }

    func cancel() {
        pending?.cancel()
        pending = nil
    }
}
