import Foundation

/// The app's earlier identities: it was called MessengerMac, and until 0.9 its bundle ID was
/// com.kristofgruber.Hermes (a personal team; now it's the owner's paid one). On the first launch
/// under a new bundle ID, the old one's data moves over: the web view's data (the Messenger web
/// login, with the encrypted chats restored there) and the settings; from MessengerMac also the
/// data folder (chats, encryption keys, log). Runs before anything else.
enum RenameMigration {
    private static let oldName = "MessengerMac"

    static func run() {
        guard let newID = Bundle.main.bundleIdentifier, newID.hasSuffix(".Hermes") else { return }
        let prefix = String(newID.dropLast("Hermes".count))
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        move(support.appendingPathComponent(oldName, isDirectory: true), to: AppData.folder)

        // Newest first: the web data comes from the first one that has it, settings from all
        // (a key already set isn't overwritten).
        let previousIDs = ["com.kristofgruber.Hermes", "com.kristofgruber.\(oldName)", prefix + oldName]
        var seen: Set<String> = [newID]
        for oldID in previousIDs where seen.insert(oldID).inserted {
            migrate(from: oldID, to: newID)
        }
    }

    private static func migrate(from oldID: String, to newID: String) {
        let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        for folder in ["WebKit", "HTTPStorages"] {
            move(library.appendingPathComponent("\(folder)/\(oldID)"), to: library.appendingPathComponent("\(folder)/\(newID)"))
        }
        move(library.appendingPathComponent("HTTPStorages/\(oldID).binarycookies"),
             to: library.appendingPathComponent("HTTPStorages/\(newID).binarycookies"))

        // The MessengerMac key is the one earlier versions set.
        let doneKey = oldID.hasSuffix(".\(oldName)") ? "MigratedFrom\(oldName)" : "MigratedFrom \(oldID)"
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: doneKey) else { return }
        if let old = defaults.persistentDomain(forName: oldID) {
            for (key, value) in old where defaults.object(forKey: key) == nil {
                defaults.set(value, forKey: key)
            }
        }
        defaults.set(true, forKey: doneKey)
    }

    /// Moves it if it's there and nothing is at the new place yet.
    private static func move(_ source: URL, to destination: URL) {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: source.path), !fileManager.fileExists(atPath: destination.path) else { return }
        try? fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fileManager.moveItem(at: source, to: destination)
    }
}
