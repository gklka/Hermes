import AppKit
import Network

/// Reconnects to Messenger at once when it's worth trying again: the network came back or
/// changed (another Wi-Fi, a VPN), the Mac woke, or you came back to the app while it showed
/// "Waiting for network…". Otherwise the core waits out its retry delay.
final class ConnectionWatcher {
    static let shared = ConnectionWatcher()

    private let monitor = NWPathMonitor()
    private var lastPath: NWPath?

    func start() {
        monitor.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async { self?.pathChanged(path) }
        }
        monitor.start(queue: DispatchQueue(label: "ConnectionWatcher"))
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(didWake), name: NSWorkspace.didWakeNotification, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(didBecomeActive), name: NSApplication.didBecomeActiveNotification, object: nil
        )
    }

    private func pathChanged(_ path: NWPath) {
        defer { lastPath = path }
        guard path.status == .satisfied, let lastPath else { return }
        // Back online, or online another way.
        if lastPath.status != .satisfied || lastPath.availableInterfaces.map(\.name) != path.availableInterfaces.map(\.name) {
            ChatStore.shared.reconnectNow(reason: "network changed")
        }
    }

    @objc private func didWake() {
        ChatStore.shared.reconnectNow(reason: "woke")
    }

    @objc private func didBecomeActive() {
        ChatStore.shared.reconnectNow(reason: "app active")
    }
}
