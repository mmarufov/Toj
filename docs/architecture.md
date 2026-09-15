# Architecture

This document explains how Toj is put together and, more usefully, *why* — most
of the non-obvious decisions here exist because of one network constraint. Start
with the [README](../README.md) for the overview; this is the depth behind it.

## The constraint

Tajikistan routes effectively all international traffic through a single
state-controlled gateway which throttles targeted messengers. The design target
is therefore a 3G worst case: **100–500 kbps, high latency, jitter, packet loss,
and abrupt disconnection**.

Two rules fall out of that, and nearly every design choice below is one of them
applied to a specific subsystem:

1. **Never assume connectivity.** Everything retries, resumes, and degrades.
   A dropped connection is an expected state, not an error path.
2. **Keep domestic traffic domestic.** Traffic that stays in-country never
   crosses the gateway. The endpoint is one swappable configuration value
   (`TOJ_CLOUD_BASE_URL` / `CloudConfig`), so relocating the backend in-country
   is a migration, not a redesign.

## Data model: a cloud messenger, deliberately

Toj follows Telegram's **data model**, not its wire protocol.

Default chats are cloud chats: messages persist server-side, sync across a
user's devices, and are restorable on a new login. They are stored **encrypted
at rest with server-held keys**. The server can decrypt — that capability is
what makes sync, history restore and new-device login work at all.

The alternative, end-to-end by default, was considered and rejected for the
product rather than for the engineering: multi-device end-to-end is the genuinely
hard part, most users neither verify nor believe end-to-end claims, and an app
that structurally *cannot* comply with a lawful order is an app that gets blocked
rather than one that protects anyone.

The honest version of privacy here is **Secret Chats** — opt-in, true end-to-end
via libsignal, single-device. The libsignal engine is already in the repository
(`Toj/Core/Crypto/CryptoEngine.swift`); the user-facing feature is not built yet.

What this explicitly is *not*: Toj does not claim default chats are unreadable
by the server. That claim would be the one genuinely dangerous lie a messenger
can tell.

## Client

Native Swift and SwiftUI, iOS 26, Liquid Glass. All I/O, cryptography and
networking is asynchronous and cancellable; the main thread never blocks.

### Offline-first is the anti-lag rule

```
User taps send
   │
   ├─► write to encrypted local store ──► UI updates immediately
   │
   └─► enqueue in outbox ──► transport ──► server ──► ack ──► reconcile state
```

The encrypted on-device store is **the UI's source of truth**. Views render
from local data and never wait on a round trip. Sends are optimistic: the
message appears instantly and its delivery state is reconciled later. On a link
where the round trip is half a second on a good day, this is the difference
between an app that feels fast and one that does not.

### Client modules

| Module | Contents | Notes |
| --- | --- | --- |
| `Core/Store/` | `CloudLocalStore`, `CloudProductivityStore`, `EncryptedProfilePhotoStore` | SQLite via GRDB, encrypted with SQLCipher |
| `Core/Store/Search/` | `SearchIndexer`, `MessageSearchStore`, `SearchIndexSchema` | On-device FTS5 index |
| `Core/Search/` | `SearchTextNormalizer`, `SearchUnicodeTables`, `PreparedSearchQuery` | Tokenizer tables are **generated**, not hand-written — see below |
| `Core/Cloud/` | `CloudAPI`, `CloudConfig`, `TokenStore`, `CloudMediaEngine`, `MediaPrefetchScheduler` | REST/WebSocket client, endpoint config, chunked media |
| `Core/Sync/` | `ReplicaSyncCoordinator`, `CloudHintSocket`, `PresenceCoordinator`, `DraftSyncCoordinator`, `ReplicaNetworkMonitor` | Multi-device convergence |
| `Core/Transport/` | `WebSocketClient`, `BackoffPolicy`, `Envelope`, `KeyDirectoryClient` | Connection lifecycle and reconnection |
| `Core/Calls/` | `CallStateMachine`, `CallProtocol`, `CallCrypto`, `WebRTCVoiceEngine` | 1:1 calling |
| `Core/GroupCalls/` | `GroupCallCrypto`, `GroupCallMediaReducer` | SFU group calls |
| `Core/Accounts/` | `AccountCatalog`, `AccountStorage`, `MessagingAccountRuntime` | Identity and per-account isolation |
| `Core/Background/`, `Core/Push/` | `BackgroundRuntimeCoordinator`, `PushRegistrationCenter` | Background wake and APNs registration |
| `Features/` | Conversations, contacts, settings, calls, search UI | Logic lives in testable types, not views |
| `DesignSystem/` | `TojTheme` and shared primitives | See [design system](design-system.md) |

### Search tokenizer artifacts are generated

The Unicode normalizer tables, test vectors and tokenizer manifest under
`Core/Search/` are **probed from the locked SQLCipher build** by
`scripts/generate-search-*.py`, not written by hand. CI regenerates them and
diffs the result, so a pod bump or a manual edit cannot silently leave on-device
indexes disagreeing with the code that queries them. The check fails closed:
a shallow checkout is a build failure rather than a skipped test.

## Transport

