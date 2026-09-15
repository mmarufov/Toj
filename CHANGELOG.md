# Changelog

All notable changes to Toj are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to a `MAJOR.MINOR.PATCH.BUILD` version scheme.

## [0.4.0.1] — 2026-08-29

### Fixed

- Made the search background-wake regression check synchronize with task retirement and enqueue
  its deep backlog atomically, preventing slow CI machines from reporting a false timeout.

## [0.4.0.0] — 2026-07-23

Adds one-to-one encrypted camera video calls on top of Toj's existing voice-call
handshake and recovery stack. Production enablement remains disabled until Apple
provisioning, APNs, two-region TURN capacity, and physical-device release gates pass.

### Added

- Authenticated media profile 2 with Opus audio, strict H264 video, transcript-bound
  DTLS fingerprints, permanent camera transceivers, and camera toggling without SDP
  renegotiation.
- Video-first and audio-first call flows, front/rear switching, local and remote
  renderers, Picture in Picture plumbing, CallKit video state, data-saver controls,
  and permission-safe camera lifecycle handling.
- Audio-priority network and thermal adaptation with high, medium, low, and automatic
  pause tiers driven by interval WebRTC statistics and encrypted peer receive caps.
- Device capability registration, immutable voice/video start intent, video-aware
  multi-device targeting, and lifecycle-only projections for losing ring targets.
- A public release report separating automated evidence from provisioning,
  infrastructure, and physical-device gates.

### Changed

- Renamed the concrete WebRTC implementation to `WebRTCCallEngine` and extended the
  injectable engine contract with one-shot media-profile configuration and independent
  renderer handles.
- Raised the coturn allocation starting cap to 512,000 bytes per second and added
  aggregate allocation, egress, and transport-probe alerts for video readiness.
- Backfilled retained calls in bounded transactions before enforcing the selected
  media-profile invariant, avoiding a long migration transaction on the calls table.
- Made the required iOS pull-request check download and attest the pinned WebRTC
  artifact, compile the real Release implementation, and run the signed test suite.

### Security

- Bound the original media offer, selected profile, call intent, and DTLS fingerprint
  into the existing encrypted call transcript and rejected signal-kind/SDP-type
  mismatches.
- Scoped call reads, events, active-call lists, WebSocket hints, and terminal cleanup
  to the initiating device and explicit ring targets; unrelated same-account devices
  receive no setup or encrypted signaling data.
- Prevented camera capture and permission prompts before authenticated acceptance,
  fenced late callbacks by call generation, and kept camera state encrypted from the
  server.
- Kept the restricted multitasking-camera entitlement opt-in so ordinary signed builds
  remain merge-safe until a matching Apple provisioning profile is available.

## [0.3.0.0] — 2026-07-19

Makes saved chats and downloaded media open immediately from encrypted local storage,
while keeping connectivity, catch-up, and media-transfer state accurate on weak networks.

### Added

- Local-first conversation snapshots, deterministic loading and empty states, prepared-chat
  caching, and UI fixtures that verify cold offline opening and rapid chat switching.
- Observable connectivity and sync coordination with independent probe/page deadlines,
  automatic path and WebSocket recovery, immediate retry, and network-sized difference pages.
- Durable encrypted photo and video representations, a shared decoded presentation cache,
  prepared local video assets, and a foreground scheduler that continuously drains visible media.
- Background refresh, processing, and media-session restoration with durable retry state and
  consistent cache clearing by chat or media type.
- Contacts, profile details, storage controls, privacy manifests, and privacy-safe performance
  signposts for local readiness, chat opening, sync, and media availability.

### Changed

- Cloud difference assembly now batches message, media, and reaction loading into a constant
  number of database queries while preserving the existing response contract.
- Existing voice-call startup, socket events, service rows, and privacy controls now coexist with
  local-first messaging after integrating the latest `main` branch.
- Downloaded media defaults to unlimited size and permanent retention unless the user has already
  chosen another policy or the low-disk safety reserve must reclaim space.

### Fixed

- Offline is shown only for genuine network loss; slow servers, expired sessions, protocol errors,
  configuration mistakes, and local-replica failures now remain distinct and recoverable.
- Chat navigation no longer publishes a blank timeline before SQLCipher returns the first snapshot.
- Media bubbles and fullscreen viewers reuse encrypted disk and decoded memory tiers instead of
  downloading or decoding the same resource again.

### Security

- Kept bearer credentials out of the durable background-transfer ledger and rejected cross-origin
  redirects for authenticated media requests.
- Removed OTP provider error text from server logs so adapter failures cannot expose phone numbers,
  verification codes, or provider-specific request details.

