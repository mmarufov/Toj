# Voice Calls Follow-up Work

This file contains work intentionally excluded from the bootstrap merge. Items under
"Before public beta" are rollout gates, not optional polish.

## Before public beta

- [ ] **Short-lived TURN authorization.** Replace the current 60-minute credential
  exposure with a shorter renewable window or a revocable authorization design.
  Keep public voice-call readiness disabled until relay-abuse limits are proven.
- [ ] **Dedicated VoIP APNs readiness.** Verify the production key, team, bundle ID,
  VoIP topic, and environment independently of ordinary notification readiness. Add
  a failure metric that disables call advertising after persistent topic/auth errors.
- [ ] **Safe block-feature rollout floor.** Deploy a server version that enforces
  durable `account_blocks` before exposing block creation, and document the oldest
  version to which production may safely roll back.
- [ ] **Two-device production-path drill.** Test incoming calls from terminated,
  backgrounded, locked, and foreground states over Wi-Fi, cellular, relay-only, and
  temporary network loss.
- [ ] **TURN capacity and isolation drill.** Prove every UDP/TCP/TLS route from
  outside the relay network, verify special-use peer ranges stay denied, and record
  measured allocation and bandwidth capacity.
- [ ] **Call-control load test.** Exercise rate limits, simultaneous cross-calls,
  multi-device ringing, APNs timeouts, cleanup workers, and PostgreSQL listener
  reconnection at expected peak load.

## After the first immutable WebRTC release

- [x] **Required real-WebRTC PR gate.** The existing required iOS check now fetches
  and verifies the pinned immutable artifact, compiles the Release implementation,
  asserts `Toj.WebRTCCallEngine`, and runs the signed suite.
  **Completed:** v0.4.0.0 (2026-07-23).
- [ ] Add negative-path tests for `scripts/fetch-webrtc-xcframework.sh`: missing
  release, wrong revision, bad checksum, unsafe archive path, untrusted attestation,
  and self-hosted provenance.
- [ ] Test artifact recovery from a clean clone with no CocoaPods cache and no local
  WebRTC files.
- [ ] Schedule a periodic rebuild of the same pins and compare checksums, symbols,
  licenses, and SBOM metadata for reproducibility drift.

## Reliability and test depth

- [ ] Build a deterministic `CallCoordinator` harness covering outgoing, incoming,
  answered, declined, canceled, expired, reconnecting, and revoked-session flows.
- [ ] Replace open-ended `Task.yield()` test polling with bounded clocks or explicit
  synchronization.
- [ ] Add APNs failure-matrix tests for `Unregistered`, `BadDeviceToken`,
  `DeviceTokenNotForTopic`, throttling, transient HTTP/2 failures, and expiry during
  retry.
- [ ] Add cleanup tests for stale calls, signaling events, attempts, deliveries,
  allocations, telemetry claims, and permanently failing history rows.
- [ ] Add end-to-end idempotency-conflict tests for every call mutation, not only
  call creation and signaling sequence reuse.

## Product and operations

- [ ] Populate production call-quality telemetry from WebRTC statistics using only
  bounded, non-identifying buckets.
- [ ] Add dashboards and alerts for ring delivery latency, answer rate, key-exchange
  failure, TURN allocation failure, relay usage, signaling reconnects, and history
  outbox age.
- [ ] Document emergency kill-switch, partial-provider outage, TURN secret rotation,
  APNs key rotation, and immutable-artifact rollback procedures.
- [ ] Review call-history retention and privacy language before a wider rollout.
- [ ] Remove duplicate or unused call DTOs after the production contract stabilizes.
