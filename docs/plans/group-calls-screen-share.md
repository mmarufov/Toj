# Toj group calls and screen sharing

Status: repository implementation complete behind disabled, fail-closed release gates. This
document is the security and operations contract for the code; it is not a claim that external
SFU capacity, Apple provisioning, or physical-device certification has already happened.

## Product boundary

- One active interactive call per group.
- Up to 32 joined devices, 16 simultaneous camera publishers, one screen-share publisher, and
  nine ordinary video subscriptions per phone. The active screen share is always subscribed.
- Voice-first and video-first starts. Everyone joins muted with camera and screen capture off.
- Group members may start and join. Owners/admins may end the room or remove a participant.
- Screen sharing is full-device capture through a ReplayKit Broadcast Upload Extension. In-app
  capture is not presented as full-device sharing.
- 1:1 calls keep the existing `WebRTCCallEngine`; group calls use a separate namespaced SFU SDK.

## Media and trust topology

```text
Toj control plane ── authorizes membership, devices, room lifecycle, epochs, short-lived tokens
       │
       ├── stores only participant public key packages and opaque epoch-key envelopes
       │
iPhone ├── frame-encrypts audio/video/screen frames before transport
       │
       └─────────────── DTLS-SRTP ── SFU ── DTLS-SRTP ─────────────── iPhone
                                      │
                                      └── sees routing metadata, never plaintext media or epoch keys
```

An SFU is required for predictable battery, uplink, and large-room behavior. Full mesh is not a
supported fallback. The SFU SDK is LiveKit Swift `2.13.0`, whose WebRTC symbols are prefixed and
can coexist with Toj's pinned 1:1 WebRTC XCFramework. Toj enables the SDK's frame cryptor before
joining a room. DTLS-SRTP alone is never reported as group-call E2EE.

The control plane issues a five-minute room-scoped JWT. It never sends the LiveKit API secret to a
client. Tokens deny room creation, administration, hidden participants, ingress, recording, data
channels, and arbitrary room selection. A participant identity is a call-local random identifier,
not an account or phone identifier.

## Epoch protocol

Each joined device creates a fresh X25519 public key package for this call. The current key leader
generates a random 256-bit media key and uploads one authenticated encrypted envelope for every
other active device. Envelope additional authenticated data binds:

1. protocol version;
2. call and group identifiers;
3. media epoch and membership revision;
4. leader and recipient device identifiers;
5. both ephemeral public keys; and
6. the sorted active participant/device set.

The server validates exact envelope coverage, uniqueness, sizes, leader ownership, and the current
membership revision atomically, but cannot decrypt an envelope. Joining, leaving, removal, device
revocation, and leader replacement increment the membership revision and require a new epoch.
Clients install the next epoch before publishing. The prior epoch is accepted for at most ten
seconds to drain reordered packets, then erased. A pending joiner receives no SFU credential until
an envelope for the current epoch exists.

Every participant derives the displayed security emoji from the canonical participant-key and
epoch-commitment transcript. Comparing the emoji out of band can detect an equivocating control
plane. The in-call E2EE indicator means the authenticated epoch transcript and media cryptors have
passed their checks; it is not a human-identity or device-transparency assertion. Toj does not
claim identity transparency until a separately audited device-key transparency service ships.

## Quality and lifecycle

- Adaptive stream, dynacast, simulcast, and selective subscription are mandatory.
- Camera layers: 180p/15, 360p/24, and 720p/30. The dominant tile may receive 720p; thumbnails are
  capped at 360p or 180p. Screen share targets 1080p/15 with detail optimization.
- Audio has priority over camera and screen media. Congestion first drops remote thumbnail layers,
  then the local camera tier, then pauses camera. Screen share keeps a readable low layer while
  audio remains viable.
- A generation-fenced reducer owns camera intent, app state, thermal pressure, system pressure,
  network policy, secure-media readiness, and capture permissions. Server leases and the owning
  coordinator generation fence screen-share activation and teardown.
- A minimal ReplayKit Broadcast Upload Extension delegates sample handling to the pinned LiveKit
  broadcast handler. Toj separately generation-fences the activation permission, uses a renewable
  server lease for the single authorized publisher, rejects tracks from publishers absent from the
  authenticated room snapshot, and stops the SDK capture path on leave/end.
- No microphone, camera, or screen capture starts before an explicit join/CallKit accept action.
  A killed/background launch never prompts for capture permission.

## Fail-closed rollout

The server advertises `group_calls_v1`, `group_video_calls_v1`, and `screen_sharing_v1` only when
all applicable checks pass:

- `TOJ_GROUPS_V1_ENABLED=1`
- `TOJ_GROUP_CALLS_ENABLED=1`
- `TOJ_GROUP_CALLS_SFU_READY=1`
- `TOJ_GROUP_CALLS_E2EE_REQUIRED=1`
- valid HTTPS/WSS LiveKit URL plus non-placeholder API key and secret
- complete group-call database schema
- account allowlist or stable percentage rollout selection

The client advertises group media only when the pinned SDK imports, frame cryptor construction
succeeds, and ReplayKit/app-group prerequisites are present. Missing capabilities hide start/join
actions. Rollback sets rollout to zero: no new start or join is admitted. Already joined
participants may renew five-minute credentials and remain until the room ends or the normal stale
participant/room lifecycle removes them; administrators can still end the room. This preserves
active calls without pretending the rollout switch is an emergency media-disconnect control.

Stages are internal accounts, 5% for 48 hours, 25% for 72 hours, then 100%. Advancement requires
all of the following:

- no regression over 0.5 percentage points in 1:1 call success and no more than 5% regression in
  1:1 setup p95;
- group join-to-audio p95 at or below 3 seconds in-region and 5 seconds cross-region;
- screen-share start-to-first-frame p95 at or below 2 seconds;
- rekey p95 at or below 2 seconds with zero removed-device decryptions after the grace window;
- 99.99% SFU room availability, tested regional evacuation, and no API-secret exposure;
- a 32-participant, 60-minute load test within CPU, memory, packet-loss, and egress budgets;
- signed physical-device results for foreground/background/killed/locked, ReplayKit, Bluetooth,
  Wi-Fi/cellular handoff, Low Data Mode, thermal pressure, and interrupted broadcasts.

## External production prerequisites

Repository completion is not production certification. General rollout additionally requires two
failure-independent LiveKit/SFU regions, DNS/TLS, capacity and egress budgets, abuse monitoring,
Apple App Group and Broadcast Upload Extension provisioning, APNs/CallKit validation, privacy
review, incident runbooks, and recorded physical-device/carrier results.

## Primary references

- Telegram group calls and encrypted conference calls:
  <https://core.telegram.org/api/group-calls> and
  <https://core.telegram.org/api/end-to-end/group-calls>
- WhatsApp multi-device call key distribution:
  <https://engineering.fb.com/2021/07/14/security/whatsapp-multi-device/>
- IETF multiparty frame-encryption architecture (reference model, not a claim that Toj uses the
  SFrame wire format): <https://www.rfc-editor.org/rfc/rfc9605>
- Apple ReplayKit: <https://developer.apple.com/documentation/replaykit>
- LiveKit Swift SDK: <https://github.com/livekit/client-sdk-swift>