## [0.2.0.0] — 2026-07-18

Prepares encrypted one-to-one iOS voice calls for an Apple Developer and
infrastructure-gated rollout. Calling remains unavailable until APNs, TURN, the
pinned WebRTC artifact, and the explicit production readiness flags are present.

### Added

- CallKit and PushKit lifecycle integration, encrypted signaling, X25519 call-key
  agreement, DTLS fingerprint commitments, multi-device first-answer-wins, call
  history, and privacy-preserving quality buckets.
- PostgreSQL call control, durable call/history/push outboxes, abuse limits,
  block enforcement, atomic session revocation, and bounded cleanup.
- A pinned WebRTC XCFramework build and immutable-release workflow with checksum,
  SBOM, slice, symbol, and provenance verification.
- Hardened coturn deployment templates, relay peer-policy validation, operational
  gates, and explicit Apple/APNs/TURN follow-up checklists.
- Required backend, signed iOS simulator, and repository-policy CI checks.

### Security

- Serialized blocking, message, call, and invite-budget mutations to close
  cross-request races.
- Restricted telemetry to call-owning devices and made reports idempotent.
- Protected generated call-history identifiers from client-controlled UUIDs and
  retained terminal calls until history delivery succeeds.
- Added safe concurrent production indexes and retry repair for interrupted index
  builds.

## [0.1.1.0] — 2026-07-13

Premium-black design pass. Keeps Toj's black identity (X/Grok-grade minimalism)
while borrowing how Telegram executes iOS 26 Liquid Glass, and elevates gold into
the signature interactive accent.

### Added
- **Design tokens** in `TojTheme.swift`: semantic accent colors
  (`accent`, `onAccent`, `danger`, `hairline`, `bubbleMine`), a `TojSpacing` scale,
  and a `TojRadius` scale.
- **Reusable components**: `TojPressableStyle` (`.buttonStyle(.tojPressable)` reactive
  press feedback), `TojGlassIconButton`, `TojNavHeader`, `TojIconTile`, `TojSectionCard`,
  and `TojPillFilter`.
- **Chat folder filter** (All / Unread / Pinned) on the chat list.

### Changed
- Gold is now the signature interactive accent: send button, primary CTAs, active
  unread badges, and selected pills. White stays neutral, green stays encryption.
- Chat list, conversation, settings, profile, and auth restyled onto the shared header,
  section-card, icon-tile, and pill components with consistent tokens and press feedback.
- Outgoing message bubbles use a premium graphite fill with a faint gold hairline;
  muted chats show a gray unread badge instead of gold.

### Removed
- Dead `CloudConversationView` / `CloudBubble`, superseded by
  `TojConversationExperience` / `TojMessageBubble`.

## [0.1.0.0] — 2026-07-12

First versioned release. Establishes the visual identity, design system, and
messaging presentation layer on top of the milestone M1–M4 cloud skeleton.

### Added
- **Design system** (`Toj/DesignSystem/TojTheme.swift`, `docs/design-system.md`): black-only
  interface with matte conversation content, floating Liquid Glass controls, a
  restrained crown mark, and a documented color, typography, spacing, and motion
  language.
- **Onest typeface** bundled for brand and large headings
  (`Toj/Resources/Fonts/`), with native iOS text styles for dense content.
- **App icons** for light, dark, and tinted appearances.
- **Messaging presentation layer** (`Toj/Features/Cloud/MessagingPresentation.swift`)
  with unit coverage (`TojTests/MessagingPresentationTests.swift`).
- **Conversation experience** and rich demo surfaces
  (`Toj/Features/Cloud/ConversationExperience.swift`, `RichDemoSurfaces.swift`).
- **Localization** via `Toj/Localizable.xcstrings` for a Tajik-first UI.

### Changed
- Overhauled the cloud chat UI and view model (`CloudRootView.swift`,
  `CloudAppModel.swift`) to adopt the new design system.
- Refined local store handling and its tests (`CloudLocalStore.swift`,
  `CloudLocalStoreTests.swift`).
- Updated project configuration, Info.plist, and prep tooling to bundle fonts,
  icons, and localized resources.

[0.4.0.0]: https://github.com/mmarufov/tojmessanger/releases/tag/v0.4.0.0
[0.3.0.0]: https://github.com/mmarufov/tojmessanger/releases/tag/v0.3.0.0
[0.2.0.0]: https://github.com/mmarufov/tojmessanger/releases/tag/v0.2.0.0
[0.1.1.0]: https://github.com/mmarufov/tojmessanger/releases/tag/v0.1.1.0
[0.1.0.0]: https://github.com/mmarufov/tojmessanger/releases/tag/v0.1.0.0
