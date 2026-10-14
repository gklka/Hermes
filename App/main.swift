import AppKit

MainActor.assumeIsolated {
    let app = NSApplication.shared
    // The application keeps its delegate weakly; this one lives as long as the app runs.
    let delegate = AppDelegate()
    app.delegate = delegate
    _ = NSApplicationMain(CommandLine.argc, CommandLine.unsafeArgv)
}
