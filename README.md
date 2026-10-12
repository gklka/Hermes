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
- **Bridge:** Swift calls `MMRequest(json)`, and Go replies through one callback with `{"type":"response"|"event", …}`. See `App/Core/CoreBridge.swift` and `Core/main.go`.

## Building

Requires Xcode 26+ and Go (`brew install go`). The "Build Go Core" phase runs `Support/build-core.sh`, which produces `Core/build/libmmcore.a` before Swift compiles.

## Limitations

- **E2EE history:** encrypted chats have no server-side history. Only messages received after this app registers as a device will appear.
- **New conversations:** starting a new conversation, calls and stories aren't implemented.
