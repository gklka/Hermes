import AppKit

/// "New Chat" sheet: one token field that autocompletes anyone on Messenger, using the same
/// avatar list as @-mentions. Each person becomes a native token (accepted with Return, Tab,
/// comma, or by picking from the list); one person starts a 1:1 chat, several start a group.
final class NewChatViewController: NSViewController, NSTokenFieldDelegate {
    /// Called with the chosen people's user IDs.
    var onCreate: (([String]) -> Void)?

    private let fieldHost = TokenFieldHost()
    private var field: NSTokenField { fieldHost.field }
    private let picker = MentionPicker()
    private var searchTask: Task<Void, Never>?
    /// Finished searches, by lowercased query.
    private var cache: [String: [Participant]] = [:]
    /// Everyone seen in results, to turn a token or a picked suggestion back into a person.
    private var byID: [String: Participant] = [:]
    private var byName: [String: Participant] = [:]
    private var currentQuery = ""

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 380, height: 160))

        let title = NSTextField(labelWithString: "New Chat")
        title.font = .systemFont(ofSize: 13, weight: .semibold)

        field.placeholderString = "To: name"
        field.delegate = self
        field.tokenStyle = .rounded
        // Tokens are added by hand (from the list), not by the token field itself.
        field.tokenizingCharacterSet = CharacterSet()

        picker.onPick = { [weak self] candidate in
            guard let self, let person = self.byID[candidate.id] else { return }
            self.addToken(person)
        }

        let close = NSButton.glassClose(target: self, action: #selector(cancel))

        let note = NSTextField(wrappingLabelWithString: "Add one person for a direct chat, or several for a group.")
        note.font = .systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor

        let create = NSButton(title: "Chat", target: self, action: #selector(createChat))
        create.bezelStyle = .rounded
        create.keyEquivalent = "\r"

        for view in [title, close, fieldHost, note, create] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        NSLayoutConstraint.activate([
            close.topAnchor.constraint(equalTo: root.topAnchor, constant: 12),
            close.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            title.topAnchor.constraint(equalTo: root.topAnchor, constant: 16),
            title.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            fieldHost.topAnchor.constraint(equalTo: close.bottomAnchor, constant: 8),
            fieldHost.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            fieldHost.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            fieldHost.heightAnchor.constraint(equalToConstant: 24),
            note.topAnchor.constraint(equalTo: fieldHost.bottomAnchor, constant: 8),
            note.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            note.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            create.topAnchor.constraint(equalTo: note.bottomAnchor, constant: 14),
            create.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            create.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -14),
            create.widthAnchor.constraint(greaterThanOrEqualToConstant: 80),
            root.widthAnchor.constraint(equalToConstant: 380),
        ])
        view = root
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(field)
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        picker.hide()
    }

    @objc private func createChat() {
        let ids = participantIDs()
        guard !ids.isEmpty else {
            NSSound.beep()
            return
        }
        picker.hide()
        dismiss(nil)
        onCreate?(ids)
    }

    @objc private func cancel() {
        picker.hide()
        dismiss(nil)
    }

    // MARK: - Tokens

    private func currentTokens() -> [PersonToken] {
        ((field.objectValue as? [Any]) ?? []).compactMap { $0 as? PersonToken }
    }

    private func addToken(_ person: Participant) {
        byID[person.id] = person
        byName[person.name] = person
        var tokens = currentTokens()
        guard !tokens.contains(where: { $0.participant.id == person.id }) else {
            picker.hide()
            return
        }
        tokens.append(PersonToken(person))
        field.objectValue = tokens
        picker.hide()
        currentQuery = ""
        view.window?.makeFirstResponder(field)
        if let editor = field.currentEditor() {
            editor.selectedRange = NSRange(location: (editor.string as NSString).length, length: 0)
        }
    }

    /// The user IDs of the tokens, plus a fully typed but unadded name if it matches a result.
    private func participantIDs() -> [String] {
        var ids = currentTokens().map { $0.participant.id }
        if let person = byName[editingSubstring()], !ids.contains(person.id) {
            ids.append(person.id)
        }
        return ids
    }

    // MARK: - Suggestions

    /// The text being typed after the last token (tokens show as object-replacement characters).
    private func editingSubstring() -> String {
        guard let editor = field.currentEditor() else { return "" }
        let string = editor.string as NSString
        let marker = string.range(of: "\u{fffc}", options: .backwards)
        let start = marker.location == NSNotFound ? 0 : marker.location + marker.length
        return string.substring(from: start).trimmingCharacters(in: .whitespaces)
    }

    private func updateSuggestions() {
        let query = editingSubstring().lowercased()
        currentQuery = query
        guard query.count >= 2 else {
            picker.hide()
            return
        }
        refreshPicker()
        scheduleSearch(query)
    }

    private func scheduleSearch(_ query: String) {
        guard cache[query] == nil else { return }
        searchTask?.cancel()
        searchTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            let results = await ChatStore.shared.searchPeople(query)
            guard !Task.isCancelled, let self else { return }
            self.cache[query] = results
            for person in results {
                self.byID[person.id] = person
                self.byName[person.name] = person
            }
            guard self.currentQuery == query else { return }
            self.refreshPicker()
        }
    }

    private func refreshPicker() {
        guard let window = view.window, let results = cache[currentQuery] else { return }
        let taken = Set(currentTokens().map { $0.participant.id })
        let candidates = results
            .filter { !taken.contains($0.id) }
            .map { MentionCandidate(id: $0.id, name: $0.name, avatarURL: $0.avatarURL) }
        guard !candidates.isEmpty else {
            picker.hide()
            return
        }
        let anchor = window.convertToScreen(fieldHost.convert(fieldHost.bounds, to: nil))
        picker.show(candidates, above: anchor, in: window, below: true)
    }

    // MARK: - NSControl / NSTokenFieldDelegate

    func controlTextDidChange(_ obj: Notification) {
        // A comma accepts the highlighted suggestion (then the token field clears the stray comma).
        if let editor = field.currentEditor(), editor.string.hasSuffix(",") {
            if picker.isVisible {
                picker.pickSelected()
            } else {
                let string = editor.string as NSString
                editor.string = string.substring(to: string.length - 1)
            }
            return
        }
        updateSuggestions()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        // The list takes the arrow keys, Return, Tab and Escape while it's open.
        guard picker.isVisible else { return false }
        switch commandSelector {
        case #selector(NSResponder.moveUp(_:)):
            picker.moveSelection(by: -1)
            return true
        case #selector(NSResponder.moveDown(_:)):
            picker.moveSelection(by: 1)
            return true
        case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertTab(_:)):
            picker.pickSelected()
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            picker.hide()
            return true
        default:
            return false
        }
    }

    func tokenField(_ tokenField: NSTokenField, displayStringForRepresentedObject representedObject: Any) -> String? {
        (representedObject as? PersonToken)?.participant.name ?? representedObject as? String
    }

    func tokenField(_ tokenField: NSTokenField, styleForRepresentedObject representedObject: Any) -> NSTokenField.TokenStyle {
        .rounded
    }
}

/// Holds the token field with autoresizing (not Auto Layout), so AppKit never runs the token
/// field's multi-pass intrinsic-size computation — that commits the editor mid-layout and throws.
/// The host participates in Auto Layout; the field just fills it.
final class TokenFieldHost: NSView {
    let field = NSTokenField()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        field.translatesAutoresizingMaskIntoConstraints = true
        field.autoresizingMask = [.width, .height]
        addSubview(field)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        field.frame = bounds
    }
}

/// A person held by a token in the New Chat field.
final class PersonToken: NSObject {
    let participant: Participant
    init(_ participant: Participant) { self.participant = participant }
}
