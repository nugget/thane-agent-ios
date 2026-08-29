# AGENTS.md

`thane-agent-ios` is the sandboxed iOS companion for
[Thane](https://github.com/nugget/thane-ai-agent). It connects to a Thane
instance using the authenticated realtime platform-provider protocol and
exposes operator-approved Apple platform data through public iOS APIs.

## Build and test

Use `just` for every workflow. Never invoke `xcodebuild` directly when a
recipe exists.

```bash
just build
just test
just ci
```

`just ci` is mandatory before every push.

## Conventions

- Swift 6 with strict concurrency, SwiftUI, and `@Observable`.
- iOS 26.0 is the deployment target. Do not raise it without a capability
  that cannot be implemented on iOS 26.
- Use Apple system frameworks only. Discuss any third-party dependency first.
- Treat the app as a remote companion. iOS cannot supervise or execute the
  Thane daemon.
- Keep all platform data independently opt-in and default-off. Permission
  prompts must result from a visible operator action, never a remote request.
- Send data only over the authenticated Thane connection. Never disable TLS
  verification, log tokens, or store tokens outside Keychain.
- Do not imply continuous background availability. The realtime provider is
  available while the app is active; add background modes only for their
  documented purpose and with a concrete product requirement.
- Use `os.Logger` with subsystem `info.nugget.thane-agent-ios`. No `print()`.
- Add usage descriptions, privacy-manifest declarations, UI disclosure, and
  tests in the same change as each new data source.
- Keep App Store Review Guidelines and least-privilege entitlement use in the
  design path. Avoid restricted entitlements unless the feature depends on
  one and the distribution case is documented.

## Architecture

- `App/` owns SwiftUI lifecycle, operator UI, and `AppState`.
- `Connection/` implements the `/v1/realtime/ws` platform protocol and routes
  server requests to registered capabilities.
- `Platform/` owns public-API data providers. Providers return on-demand
  snapshots and enforce local disclosure settings before reading data.
- `Settings/` persists non-secret operator choices in app-only UserDefaults.
- `Security/` stores the API token in Keychain.
