import AppKit
import Contacts
import ContactsUI

/// Show Contact Card: finds the person of a 1:1 chat (or a group chat sender) among the Mac's contacts and shows their
/// card. A Facebook link on the card (a Facebook profile, or a facebook.com URL with their user
/// ID) matches; otherwise their name does, if exactly one contact has it.
final class ContactCards {
    static let shared = ContactCards()

    private let store = CNContactStore()
    /// The contacts by what can match them; nil until read (and after the contacts change).
    private var index: Index?
    private var loading: Task<Void, Never>?

    private struct Index {
        /// Facebook user ID → contact identifier.
        var byFacebookID: [String: String] = [:]
        /// Folded name → contact identifiers.
        var byName: [String: [String]] = [:]
    }

    private init() {
        NotificationCenter.default.addObserver(forName: .CNContactStoreDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.index = nil
                self?.loading = nil
                self?.prepare()
            }
        }
    }

    /// Whether access to the contacts hasn't been asked for yet (the menu item asks).
    var canAsk: Bool { CNContactStore.authorizationStatus(for: .contacts) == .notDetermined }

    private var isAuthorized: Bool { CNContactStore.authorizationStatus(for: .contacts) == .authorized }

    /// Reads the contacts in the background if allowed, so menus can tell whether there's a card.
    func prepare() {
        guard isAuthorized, index == nil, loading == nil else { return }
        loading = Task {
            let index = await Task.detached(priority: .utility) { Self.buildIndex() }.value
            self.index = index
        }
    }

    /// The matching contact's identifier, if the contacts have been read.
    func match(userID: String, name: String) -> String? {
        guard let index else { return nil }
        if let id = index.byFacebookID[userID] { return id }
        let byName = index.byName[Self.fold(name)] ?? []
        return byName.count == 1 ? byName[0] : nil
    }

    /// Asks for access if needed, reads the contacts, and returns the match.
    func findMatch(userID: String, name: String) async -> String? {
        if canAsk {
            _ = try? await store.requestAccess(for: .contacts)
        }
        prepare()
        await loading?.value
        return match(userID: userID, name: name)
    }

    /// The contact's card in a popover next to `rect` of `view`, with a button opening it in Contacts.
    func showCard(_ identifier: String, relativeTo rect: NSRect, of view: NSView) {
        let keys = [CNContactViewController.descriptorForRequiredKeys()]
        guard let contact = try? store.unifiedContact(withIdentifier: identifier, keysToFetch: keys) else { return }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = CardViewController(contact: contact) { [weak popover] in
            popover?.close()
            // Contacts opens the card for an addressbook:// link with its identifier.
            if let url = URL(string: "addressbook://\(identifier)") {
                NSWorkspace.shared.open(url)
            }
        }
        popover.contentSize = NSSize(width: 360, height: 520)
        popover.show(relativeTo: rect, of: view, preferredEdge: .maxX)
    }

    // MARK: - Reading the contacts

    nonisolated private static func buildIndex() -> Index {
        var index = Index()
        let keys: [CNKeyDescriptor] = [
            CNContactIdentifierKey, CNContactGivenNameKey, CNContactMiddleNameKey, CNContactFamilyNameKey,
            CNContactNicknameKey, CNContactSocialProfilesKey, CNContactUrlAddressesKey,
        ].map { $0 as CNKeyDescriptor }
        let request = CNContactFetchRequest(keysToFetch: keys)
        try? CNContactStore().enumerateContacts(with: request) { contact, _ in
            for id in facebookIDs(of: contact) {
                index.byFacebookID[id] = contact.identifier
            }
            for name in names(of: contact) where !name.isEmpty {
                index.byName[name, default: []].append(contact.identifier)
            }
        }
        // A contact listed under two of its names counts once.
        index.byName = index.byName.mapValues { Array(Set($0)) }
        return index
    }

    /// Facebook user IDs on the card: a Facebook profile's ID (or numeric user name), and
    /// facebook.com links with an ID ("facebook.com/123", "profile.php?id=123").
    nonisolated private static func facebookIDs(of contact: CNContact) -> [String] {
        var ids: [String] = []
        var links: [String] = contact.urlAddresses.map { $0.value as String }
        for profile in contact.socialProfiles.map(\.value) where profile.service.lowercased().contains("facebook") {
            for value in [profile.userIdentifier, profile.username] where !value.isEmpty && value.allSatisfy(\.isNumber) {
                ids.append(value)
            }
            links.append(profile.urlString)
        }
        for link in links where link.lowercased().contains("facebook.com") {
            for pattern in [#"[?&]id=(\d+)"#, #"facebook\.com/(\d+)"#] {
                if let match = link.range(of: pattern, options: .regularExpression) {
                    ids.append(String(link[match].drop { !$0.isNumber }.prefix { $0.isNumber }))
                }
            }
        }
        return ids
    }

    /// The names the contact could have on Facebook: given + family name in both orders (family
    /// first, as in Hungarian), with the middle name, and the nickname.
    nonisolated private static func names(of contact: CNContact) -> [String] {
        let given = contact.givenName, middle = contact.middleName, family = contact.familyName
        return [
            "\(given) \(family)", "\(family) \(given)", "\(given) \(middle) \(family)", "\(family) \(given) \(middle)",
            contact.nickname,
        ].map(fold)
    }

    /// Ignoring case, accents and extra spaces.
    nonisolated private static func fold(_ name: String) -> String {
        name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

/// The system's contact card under an Open with Contacts button, like Mail's.
private final class CardViewController: NSViewController {
    private let card = CNContactViewController()
    private let onOpen: () -> Void

    init(contact: CNContact, onOpen: @escaping () -> Void) {
        self.onOpen = onOpen
        super.init(nibName: nil, bundle: nil)
        card.contact = contact
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let container = NSView()
        addChild(card)
        let button = NSButton(title: "Open with Contacts", target: self, action: #selector(open))
        button.bezelStyle = .push
        button.controlSize = .large
        // The card in a rounded inset below the button.
        card.view.wantsLayer = true
        card.view.layer?.cornerRadius = 18
        card.view.layer?.masksToBounds = true
        for view in [card.view, button] {
            view.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(view)
        }
        NSLayoutConstraint.activate([
            button.topAnchor.constraint(equalTo: container.topAnchor, constant: 8),
            button.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -10),
            card.view.topAnchor.constraint(equalTo: button.bottomAnchor, constant: 8),
            card.view.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            card.view.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            card.view.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -8),
        ])
        view = container
    }

    @objc private func open() {
        onOpen()
    }
}
