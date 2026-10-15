# Hermes

An unofficial, learning-purpose macOS client for Facebook Messenger with a native AppKit UI modeled on Apple's Messages.

> **Not affiliated with Meta.** This is an independent project. It is not made, endorsed or supported by Meta Platforms, Inc. Facebook, Messenger and their logos are trademarks of Meta Platforms, Inc.

<p align="center"><img src="docs/screenshot.png" alt="Hermes showing a chat list and a conversation with a link preview, a tapback and the typing bubble" width="760"></p>

## Features

### A real Mac app

No Electron and no web page in a window. Hermes is written in Swift with AppKit, and looks and behaves like Apple's Messages:

- **Native UI:** Liquid Glass toolbar and compose field, a source-list sidebar, Messages-style bubbles, tapbacks and read pictures.
- **Mac conventions:** full menus and keyboard shortcuts (⌘1–⌘9 pick a chat, ⌘F, ⌥⌘F Find in Chat, ⌘E Edit, ⌘L Like…), chats in their own windows, drag and drop, Quick Look, a Dock badge and Dock menu.
- **System integration:** notifications with Reply and Mark as Read, Shortcuts actions, messages in Spotlight, and a Share extension.
- **Smooth animations:** arriving messages, the typing bubble turning into the message, rows sliding and read pictures moving.
- **Light and dark mode,** and each chat's Messenger theme colors.
- **Fast:** messages are stored locally, so chats open instantly.

### Messenger

- 1:1, group and end-to-end encrypted chats, with live sync and full history.
- Text, replies, pictures and files, link previews, tapbacks and quick reactions.
- Edit (with earlier versions) and unsend, typing indicators, read receipts and presence.
- Find in Chat (also fetching older history) and Export Chat as Markdown.
- Start chats with anyone on Messenger, see a group's members, mute, mark read or unread, delete, leave and block.
- Encrypted chats' history and themes, read from Messenger's own web app once you've restored it with your PIN.

## Before you use it

- **It may break Facebook's Terms.** Meta's [Terms of Service](https://www.facebook.com/terms.php) don't allow accessing their products by automated means or with unofficial tools without their permission. Meta can restrict, suspend or disable an account it believes breaks its terms.
- **Your account is your responsibility.** Use it only with an account you're willing to risk. Nothing here is a promise that it's safe to use.
- **No warranty.** It's provided as is (see the license): it can stop working at any time if Meta changes its service, lose or misshow messages, or fail to deliver them. Don't rely on it for anything important.
- **Your data stays on your Mac.** Messages, keys and session cookies are stored in `~/Library/Application Support/Hermes/` and go only to Meta's servers. Keep that folder private: anyone with it can use your session.

## How it works

```
AppKit UI (App/)  ──JSON over C calls──▶  Go core (Core/, static lib)
                                          ├─ messagix  → facebook.com web protocol (MQTT/LightSpeed over WebSocket)
                                          └─ whatsmeow → end-to-end encrypted chats (Signal protocol)
```

- **Login:** a WKWebView shows facebook.com's own login page. Once the `c_user` and `xs` cookies exist, they're passed to the core.
- **Core:** it uses [mautrix-meta](https://github.com/mautrix/meta)'s `messagix` package as a library and stores threads and messages in `~/Library/Application Support/Hermes/app.db`. E2EE keys are in `e2ee.db`, and logs are in `core.log`.
- **Bridge:** Swift calls `MMRequest(json)`, and Go replies through one callback with `{"type":"response"|"event", …}`. See `App/Core/CoreBridge.swift`, `Core/main.go` and `Core/rpc.go`.
- **Encrypted history:** Messenger keeps it in a PIN-protected backup. A hidden web view runs Messenger's own web app, where you restore it once; the app reads the history and themes from there.

## Building

Requires Xcode 26+ and Go (`brew install go`).

1. Create `Support/Signing.local.xcconfig` with your own bundle ID prefix and Apple developer team (see `Support/Signing.xcconfig`).
2. Build the `Hermes` scheme. The "Build Go Core" phase runs `Support/build-core.sh`, which produces `Core/build/libmmcore.a` before Swift compiles.
3. `Support/install.sh` builds Release and installs it to `/Applications` (Shortcuts and Spotlight need the installed, team-signed copy).

See `HANDOFF.md` for the architecture and the file layout.

## Limitations

- Calls and stories aren't implemented.
- Siri can't send messages (Apple's messages schema didn't hand the app a recipient).
- Encrypted history comes from the web app, 400 messages at a time (more as you scroll up), so it's slow to go far back.

## License

Hermes is free software, licensed under the [GNU Affero General Public License v3.0](LICENSE) (AGPL-3.0). It has to be: it's built on [mautrix-meta](https://github.com/mautrix/meta), which is AGPL-3.0. If you distribute it or a modified version, you must make the source available under the same license.

It also uses [whatsmeow](https://github.com/tulir/whatsmeow) and [go.mau.fi/util](https://github.com/mautrix/go-util) (Mozilla Public License 2.0), and other Go modules under their own licenses (see `Core/go.mod`).

This program is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU Affero General Public License for more details.
