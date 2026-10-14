# MessengerMac

A personal, learning-purpose macOS client for Facebook Messenger with a native AppKit UI modeled on Apple's Messages.

## How it works

```
AppKit UI (App/)  ──JSON over C calls──▶  Go core (Core/, static lib)
                                          ├─ messagix  → facebook.com web protocol (MQTT/LightSpeed over WebSocket)
                                          └─ whatsmeow → end-to-end encrypted chats (Signal protocol)
```

- **Login:** a WKWebView shows facebook.com's own login page. Once the `c_user` and `xs` cookies exist, they're passed to the core.
- **Core:** it uses [mautrix-meta](https://github.com/mautrix/meta)'s `messagix` package (AGPL-3.0) as a library and stores threads and messages in `~/Library/Application Support/MessengerMac/app.db`. E2EE keys are in `e2ee.db`, and logs are in `core.log`.
- **Bridge:** Swift calls `MMRequest(json)`, and Go replies through one callback with `{"type":"response"|"event", …}`. See `App/Core/CoreBridge.swift`, `Core/main.go` and `Core/rpc.go`.
- **Encrypted history:** Messenger keeps it in a PIN-protected backup. A hidden web view runs Messenger's own web app, where you restore it once; the app reads the history and themes from there.

## Building

Requires Xcode 26+ and Go (`brew install go`). The "Build Go Core" phase runs `Support/build-core.sh`, which produces `Core/build/libmmcore.a` before Swift compiles. `Support/install.sh` builds Release and installs it to `/Applications` (Shortcuts and Spotlight need the installed, team-signed copy).

See `HANDOFF.md` for the architecture and the file layout.

## Limitations

- Calls and stories aren't implemented.
- Siri can't send messages (Apple's messages schema didn't hand the app a recipient).
- Encrypted history comes from the web app, so it's limited to what it shows: recent chats, about 400 messages each.
