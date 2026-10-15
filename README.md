# MessengerMac

An unofficial, learning-purpose macOS client for Facebook Messenger with a native AppKit UI modeled on Apple's Messages.

> **Not affiliated with Meta.** This is an independent project. It is not made, endorsed or supported by Meta Platforms, Inc. Facebook, Messenger and their logos are trademarks of Meta Platforms, Inc.

## Before you use it

- **It may break Facebook's Terms.** Meta's [Terms of Service](https://www.facebook.com/terms.php) don't allow accessing their products by automated means or with unofficial tools without their permission. Meta can restrict, suspend or disable an account it believes breaks its terms.
- **Your account is your responsibility.** Use it only with an account you're willing to risk. Nothing here is a promise that it's safe to use.
- **No warranty.** It's provided as is (see the license): it can stop working at any time if Meta changes its service, lose or misshow messages, or fail to deliver them. Don't rely on it for anything important.
- **Your data stays on your Mac.** Messages, keys and session cookies are stored in `~/Library/Application Support/MessengerMac/` and go only to Meta's servers. Keep that folder private: anyone with it can use your session.

## How it works

```
AppKit UI (App/)  ──JSON over C calls──▶  Go core (Core/, static lib)
                                          ├─ messagix  → facebook.com web protocol (MQTT/LightSpeed over WebSocket)
                                          └─ whatsmeow → end-to-end encrypted chats (Signal protocol)
```

- **Login:** a WKWebView shows facebook.com's own login page. Once the `c_user` and `xs` cookies exist, they're passed to the core.
- **Core:** it uses [mautrix-meta](https://github.com/mautrix/meta)'s `messagix` package as a library and stores threads and messages in `~/Library/Application Support/MessengerMac/app.db`. E2EE keys are in `e2ee.db`, and logs are in `core.log`.
- **Bridge:** Swift calls `MMRequest(json)`, and Go replies through one callback with `{"type":"response"|"event", …}`. See `App/Core/CoreBridge.swift`, `Core/main.go` and `Core/rpc.go`.
- **Encrypted history:** Messenger keeps it in a PIN-protected backup. A hidden web view runs Messenger's own web app, where you restore it once; the app reads the history and themes from there.

## Building

Requires Xcode 26+ and Go (`brew install go`).

1. Create `Support/Signing.local.xcconfig` with your own bundle ID prefix and Apple developer team (see `Support/Signing.xcconfig`).
2. Build the `MessengerMac` scheme. The "Build Go Core" phase runs `Support/build-core.sh`, which produces `Core/build/libmmcore.a` before Swift compiles.
3. `Support/install.sh` builds Release and installs it to `/Applications` (Shortcuts and Spotlight need the installed, team-signed copy).

See `HANDOFF.md` for the architecture and the file layout.

## Limitations

- Calls and stories aren't implemented.
- Siri can't send messages (Apple's messages schema didn't hand the app a recipient).
- Encrypted history comes from the web app, so it's limited to what it shows: recent chats, about 400 messages each.

## License

MessengerMac is free software, licensed under the [GNU Affero General Public License v3.0](LICENSE) (AGPL-3.0). It has to be: it's built on [mautrix-meta](https://github.com/mautrix/meta), which is AGPL-3.0. If you distribute it or a modified version, you must make the source available under the same license.

It also uses [whatsmeow](https://github.com/tulir/whatsmeow) and [go.mau.fi/util](https://github.com/mautrix/go-util) (Mozilla Public License 2.0), and other Go modules under their own licenses (see `Core/go.mod`).

This program is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU Affero General Public License for more details.
