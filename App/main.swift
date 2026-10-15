import AppKit

MainActor.assumeIsolated {
    // Before anything opens the data folder or the web view's data.
    RenameMigration.run()
    let app = NSApplication.shared
    // The application keeps its delegate weakly; this one lives as long as the app runs.
    let delegate = AppDelegate()
    app.delegate = delegate
    _ = NSApplicationMain(CommandLine.argc, CommandLine.unsafeArgv)
}
