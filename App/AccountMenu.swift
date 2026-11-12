import AppKit

/// The Account menu: the accounts on this Mac with their pictures (the active one ticked;
/// choosing another relaunches with it), then Log Out.
final class AccountMenu: NSObject, NSMenuDelegate {
    static let shared = AccountMenu()

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let accounts = Accounts.loggedIn
        for account in accounts {
            let name = account.name ?? "Account"
            let item = NSMenuItem(title: name, action: #selector(AppDelegate.switchAccount(_:)), keyEquivalent: "")
            item.representedObject = account.key
            item.state = account.key == Accounts.active ? .on : .off
            let picture = NSImage(contentsOf: Accounts.pictureFile(for: account.key))
            item.image = RoundAvatar.image(picture, name: name, size: 20)
            if accounts.count > 1, Accounts.isMainAccount(account) {
                item.subtitle = "Main account, in Spotlight, Siri and Shortcuts"
            }
            menu.addItem(item)
        }
        if !accounts.isEmpty { menu.addItem(.separator()) }
        menu.addItem(withTitle: "Log Out…", action: #selector(AppDelegate.logOut(_:)), keyEquivalent: "")
    }
}