Ordinary TLS + WebSocket, with REST under `/v1` and the socket at `/v1/ws`.

Toj deliberately does **not** implement a custom wire protocol. Looking exactly
like normal HTTPS is the censorship-resistance strategy — a bespoke protocol is
a fingerprint, and a fingerprint is what gets throttled. Resistance comes from
being unremarkable on the wire, plus multiple entry IPs.

Reconnection is `BackoffPolicy`'s job, and it is assumed to run constantly.

## Backend

Bun + TypeScript over PostgreSQL, in [`server/`](../server). This is the real
backend — roughly 50 modules and ~387 tests — not a prototype awaiting a
rewrite. It persists messages, syncs devices, and handles delivery, acks,
presence and fan-out.

### Encryption at rest

A messenger's message store is a high-value target, so it is never a plaintext
honeypot.

`envelope-crypto.ts` implements envelope encryption: content is sealed under a
per-record data key with AES-GCM, and that data key is itself wrapped by a
per-account key. Key material is cached briefly, zeroized after use, and key
retirement is fenced — new unwraps stop as soon as revocation begins, and the
destructive pass waits out the cache drain so it cannot race a read that copied
a key moments before expiry.

### Lookup without plaintext

`blind-index.ts` provides **versioned** keyed digests so the server can look
records up without storing the value it is searching on. Each domain —
`phone-lookup`, `otp-code`, `opaque-token`, `media-digest`, `message-send`,
and others — gets its own HMAC domain, so a digest from one context cannot be
replayed as a lookup in another. Versioning means the index key can be rotated
without a flag day.

### Migrations

Schema changes are expand/contract, visible in the file naming:
`schema-*-expand.sql` adds, `schema-*-contract.sql` removes, and
`schema-*-concurrent.sql` holds index builds that must not take a lock. A
deploy is never a moment where old and new code cannot both run.

### Storage

PostgreSQL is the message store, Supabase-hosted today. Media chunks live
encrypted in PostgreSQL rather than in object storage — one fewer service to
reach through the gateway, and one fewer place for plaintext to sit.

### Identity and OTP

Phone-number identity, OTP-verified. Delivery is multi-channel —
`telegram-otp.ts`, `infobip-otp.ts` (SMS) and `whatsapp-otp.ts` — because SMS
into Tajikistan is expensive and gives no delivery receipt, so the cheap
channels carry the traffic and the user chooses.

## Calls

**Written and tested; disabled in every deployed configuration.**

- **1:1** — WebRTC, preferring peer-to-peer. Opus audio; VP8/VP9/AV1 and H.264
  video with simulcast and adaptive bitrate. Media adapts on network and thermal
  pressure with audio given priority, because a call that keeps audio and drops
  video is still a call.
- **Group** — LiveKit SFU with end-to-end frame encryption.
- **Relay** — coturn. `infra/coturn/` is a deployment template; **no TURN server
  is deployed**, and CI validates the peer-deny policy in that template.

`server/src/staging-config.ts` *throws on startup* if the call feature flags are
set. That is intentional: the release gates behind them, recorded in
[docs/releases/](releases/), are not met, and a flag that can be flipped by
accident is not a gate.

## Verification

CI runs three jobs on every pull request:

| Job | What it proves |
| --- | --- |
| `server-tests` | Backend suite against a live PostgreSQL service, including cross-domain envelope writes exercised in both canary and full envelope modes |
| `ios-debug-tests` | Fetches and verifies the pinned WebRTC artifact's checksum and attestation, compiles the Release path, asserts WebRTC namespace isolation, verifies the privacy manifest, and runs the signed suite on a real simulator |
| `repository-policy-tests` | Search-table ancestry fails closed; shell, plist and coturn policy validate; SwiftPM and CocoaPods pins match reviewed revisions exactly; **every GitHub Action is pinned to a full commit SHA** |

Supply chain is pinned rather than floated: the WebRTC XCFramework is a
reproducible build published as an attested release artifact, LibSignalClient is
pinned by tag *and* prebuilt-FFI checksum, and the SwiftPM pin set is asserted
against an expected map in CI.

## Deployment

| | |
| --- | --- |
| **Staging** | `api.tojchat.tech` — Render (Frankfurt) + Supabase PostgreSQL. Manual deploys only. Login restricted to a small allowlist |
| **Production** | A separate, untouched endpoint |
| **Planned** | An in-country Tajikistan server, taken at launch once there is a device and a real SIM to measure against |

Runbooks: [backend staging](../server/STAGING.md),
[backend operations](../server/OPERATIONS.md),
[iOS staging](ios-staging.md).

## Known gaps

Honest accounting, as of the current `main`:

- Nothing has run on a **physical device or a Tajik SIM**. This is the riskiest
  remaining unknown in the project, and it is not a code problem.
- **Push notifications are not provisioned** — APNs needs an Apple Developer
  account.
- **No TURN server is deployed**, so calls cannot traverse restrictive NATs even
  if they were enabled.
- **Secret Chats are not built.**
- Scale hardening — partitioning, connection limits, read replicas, a paid
  database tier — is pre-launch work that has not been done.
