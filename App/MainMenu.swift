import AppKit

enum MainMenu {
    static func build() -> NSMenu {
        let main = NSMenu()
        let appName = ProcessInfo.processInfo.processName

        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About \(appName)", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(withTitle: "Check for Updates…", action: #selector(AppDelegate.checkForUpdates(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Log Out", action: #selector(AppDelegate.logOut(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        let services = NSMenu()
        appMenu.addItem(withTitle: "Services", action: nil, keyEquivalent: "").submenu = services
        NSApp.servicesMenu = services
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide \(appName)", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit \(appName)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.addItem(withTitle: appName, action: nil, keyEquivalent: "").submenu = appMenu

        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(withTitle: "Open Chat…", action: #selector(MainWindowController.newMessage(_:)), keyEquivalent: "o")
        // ⌘N still works, as in Messages.
        let newMessage = fileMenu.addItem(withTitle: "New Message", action: #selector(MainWindowController.newMessage(_:)), keyEquivalent: "n")
        newMessage.isHidden = true
        newMessage.allowsKeyEquivalentWhenHidden = true
        let attach = fileMenu.addItem(withTitle: "Attach Files…", action: #selector(MainWindowController.attachFiles(_:)), keyEquivalent: "a")
        attach.keyEquivalentModifierMask = [.command, .shift]
        fileMenu.addItem(withTitle: "Restore Encrypted Chats…", action: #selector(AppDelegate.showWebSync(_:)), keyEquivalent: "")
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        main.addItem(withTitle: "File", action: nil, keyEquivalent: "").submenu = fileMenu

        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenu.addItem(.separator())
        let find = editMenu.addItem(withTitle: "Find…", action: #selector(MainWindowController.focusSearch(_:)), keyEquivalent: "f")
        find.keyEquivalentModifierMask = [.command]
        let findInChat = editMenu.addItem(withTitle: "Find in Chat…", action: #selector(MainWindowController.findInChat(_:)), keyEquivalent: "f")
        findInChat.keyEquivalentModifierMask = [.command, .option]
        let emoji = editMenu.addItem(withTitle: "Emoji & Symbols", action: #selector(NSApplication.orderFrontCharacterPalette(_:)), keyEquivalent: " ")
        emoji.keyEquivalentModifierMask = [.command, .control]
        main.addItem(withTitle: "Edit", action: nil, keyEquivalent: "").submenu = editMenu

        let viewMenu = NSMenu(title: "View")
        let sidebar = viewMenu.addItem(withTitle: "Toggle Sidebar", action: #selector(NSSplitViewController.toggleSidebar(_:)), keyEquivalent: "s")
        sidebar.keyEquivalentModifierMask = [.command, .control]
        main.addItem(withTitle: "View", action: nil, keyEquivalent: "").submenu = viewMenu

        let conversationMenu = NSMenu(title: "Conversation")
        let unread = conversationMenu.addItem(withTitle: "Mark as Unread", action: #selector(MainWindowController.toggleUnread(_:)), keyEquivalent: "u")
        unread.keyEquivalentModifierMask = [.command, .shift]
        conversationMenu.addItem(withTitle: "Like", action: #selector(MainWindowController.sendLike(_:)), keyEquivalent: "l")
        conversationMenu.addItem(withTitle: "Edit Message", action: #selector(MainWindowController.editMessage(_:)), keyEquivalent: "e")
        conversationMenu.addItem(.separator())
        conversationMenu.addItem(withTitle: "Audio Call", action: #selector(MainWindowController.startAudioCall(_:)), keyEquivalent: "")
        conversationMenu.addItem(withTitle: "Video Call", action: #selector(MainWindowController.startVideoCall(_:)), keyEquivalent: "")
        conversationMenu.addItem(.separator())
        conversationMenu.addItem(withTitle: "Refresh",action: #selector(MainWindowController.refreshChat(_:)), keyEquivalent: "r")
        let export = conversationMenu.addItem(withTitle: "Export Chat…", action: #selector(MainWindowController.exportChat(_:)), keyEquivalent: "e")
        export.keyEquivalentModifierMask = [.command, .shift]
        main.addItem(withTitle: "Conversation", action: nil, keyEquivalent: "").submenu = conversationMenu

        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenu.addItem(.separator())
        let activity = windowMenu.addItem(withTitle: "Activity", action: #selector(AppDelegate.toggleActivity(_:)), keyEquivalent: "0")
        activity.keyEquivalentModifierMask = [.command, .option]
        main.addItem(withTitle: "Window", action: nil, keyEquivalent: "").submenu = windowMenu
        NSApp.windowsMenu = windowMenu

        return main
    }
}
