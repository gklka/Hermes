import Foundation

/// The app used to be called MessengerMac. On the first launch as Hermes, its data moves over:
/// the data folder (chats, encryption keys, log), the web view's data (the Messenger web login,
/// with the encrypted chats restored there) and the settings. Runs before anything else.
enum RenameMigration {
    private static let oldName = "MessengerMac"
    private static let doneKey = "MigratedFromMessengerMac"

    static func run() {
        guard let newID = Bundle.main.bundleIdentifier, newID.hasSuffix(".Hermes") else { return }
        let oldID = String(newID.dropLast("Hermes".count)) + oldName
        let fileManager = FileManager.default
        let library = fileManager.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]

        move(support.appendingPathComponent(oldName, isDirectory: true), to: AppData.folder)
        for folder in ["WebKit", "HTTPStorages"] {
            move(library.appendingPathComponent("\(folder)/\(oldID)"), to: library.appendingPathComponent("\(folder)/\(newID)"))
        }
        move(library.appendingPathComponent("HTTPStorages/\(oldID).binarycookies"),
             to: library.appendingPathComponent("HTTPStorages/\(newID).binarycookies"))

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
