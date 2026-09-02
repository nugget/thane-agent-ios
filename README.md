# thane-agent-ios

An App Store-oriented iPhone and iPad companion that makes operator-approved
iOS context available to [Thane](https://github.com/nugget/thane-ai-agent).

The app is a data bridge, not an iOS host for the Thane daemon. While active,
it connects to `/v1/realtime/ws`, authenticates as a platform provider, and
answers on-demand requests using public Apple APIs and iOS permission controls.
It can also make short authenticated HTTPS uploads from a durable latest-value
outbox when an opted-in system event gives it background execution time.

## Initial capabilities

- `ios.system-context` / `ios_system_context`: an operator-approved snapshot
  of regional settings, device state, and network-path state.
- `ios.location` / `ios_current_location`: a one-shot Core Location reading
  after the operator enables sharing and grants While Using authorization.
- `ios.location` background observations: optional significant-change updates
  after a separate in-app opt-in and Always authorization. iOS, not Thane,
  decides when those events are delivered.
- `ios.photos` / `ios_recent_photos`: a bounded list of recent visible-photo
  metadata after a separate in-app opt-in and Photos authorization. It includes
  PhotoKit dates, dimensions, favorite state, saved location, and selected
  EXIF/TIFF camera fields when the original is already local. It never returns
  pixels, hidden assets, raw PhotoKit identifiers, or downloads from iCloud.

Every category defaults off. A connected Thane receives only categories the
operator enabled in the app. Background events are coalesced by kind, protected
with iOS file protection, and removed only after Thane accepts them. The app
does not continuously track location or claim persistent background
availability; its realtime tools remain foreground-only.

The adaptive app shell separates routine operation from configuration:

- **Thane** shows the presented cryptographic identity, live/background
  availability, and observation-delivery state.
- **Context** owns local disclosure choices and Apple permission state.
- **Settings** owns credentials, connection controls, and diagnostics.

The app reads authenticated `GET /v1/identity` evidence from the configured
Thane and exposes its stable identifier, public fingerprints, core revisions,
anchor posture, and local verification results. This first identity surface is
deliberately presentation-only: it does not yet pin the identity or turn the
server's evidence into an independent trust verdict.

API tokens are stored in Keychain. Remote servers must use HTTPS; plaintext is
accepted only for simulator-friendly loopback development. TLS verification is
never disabled.

## App links

The initial `thane://` routes are read-only and versioned. They carry bounded
routing identifiers only:

- `thane://v1/agents/<thane-identity-id>`
- `thane://v1/agents/<thane-identity-id>/conversations`
- `thane://v1/agents/<thane-identity-id>/conversations/<conversation-id>`
- `thane://v1/agents/<thane-identity-id>/inbox`
- `thane://v1/agents/<thane-identity-id>/inbox/<item-id>`

Reserved characters in identifiers must be percent encoded. The app rejects
unknown versions and destinations, credentials, ports, query strings,
fragments, oversized values, and non-identifier payloads. A route opens only
when its exact Thane identity is active; mismatches show both identities for
operator inspection without switching agents or disclosing destination data.

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

- iOS sandbox with the standard `location` background mode solely for the
  separately enabled significant-change location feature.
- Public Core Location, Foundation, UIKit, Network, Security, and SwiftUI APIs.
- Foreground-only realtime service plus best-effort significant-change
  background location publication.
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

The broader identity-first product arc is tracked in
[roadmap issue #8](https://github.com/nugget/thane-agent-ios/issues/8), including
identity continuity, typed URL handling, notifications and inbox, and a
protocol-neutral conversation surface. Conversation transport and synchronized
history remain server-owned future work under
[thane-ai-agent issue #1502](https://github.com/nugget/thane-ai-agent/issues/1502);
Signal remains the operator communication channel in the meantime.
