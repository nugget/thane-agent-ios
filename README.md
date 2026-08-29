# thane-agent-ios

An App Store-oriented iPhone and iPad companion that makes operator-approved
iOS context available to [Thane](https://github.com/nugget/thane-ai-agent).

The app is a data bridge, not an iOS host for the Thane daemon. While active,
it connects to `/v1/realtime/ws`, authenticates as a platform provider, and
answers on-demand requests using public Apple APIs and iOS permission controls.

## Initial capabilities

- `ios.system-context` / `ios_system_context`: an operator-approved snapshot
  of regional settings, device state, and network-path state.
- `ios.location` / `ios_current_location`: a one-shot Core Location reading
  after the operator enables sharing and grants While Using authorization.

Every category defaults off. A connected Thane receives only categories the
operator enabled in the app. The app does not continuously track location,
does not request Always authorization, and does not claim persistent background
availability.

API tokens are stored in Keychain. Remote servers must use HTTPS; plaintext is
accepted only for simulator-friendly loopback development. TLS verification is
never disabled.

## Platform target

The deployment target is iOS 26.0. The initial providers need no iOS 27-only
API, so requiring iOS 27 would reduce reach without adding a capability. Patch
updates within iOS 26 remain supported normally.

## Build

Requires Xcode 26+ and [just](https://github.com/casey/just).

```bash
just ci
```

The test destination defaults to the iOS 26.5 `iPhone 17 Pro` simulator that
ships with the current Xcode 26.6 toolchain. Override it with
`IOS_SIMULATOR_DESTINATION` when needed.

## App Store posture

- iOS sandbox; no special entitlements or background modes.
- Public Core Location, Foundation, UIKit, Network, Security, and SwiftUI APIs.
- Foreground-only realtime service in this first slice.
- Purpose strings for location and local-network access.
- A bundled privacy manifest covering app preferences and the data categories
  the app can transmit to the operator's configured Thane instance.

App Store Connect privacy answers and a privacy-policy URL still need to be
completed before submission. A production app icon and store metadata are also
release prerequisites.

## Near-term data-source roadmap

The provider boundary is ready for separately reviewed, independently
authorized integrations such as Calendar, Contacts, Reminders, HealthKit,
Motion & Fitness, Photos, HomeKit, and Focus status. Each should land as a
focused capability with bounded queries and clear field-level disclosure; they
should not be bundled behind a single broad consent switch.
