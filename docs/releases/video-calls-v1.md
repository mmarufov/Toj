# Video Calls v1 Release Report

This document is the release record for Toj one-to-one encrypted camera video calls. It separates
automated repository evidence from checks that require provisioned infrastructure and physical
iPhones. A release owner must complete every unchecked gate before enabling a general rollout.

## Build under review

- Branch: `mmarufov/video-calling-plan`
- Base: `origin/main`
- Call crypto protocol: `1`
- Camera media profile: `2`
- Pinned WebRTC revision: `e3512de97abf`
- XCFramework SHA-256: `4865baa44ed53114365bbb3576e8de6088a68048c4080ba72b31b4b702997b8b`
- Attestation source ref: `refs/tags/webrtc-e3512de97abf-build.2`
- Local verification: 2026-07-23
- Review status: automated repository gates pass; external release gates remain blocked

## Automated evidence

- [x] The downloaded XCFramework attestation and checksum match the pinned release.
- [x] The backend migration and complete server suite pass against PostgreSQL: 84 tests,
      0 failures, and 523 assertions.
- [x] The real `canImport(WebRTC)` path creates and strictly validates profile-1 SDP.
- [x] The real `canImport(WebRTC)` path creates, exchanges, and strictly validates profile-2 H264
      offer/answer SDP, including the transcript-bound DTLS fingerprints.
- [x] Profile-2 tests cover independent main/PiP renderers, permanent disabled track behavior,
      repeated engine teardown, and an ICE-restart offer.
- [x] The final complete signed iOS suite passes: 179 app/unit tests and 2 UI tests passed,
      0 failed, and only the opt-in 100k-message performance fixture skipped.
- [x] A clean Release simulator build succeeds and its demangled symbol table contains
      `Toj.WebRTCCallEngine`.
- [x] Scoped read-only Codex audits finish clean after their authorization, lifecycle, media,
      coordinator-reentrancy, and route-selection findings were fixed and regression-tested.
- [x] Info, base-entitlement, and opt-in multitasking-camera entitlement plists, the WebRTC
      workflow, coturn peer policy, Prometheus alert YAML, and `git diff --check` pass local static
      validation.
- [ ] A signed build succeeds with the distribution provisioning profile that contains the
      multitasking-camera capability and selects `Toj/Toj-MultitaskingCamera.entitlements`.
- [x] The required iOS PR check downloads and verifies the attested XCFramework, compiles the
      real-WebRTC Release path, asserts `Toj.WebRTCCallEngine`, and repeats the signed tests.

Automated tests do not establish camera hardware, encoder power, radio, TURN capacity, APNs, or
thermal behavior. Simulator success must not be used to check any physical-device gate below.

An attached physical iPhone was reachable on 2026-07-23, but the signed device build stopped before
compilation because no local iOS Development profile exists for `com.toj.Toj`. Automatic Apple
Developer profile creation was deliberately not invoked. The provisioning gate therefore remains
unchecked.

The checked-in project selects `Toj/Toj.entitlements`, which does not request Apple's restricted
multitasking-camera capability. This keeps ordinary signed builds merge-safe. A release owner may
select `Toj/Toj-MultitaskingCamera.entitlements` only with a matching provisioned profile; until
then, remote PiP and audio continue while outgoing capture pauses in the background.

## Provisioning and infrastructure

- [ ] `NSCameraUsageDescription`, Push Notifications, VoIP Push, background audio, and
      multitasking-camera capabilities are present in the release profile.
- [ ] Production APNs sends `video_call` only to devices registered with protocol `1`, media
      profile `2`, and call view `2`.
- [ ] Two failure-independent TURN regions expose UDP/TCP 3478 and TLS 443.
- [ ] Each TURN region has independent allocation and egress load-test results.
- [ ] `max-bps` starts at `512000` bytes/sec per allocation; `bps-capacity`, `total-quota`, and
      egress budgets are set from measurements rather than copied defaults.
- [ ] Aggregate allocation, saturation, failure, transport, and egress alerts have fired in a
      staging drill. No per-call camera-state telemetry is exported.
- [ ] `TOJ_TURN_VIDEO_READY=1` is set only after the preceding TURN gates pass.

## Physical-device matrix

Record device model, iOS version, app build, account IDs in redacted form, network/carrier, TURN
region, timestamps, and attached logs for every run. Use two accounts on at least two iPhones and
independent networks.

- [ ] Foreground outgoing and incoming video-first calls.
- [ ] Incoming background, killed, locked, and CallKit-answer flows with no pre-accept capture.
- [ ] Permission granted, undetermined, denied, Settings return, and late-callback races.
- [ ] Audio-first call upgraded to camera without SDP renegotiation.
- [ ] Front/rear switch, rotation, correct front mirroring, VoiceOver, Dynamic Type, and Reduce
      Motion.
- [ ] PiP enter/exit, scene replacement, competing camera, capture interruption, and runtime-error
      retry.
- [ ] Bluetooth and AirPlay route preservation; video-first speaker default; audio-first receiver
      behavior.
- [ ] Direct ICE and relay-only TURN over UDP, TCP, and TLS 443.
- [ ] Wi-Fi/cellular handoff, IPv6/NAT64, one TURN region unavailable, and credential renewal.
- [ ] Controlled loss/latency/jitter, constrained/Low Data Mode, roaming, and every data policy.
- [ ] Thirty-minute calls on supported low-, middle-, and high-tier devices with memory, battery,
      and thermal traces.

## Quantitative release gates

- [ ] Voice setup p95 is within 5% of baseline and success decreases by no more than 0.5 points.
- [ ] Acceptance to first remote video p95 is at most 3 seconds direct and 5 seconds over TURN/TLS.
- [ ] Camera toggle to remote frame p95 is at most 1 second on a healthy path.
- [ ] Handoff preserves audio and restores video within 8 seconds p95.
- [ ] At 10% loss and 300 ms RTT, no audio silence exceeds 2 seconds.
- [ ] Thirty-minute runs reach no critical thermal state and have no sustained post-warm-up memory
      growth.
- [ ] Relay-only SDP/candidate evidence contains neither host nor server-reflexive candidates.

## Rollout decision

Keep `TOJ_VIDEO_CALLS_ENABLED=0`, `TOJ_TURN_VIDEO_READY=0`, and the rollout percentage at zero
until all gates above are signed off. Then progress internal accounts, 5% for 48 hours, 25% for 72
hours, and 100%, stopping on any regression. Rollback sets the percentage to zero; in-flight
profile-2 calls retain their persisted selection policy and are allowed to finish.

Release owner: _unassigned_

Decision and timestamp: _blocked pending physical-device, provisioning, APNs, and TURN evidence_
