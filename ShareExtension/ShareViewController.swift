import AppKit
import UniformTypeIdentifiers

/// The Share menu's "Hermes": pick one of the most recent chats (a row of pictures, or
/// the menu for more), add a message, Send. What's shared goes to the app through ShareHandoff.
final class ShareViewController: NSViewController {
    /// How many recent chats the row of pictures shows.
    private static let quickCount = 5

    private let quickRow = NSStackView()
    private var quickButtons: [NSButton] = []
    private let chatPopUp = NSPopUpButton()
    private let messageField = NSTextField()
    private let attachmentsLabel = NSTextField(labelWithString: "")
    private let sendButton = NSButton(title: "Send", target: nil, action: nil)

    private var chats: [ShareHandoff.Chat] = []
    /// Copies of the shared files, in the extension's temporary folder.
    private var files: [URL] = []
    private var pendingLoads = 0

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 440, height: 320))

        let title = NSTextField(labelWithString: "Send with Messenger")
        title.font = .systemFont(ofSize: 13, weight: .semibold)

        quickRow.orientation = .horizontal
        quickRow.distribution = .fillEqually
        quickRow.spacing = 6

        let toLabel = NSTextField(labelWithString: "To:")
        let toRow = NSStackView(views: [toLabel, chatPopUp])
        toRow.spacing = 8
        chatPopUp.setContentHuggingPriority(.defaultLow, for: .horizontal)
        chatPopUp.target = self
        chatPopUp.action = #selector(chatChosen)

        messageField.placeholderString = "Message"
        messageField.usesSingleLineMode = false
        messageField.cell?.wraps = true
        messageField.cell?.isScrollable = false
        messageField.lineBreakMode = .byWordWrapping

        attachmentsLabel.textColor = .secondaryLabelColor
        attachmentsLabel.font = .systemFont(ofSize: 11)

        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancelButton.keyEquivalent = "\u{1b}"
        sendButton.target = self
        sendButton.action = #selector(send)
        sendButton.keyEquivalent = "\r"
        let buttons = NSStackView(views: [NSView(), cancelButton, sendButton])
        buttons.spacing = 8

        let stack = NSStackView(views: [title, quickRow, toRow, messageField, attachmentsLabel, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 16),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -16),
            quickRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            toRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            messageField.widthAnchor.constraint(equalTo: stack.widthAnchor),
            messageField.heightAnchor.constraint(equalToConstant: 70),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        loadChats()
        loadSharedItems()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(messageField)
    }

    // MARK: - Chats

    /// The app's most recent chats (ShareSupport), the first one picked.
    private func loadChats() {
        if let file = ShareHandoff.recentChatsFile, let data = try? Data(contentsOf: file),
           let saved = try? JSONDecoder().decode([ShareHandoff.Chat].self, from: data) {
            chats = saved
        }
        chatPopUp.removeAllItems()
        for chat in chats {
            chatPopUp.addItem(withTitle: chat.name)
            chatPopUp.lastItem?.representedObject = chat.id
            chatPopUp.lastItem?.image = Self.avatar(for: chat, size: 16)
        }
        for (index, chat) in chats.prefix(Self.quickCount).enumerated() {
            let button = NSButton(title: chat.name, image: Self.avatar(for: chat, size: 40), target: self, action: #selector(quickChosen))
            button.tag = index
            button.imagePosition = .imageAbove
            button.isBordered = false
            button.font = .systemFont(ofSize: 11)
            button.lineBreakMode = .byTruncatingTail
            button.wantsLayer = true
            button.layer?.cornerRadius = 8
            button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            quickButtons.append(button)
            quickRow.addArrangedSubview(button)
        }
        quickRow.isHidden = quickButtons.isEmpty
        if chats.isEmpty {
            chatPopUp.addItem(withTitle: "Open Hermes first")
            chatPopUp.isEnabled = false
        }
        updateQuickSelection()
        updateSendButton()
    }

    @objc private func quickChosen(_ sender: NSButton) {
        chatPopUp.selectItem(at: sender.tag)
        updateQuickSelection()
    }

    @objc private func chatChosen() {
        updateQuickSelection()
    }

    /// The picked chat's picture is highlighted in the row.
    private func updateQuickSelection() {
        for button in quickButtons {
            let selected = button.tag == chatPopUp.indexOfSelectedItem
            button.layer?.backgroundColor = selected ? NSColor.controlAccentColor.withAlphaComponent(0.2).cgColor : nil
        }
    }

    /// The chat's picture from the app group, or its initials on gray, in a circle.
    private static func avatar(for chat: ShareHandoff.Chat, size: CGFloat) -> NSImage {
        let picture = chat.hasAvatar
            ? ShareHandoff.avatarsFolder.flatMap { NSImage(contentsOf: $0.appendingPathComponent("\(chat.id).png")) }
            : nil
        return RoundAvatar.image(picture, name: chat.name, size: size)
    }

    // MARK: - Shared items

    private func loadSharedItems() {
        let items = extensionContext?.inputItems.compactMap { $0 as? NSExtensionItem } ?? []
        for item in items {
            if let text = item.attributedContentText?.string, !text.isEmpty {
                appendText(text)
            }
            for provider in item.attachments ?? [] {
                load(provider)
            }
        }
        updateAttachmentsLabel()
    }

    private func load(_ provider: NSItemProvider) {
        pendingLoads += 1
        Task {
            defer {
                pendingLoads -= 1
                updateAttachmentsLabel()
                updateSendButton()
            }
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                if let url = try? await Self.loadURL(provider, type: .fileURL), let copy = Self.copyToTemporary(url) {
                    files.append(copy)
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                if let url = try? await Self.loadURL(provider, type: .url) {
                    appendText(url.absoluteString)
                }
            } else if let type = [UTType.image, .movie, .audio, .pdf, .data].first(where: {
                provider.hasItemConformingToTypeIdentifier($0.identifier)
            }), type != .data || !provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
                if let copy = await Self.loadFile(provider, type: type) {
                    files.append(copy)
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
                if let text = try? await provider.loadItem(forTypeIdentifier: UTType.plainText.identifier) as? String {
                    appendText(text)
                }
            }
        }
    }

    private static func loadURL(_ provider: NSItemProvider, type: UTType) async throws -> URL? {
        let item = try await provider.loadItem(forTypeIdentifier: type.identifier)
        if let url = item as? URL { return url }
        if let data = item as? Data { return URL(dataRepresentation: data, relativeTo: nil) }
        if let string = item as? String { return URL(string: string) }
        return nil
    }

    /// The provider's file (e.g. a photo from Photos, which has no file URL), copied out.
    private static func loadFile(_ provider: NSItemProvider, type: UTType) async -> URL? {
        let name = provider.suggestedName
        return await withCheckedContinuation { continuation in
            _ = provider.loadFileRepresentation(forTypeIdentifier: type.identifier) { url, _ in
                // The file only exists until this returns.
                continuation.resume(returning: url.flatMap { Self.copyToTemporary($0, name: name) })
            }
        }
    }

    nonisolated private static func copyToTemporary(_ url: URL, name: String? = nil) -> URL? {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        var fileName = url.lastPathComponent
        if let name, !name.isEmpty {
            fileName = url.pathExtension.isEmpty || name.hasSuffix("." + url.pathExtension) ? name : "\(name).\(url.pathExtension)"
        }
        let copy = folder.appendingPathComponent(fileName)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: url, to: copy)
            return copy
        } catch {
            return nil
        }
    }

    private func appendText(_ text: String) {
        let current = messageField.stringValue
        guard !current.contains(text) else { return }
        messageField.stringValue = current.isEmpty ? text : current + "\n" + text
    }

    private func updateAttachmentsLabel() {
        if pendingLoads > 0 {
            attachmentsLabel.stringValue = "Preparing…"
        } else if files.isEmpty {
            attachmentsLabel.stringValue = ""
        } else {
            let names = files.map(\.lastPathComponent)
            attachmentsLabel.stringValue = names.count == 1 ? names[0] : "\(names.count) files"
        }
        attachmentsLabel.isHidden = attachmentsLabel.stringValue.isEmpty
    }

    private func updateSendButton() {
        sendButton.isEnabled = !chats.isEmpty && pendingLoads == 0
    }

    // MARK: - Actions

    @objc private func cancel() {
        extensionContext?.cancelRequest(withError: NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError))
    }

    @objc private func send() {
        guard let threadID = chatPopUp.selectedItem?.representedObject as? String,
              let outbox = ShareHandoff.outbox else { return }
        let text = messageField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !files.isEmpty else { return }
        let id = UUID().uuidString
        let folder = outbox.appendingPathComponent(id, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            var names: [String] = []
            for (index, file) in files.enumerated() {
                // A numbered subfolder keeps files with the same name apart.
                let name = "\(index)/\(file.lastPathComponent)"
                try FileManager.default.createDirectory(
                    at: folder.appendingPathComponent("\(index)", isDirectory: true), withIntermediateDirectories: true
                )
                try FileManager.default.moveItem(at: file, to: folder.appendingPathComponent(name))
                names.append(name)
            }
            let request = ShareHandoff.Request(threadID: threadID, text: text, files: names)
            try JSONEncoder().encode(request).write(to: folder.appendingPathComponent(ShareHandoff.requestFileName))
        } catch {
            let alert = NSAlert(error: error)
            alert.runModal()
            return
        }
        var components = URLComponents()
        components.scheme = ShareHandoff.urlScheme
        components.host = ShareHandoff.shareHost
        components.queryItems = [URLQueryItem(name: "id", value: id)]
        if let url = components.url {
            // In the background: the app sends without coming to the front.
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = false
            NSWorkspace.shared.open(url, configuration: configuration)
        }
        extensionContext?.completeRequest(returningItems: nil)
    }
}
