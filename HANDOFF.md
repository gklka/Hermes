# Hermes — handoff notes for Claude

This file lets a new Claude Code session pick up this project, also on another machine. Read it fully before making changes.

## What this is

A personal, learning-purpose native macOS client for **Facebook Messenger**. Owner's brief: "a native macOS app, just for myself, for learning purposes… it has to look similar to the Apple Messages app, but support the features of the FB network."

- UI: **AppKit** (no SwiftUI), styled like Apple Messages.
- Backend: a **Go core** wrapping [`go.mau.fi/mautrix-meta`](https://github.com/mautrix/meta) `pkg/messagix` (Facebook web protocol, LightSpeed over MQTT/WebSocket), plus `whatsmeow` for end-to-end encrypted chats. It's built as a static c-archive and linked into the app.
- Owner's choices: "Go core + Swift UI" over pure Swift or a web wrapper; a **plain .xcodeproj** (not XcodeGen).

## How the user wants you to work

These come from the user's global `~/.claude/CLAUDE.md` plus feedback given during the project. Recreate them in memory on a new machine.

- Keep answers **short and easy to understand**.
- **Don't commit or push** unless explicitly asked. When asked, commit and push to `main` directly (no branches).
- **Always edit files with Edit/Write**, never sed/perl/heredocs in Bash. The user wants inline diffs.
- Be careful with debug logs: no force-unwraps, and only log values that are actually accessible.
- **Always build, install and relaunch after every change** (`Support/install.sh`), without asking. But not while an import is running (the web history import can take minutes; check `core.log` first). A relaunch once interrupted an import.
- Don't drive the screen (osascript clicks, screencapture) to test; ask the user to try things instead.
- **Off-limits:** don't help reverse-engineer Meta's PIN-protected encrypted backup ("Labyrinth"). That was declined. The hidden-WebView approach below is what the user chose instead.

## Building, installing, testing

1. Install Xcode 26+ and Go (`brew install go`). `Support/build-core.sh` adds `/opt/homebrew/bin` and `/usr/local/go/bin` to `PATH`.
2. **Day to day: `Support/install.sh`.** It builds Release, installs it to `/Applications`, unregisters the build-folder copies, relaunches the app, and restarts `intelligenceflowd` (Siri/Shortcuts keep an app's old actions until it restarts). Siri and Shortcuts need a team-signed app with only one registered copy.
   - `DEVELOPER_DIR` defaults to `/Applications/Xcode 27.1.app` in the script; override it on another machine.
   - Before installing, wait for a running import to finish:
     ```sh
     L() { grep -o '"message":"WebHistoryImporter[^"]*' ~/Library/Application\ Support/Hermes/core.log | tail -1; }
     until L | grep -qE "imported|skipped|collected|empty"; do sleep 5; done; Support/install.sh
     ```
3. Go checks:
   ```sh
   cd Core && CC="xcrun --sdk macosx clang" go vet . && go test -run 'TestSearchFold|TestParseAge|TestAvatarKey|TestWebMessageID|TestUnrestoredPlaceholder|TestWithoutEmoji' .
   ```
4. Shortcuts end-to-end tests: `shortcuts run "MM Test Send"` (also `Edit`, `Unsend`, `Unread`, `Read`). They act on your chat with yourself (its thread ID is your Facebook user ID); check the result in `app.db` (`messages`, and the kv key `unread:<thread ID>`). A run can hang on a one-time "Allow" prompt, so wrap it in a timeout.
5. The first launch shows facebook.com's login in a web view. The app then registers itself as a new E2EE device; restore encrypted chats with the PIN once ("Restore Encrypted Chats…").

Signing: `Support/Signing.xcconfig` holds placeholders; the real bundle ID prefix and team go in `Support/Signing.local.xcconfig`, which isn't committed (create it on a new machine). The App Group (`<team>.<prefix>.Hermes`, shared with the share extension) is derived from them, also in the entitlements and Info.plists.

## Architecture

```
AppKit UI (App/)  ──JSON-RPC over C calls──▶  Go core (Core/ → Core/build/libmmcore.a)
                                              ├─ messagix  → facebook.com (threads, messages, contacts)
                                              └─ whatsmeow → E2EE chats (Signal protocol)
Hidden WKWebView (App/WebSync/) → facebook.com/messages, to read E2EE history and themes the web app has
Share extension (ShareExtension/) ──App Group files + hermes:// URL──▶ the app
```

### Xcode and build plumbing
- `Hermes.xcodeproj`: **synchronized folder groups**, so new files in `App/`, `Shared/` and `ShareExtension/` are picked up automatically. `Shared/` is in both targets.
- The "Build Go Core" phase runs `Support/build-core.sh`: builds the c-archive per arch and lipos it into `Core/build/libmmcore.a` and `.h` (`CC="xcrun --sdk macosx clang"`).
- Bridging header: `Support/Hermes-Bridging-Header.h`.
- `SWIFT_VERSION` 5 with **default actor isolation MainActor**. Off-main code must be `nonisolated` (e.g. `OutgoingMedia.prepare`, `ImageSize.probe`, decoded web types). Pass closures, not function references, to `map` and friends, or the compiler warns about isolation.
- The build has **no warnings**; keep it that way.
- SourceKit "Cannot find type … in scope" diagnostics are cross-file indexing noise. Trust `xcodebuild`.

### Go core (`Core/`)
- `go.mod` has a replace directive: `github.com/imroc/req/v3 => github.com/beeper/req/v3 …`.
- `main.go`: the cgo exports `MMStart`/`MMRequest`; responses and events go back through one callback (`emitResponse`/`emitEvent`).
- `api.go`: **the JSON shapes, mirrored in `App/Core/Models.swift`. Keep them in sync.** Every event and result has a typed struct.
- `rpc.go`: `HandleRequest` and `dispatch`, the list of every request. Requests that send or change messages run on a serial `sendQueue`, in order.
- `core.go`: the `Core`, login/connect/logout, the E2EE device, `requireClient`/`requireE2EE`.
- `changes.go`: `changeSet` and `flush` (emit `thread`/`message` events once per update), `emitThread`/`emitMessage`/`removeThread`, `applyRead`/`applyEdit`/`applyUnsend` (shared by both connections), pending (optimistic) sends.
- `meta.go`: `handleTable` for LightSpeed sync tables (threads, messages, reads), the FB-key↔JID thread mapping, sync group constants (1 regular, 95 encrypted).
- `e2ee.go`: whatsmeow events (messages, receipts, typing, presence).
- `threads.go`: chat list paging, chat actions (mark read/unread, mute, delete, leave, block), typing and presence.
- `history.go`: message pages and backfill from Messenger. `search.go`: Find in Chat.
- `send.go`: sending text and files over either connection. `message_actions.go`: react, unsend, edit. `media.go`: downloads.
- `reactions.go`: incoming reactions (and the "reaction" event for notifications). `names.go`: looking up names the sync didn't give. `themes.go`: chat themes and quick reactions.
- `store.go`: SQLite (modernc), tables kv, contacts, threads, participants, messages, reactions. The kv key prefixes (`map:`, `webmap:`, `webid:`, `colors:`, `emoji:`, `unread:`, `edits:`, `themecolors:`) and folder names are constants at the top. `threadRow.Visible()` decides what's in the chat list.
- `webimport.go`: turns chats and messages read from the web app into rows. A message's timestamp is `messageID >> 22`.

### Swift app (`App/`)
- `main.swift`, `AppDelegate.swift`: start the core, show login or the main window, start the importers, Spotlight and share support once connected; the Dock menu; `openChat(_:revealing:)` brings a chat forward.
- `MainMenu.swift`: menus (⌘N New Message, ⌘F finds a chat, ⌥⌘F Find in Chat, ⌘E Edit Message, ⌘L Like, ⌘1–⌘9 pick a chat, …).
- **`Core/`**
  - `CoreBridge.swift`: calls into Go; `log(...)` writes to `core.log` with `source=app`. `AppData.folder` is the data folder.
  - `Models.swift`: mirrors `Core/api.go`. `Attachment.Kind.label` names attachments ("Photo", "Voice Message").
  - `ChatStore.swift`: the app state, with coalesced change notifications; `waitUntilReady` for things that can launch the app.
  - `Notifier.swift`: notifications (messages, reactions), with Reply and Mark as Read.
  - `OutgoingMedia.swift`: the `outgoing/` staging folder, HEIC/TIFF → JPEG, compose thumbnails.
- **`Main/`**
  - `MainWindowController.swift` (window, toolbar, split view), `ChatWindowController.swift` (a chat in its own window), `ConversationListViewController.swift` (sidebar, filter, context menu), `NewMessageViewController.swift`.
  - `ChatViewController.swift`: a chat, by topic: the main file (state, rows, reload, table), `+Search`, `+Animations` (arriving, sliding rows, statuses, read pictures, typing → message), `+Scrolling`, `+MessageActions` (menus, tapbacks, selection, Quick Look), `+Compose`. `ChatSupportViews.swift`: the table, drop target, tapback picker.
  - Cells: `MessageCellView.swift` (a message, and the typing bubble), `Bubble.swift` (colors, `BubbleMetrics`, `BubbleView`), `MessageTextView.swift`, `MessageParts.swift` (reply quote and line, tapback badge), `AttachmentViews.swift` (attachments, link cards, dragging out), `ChatCaptionCells.swift` (times, statuses, restore prompt, read pictures).
  - `ComposeView.swift`, `ChatSearchBar.swift`, `ReactionMenuView.swift`, `MediaViewer.swift` (Quick Look).
- `Intents/`: App Intents entities (`MessagingIntents.swift`) and the Shortcuts actions (`ChatIntents.swift`).
- `Login/LoginWindowController.swift`: facebook.com login in a WKWebView; captures the cookies.
- `Util/`: `ImageCache`, `AvatarView`, `Formatters`, `LinkPreviews`, `ChatExport` (Markdown transcript), `SpotlightIndex`, `ShareSupport`, `DockBadge`, `ImageSize`, `Debouncer`, `ViewHelpers` (snapshots, fades, popovers, confirm alerts, `Facebook` URLs).
- **`WebSync/`**: the hidden web view.
  - `WebSyncController.swift`: a hidden `WKWebView` with a persistent data store (UUID `6F1C2B7E-4E1A-4C55-9B7A-2D0E7F9A1C31`). It **must use a Safari user agent** (a fake Chrome one broke the PIN restore). Embedded invisibly in the chat pane so WebKit doesn't throttle it. `withExclusiveAccess`, `navigate(toPath:)`, `evaluate`.
  - `WebChatImporter.swift`: at launch and every 10 minutes, reads the encrypted chats the web chat list shows at first; scrolling the sidebar to its bottom reads the web list's next page (`loadMore`), as on the web. The sidebar shows as many chats as the web list has loaded (`listedChats`; all of them while searching).
  - `WebHistoryImporter.swift`: when an encrypted 1:1 chat opens, scrolls its web chat back and collects messages, pictures, links and reactions.
  - `WebThemeReader.swift`: an encrypted chat's theme, from the web app.
  - `WebDOMInspector.swift`: dev hooks (`defaults write <bundle ID> WebDumpEnabled -bool YES`; `webeval.js` in the data folder runs in the page).
- `Shared/`: `ShareHandoff` (how the extension and the app talk), `RoundAvatar`. `ShareExtension/`: the Share menu's chat picker.

### Data on disk
`~/Library/Application Support/Hermes/`: `app.db`, `e2ee.db` (the whatsmeow device and keys; never commit it), `core.log` (zerolog JSON), `media/`, `outgoing/`, `linkpreviews/`.

The app used to be called MessengerMac (bundle ID `<prefix>.MessengerMac`). `App/Util/RenameMigration.swift` moves that name's data folder, web view data (the Messenger web login) and settings over on the first launch as Hermes.

## Feature status

Working:
- Login, live sync, all thread pages backfilled; group, 1:1 and encrypted chats.
- Text, replies, files and pictures, tapbacks, unsend, edit (with earlier versions), read receipts (pictures under the last seen message), typing, presence.
- Chat themes and quick reactions; link previews; dragging links and attachments out; Quick Look.
- Find in Chat (also fetching older history), Export Chat as Markdown.
- Chats in their own windows; Open on Web; mark read/unread, mute, delete, leave, block.
- Notifications with Reply and Mark as Read; read state from other devices; Dock badge and Dock menu.
- Shortcuts actions; messages in Spotlight; the share extension.
- Animations: arriving messages, the typing bubble turning into the message, rows sliding, read pictures moving.
- Encrypted history and themes via the web view, once the PIN has been entered there.

Known limitations:
- Siri can't send: Apple's messages-schema intents never received a recipient (macOS 27.1), so they were removed.
- Encrypted chats further down the web chat list are matched only once the sidebar is scrolled down to them.
- History import: about 400 messages per chat; preview-quality photos; no stickers, voice or video; 1:1 chats only.
- Opening a chat in the web view may mark it read on Messenger.
- Each picture is sent as its own message (no albums).
