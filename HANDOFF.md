# MessengerMac — handoff notes for Claude

This file lets a new Claude Code session pick up this project on another machine. Read it fully before making changes.

## What this is

A personal, learning-purpose native macOS client for **Facebook Messenger**. Owner's brief: "a native macOS app, just for myself, for learning purposes… it has to look similar to the Apple Messages app, but support the features of the FB network."

- UI: **AppKit** (no SwiftUI), styled like Apple Messages.
- Backend: a **Go core** wrapping [`go.mau.fi/mautrix-meta`](https://github.com/mautrix/meta) `pkg/messagix` (Facebook web protocol, LightSpeed over MQTT/WebSocket), plus `whatsmeow` for end-to-end encrypted chats. It's built as a static c-archive and linked into the app.
- Owner's choices: "Go core + Swift UI" over pure Swift or a web wrapper; a **plain .xcodeproj** (not XcodeGen).

## How the user wants you to work

These come from the user's global `~/.claude/CLAUDE.md` plus feedback given during the project. Recreate them in memory on the new machine.

- Keep answers **short and easy to understand**.
- **Don't commit or push** unless explicitly asked.
- **Always edit files with Edit/Write**, never sed/perl/heredocs in Bash. The user wants inline diffs.
- Be careful with debug logs: no force-unwraps, and only log values that are actually accessible.
- **For this project: always build and relaunch the app after every change**, without asking. This overrides the global "don't build automatically" rule. But don't relaunch while the user is actively using the app for something long-running, such as an import. Once a relaunch interrupted an import.
- **Off-limits:** don't help reverse-engineer Meta's PIN-protected encrypted backup ("Labyrinth"). That was declined. The hidden-WebView approach below is what the user chose instead.

## Setting up on a new machine

1. Install Xcode 26+ and Go (`brew install go`). `Support/build-core.sh` adds `/opt/homebrew/bin` and `/usr/local/go/bin` to `PATH`.
2. Build:
   ```sh
   cd MessengerMac
   # Only needed if Xcode isn't the selected developer dir (old machine: "/Applications/Xcode 27.1.app")
   export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
   xcodebuild -project MessengerMac.xcodeproj -scheme MessengerMac -configuration Debug -derivedDataPath build/DerivedData build
   ```
3. Run: `open build/DerivedData/Build/Products/Debug/MessengerMac.app`. Quit with `pkill -x MessengerMac`.
   - Day to day, use `Support/install.sh` instead: it builds Release, installs it to `/Applications` and relaunches it. Siri and Shortcuts only work with a team-signed app (the project signs with the personal team `ZWNU8P9B33`) and get confused by several registered copies, so the script unregisters the build-folder ones.
4. Run Go tests:
   ```sh
   cd Core && CC="xcrun --sdk macosx clang" go test -run 'TestParseAge|TestAvatarKey|TestWebMessageID' .
   ```
5. The first launch shows facebook.com login in a web view. The app then registers itself as a new E2EE device, and the user must restore encrypted chats with their PIN once ("Restore Encrypted Chats…", see below).
   - Optional: copy `~/Library/Application Support/MessengerMac/` from the old machine to keep the local database. A fresh login is simpler and safer, though.

Signing is ad-hoc (`CODE_SIGN_IDENTITY = "-"`), so no team is needed. The bundle ID is `com.kristofgruber.MessengerMac`.

## Architecture

```
AppKit UI (App/)  ──JSON-RPC over C calls──▶  Go core (Core/ → Core/build/libmmcore.a)
                                              ├─ messagix  → facebook.com (threads, messages, contacts)
                                              └─ whatsmeow → E2EE chats (Signal protocol)
Hidden WKWebView (App/WebSync/) → facebook.com/messages, to read E2EE history the web app has restored
```

### Xcode and build plumbing
- `MessengerMac.xcodeproj`: objectVersion 77 with **synchronized folder groups**, so new files in `App/` are picked up automatically.
- The "Build Go Core" build phase runs `Support/build-core.sh`. It builds the c-archive per arch and lipos the result into `Core/build/libmmcore.a` and `.h`.
  - It uses `CC="xcrun --sdk macosx clang"` because the old Xcode path contained a space.
- Bridging header: `Support/MessengerMac-Bridging-Header.h`.
- `SWIFT_VERSION` is 5, and **default actor isolation is MainActor**. Off-main helpers must be marked `nonisolated`; see `OutgoingMedia.prepare`.
- SourceKit "Cannot find type … in scope" diagnostics are cross-file indexing noise. Trust `xcodebuild`.

### Go core (`Core/`)
- `go.mod` has a replace directive: `github.com/imroc/req/v3 => github.com/beeper/req/v3 …`.
- `main.go`:
  - cgo exports `MMStart` and `MMRequest`.
  - Responses and events go back through one callback (`emitEvent` / `emitResponse`).
- `api.go`: JSON types. **These must stay in sync with `App/Core/Models.swift`.**
- `store.go`:
  - SQLite (modernc). Tables: kv, contacts, threads, participants, messages, reactions.
  - `threadRow.Visible()` decides what shows in the chat list. It hides requests, filtered ("other") and spam threads, plus folder pseudo-threads.
  - `SearchContacts` lives here too.
- `core.go`:
  - Login, connect and logout (platform `types.Facebook`).
  - E2EE device registration.
  - `handleMetaEvent`, which calls `backfillThreads` after the connection is up.
- `meta.go`:
  - `handleTable` processes the LightSpeed sync tables.
  - Hybrid FB-key↔JID thread mapping.
  - `flush` emits `thread`/`message` events. It emits `threadRemoved` for threads that aren't visible.
  - Pending sends.
- `e2ee.go`: whatsmeow events (FBMessage, receipts, typing).
- `actions.go`:
  - The RPC dispatch.
  - Thread paging over sync groups 1 and 95.
  - Send, sendMedia, react, unsend, markRead, typing and media download.
  - `threads.open` and `contacts.search`.
  - `web.*` import RPCs.
  - Sends go through a serial `sendQueue`, so order is preserved.
- `webimport.go`:
  - Turns chats and messages scraped from the web view into DB rows.
  - Keys `webmap:<webID>` / `webid:<userID>` map web chats to user IDs.
  - A message timestamp is `messageID >> 22`.
- `webimport_test.go`: tests for the import helpers.

### Swift app (`App/`)
- `main.swift` and `AppDelegate.swift`: start the core, show login or the main window, and start `WebChatImporter` once connected. The menu item "Restore Encrypted Chats…" shows the web view.
- `MainMenu.swift`: menus. File → New Message is ⌘N.
- **`Core/`**
  - `CoreBridge.swift`: calls into Go. Its `log(...)` writes to `core.log` with `source=app`.
  - `Models.swift`
  - `ChatStore.swift`: the app state, with coalesced change notifications. `send(text:attachments:…)` sends each attachment first, then the text.
  - `OutgoingMedia.swift`:
    - Staging folder `outgoing/`.
    - Converts HEIC/TIFF/etc. to JPEG.
    - Compose thumbnails.
    - The `ComposeAttachment` text attachment.
- **`Main/`**
  - `MainWindowController.swift`:
    - Toolbar with the filter menu (All / Messages / Marketplace) and New Message.
    - `MainSplitViewController` persists the sidebar width (UserDefaults `SidebarWidth`).
  - `ConversationListViewController.swift`: sidebar list, search, and `ConversationFilter` (UserDefaults `ConversationFilter`).
  - `ChatViewController.swift`:
    - The message table.
    - Per-chat drafts as `NSAttributedString`.
    - Drop target.
    - Reply, tapback and unsend.
    - Triggers the web history import for E2EE chats.
  - `MessageCells.swift`: bubbles. Message text is a `MessageTextView` (`NSTextView`) so link colours can be set per bubble.
  - `ComposeView.swift`:
    - iMessage-style input. Images and files are staged inline as thumbnails, via paste, drag (Finder, Photos, Safari file promises) or the + button.
    - Return sends.
  - `NewMessageViewController.swift`: contact picker.
- `Login/LoginWindowController.swift`: facebook.com login in a WKWebView. It captures the cookies.
- `Util/`: `ImageCache`, `AvatarView`, `Formatters`.
- **`WebSync/`**: E2EE history via a hidden web view.
  - `WebSyncController.swift`:
    - A hidden `WKWebView` with a persistent data store, UUID `6F1C2B7E-4E1A-4C55-9B7A-2D0E7F9A1C31`.
    - It **must use a Safari user agent**. A fake Chrome UA broke the PIN restore.
    - Web data is reset once via the `WebDataVersion` default (currently 2).
    - It's embedded invisibly (alpha 0) in the chat pane so WebKit doesn't throttle it.
    - `withExclusiveAccess`, `navigate(toPath:)` and `evaluate` (`.page` world).
  - `WebChatImporter.swift`: every 10 minutes, reads the E2EE rows from the web chat list. It resolves unmatched rows by clicking them.
  - `WebHistoryImporter.swift`: when an E2EE 1:1 chat is opened, scrolls the web chat back (up to 400 messages). It collects `data-message-id` (`<user>@msgr.<msgID>`), direction, text and images of 60px or more as base64.
  - `WebDOMInspector.swift` (dev hooks, enabled with `defaults write com.kristofgruber.MessengerMac WebDumpEnabled -bool YES`):
    - `webeval.js` in the data dir runs in the page and writes `webeval.out`.
    - `importthread.txt` triggers a history import.
    - `webdump.json`.

### Data on disk
`~/Library/Application Support/MessengerMac/`:
- `app.db`
- `e2ee.db`: the whatsmeow device and keys. Never commit it.
- `core.log`: zerolog JSON.
- `media/`
- `outgoing/`

## Feature status

Working:
- Login, live sync, all thread pages backfilled.
- Group and 1:1 chats, E2EE chats.
- Sending text, replies, reactions/tapbacks, unsend, read receipts, typing.
- Links coloured correctly in both bubble colours.
- New Message (contact search), ⌘N.
- Spam, filtered and request chats hidden.
- Sidebar filter: All / Messages / Marketplace.
- Sidebar width remembered.
- E2EE history via the web view, once the PIN has been entered there (done on the old machine; it must be redone on the new one).
- iMessage-style image and file sending. Built, but **not yet confirmed by the user** at handoff time.

Known limitations and ideas the user hasn't decided on yet:
- The web chat list renders only about 14 rows and can't be scrolled programmatically, so only recent E2EE chats are matched.
- History import:
  - Capped at 400 messages per chat.
  - Only text and preview-quality photos; no stickers, voice or video yet.
  - Only 1:1 chats, not E2EE groups.
- Opening a chat in the web view may mark it read on Messenger.
- The dev hooks are still enabled. I offered to disable them.
- Image sending sends each image as a separate message. Messenger's multi-image albums aren't used yet.
