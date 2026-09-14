# Voice Calls Release Plan

## Goal

Land encrypted one-to-one voice calls on `main`, build the exact pinned WebRTC
artifact at `webrtc-e3512de97abf`, install it locally, and leave `main` protected for
a solo-maintainer workflow.

This plan treats the current branch as a bootstrap release. Release compilation is
supposed to fail without the WebRTC artifact, so the first artifact must be built
after the reviewed source reaches `main`.

## Non-negotiable release rules

- Merge through a pull request. Do not push directly to `main`.
- Keep required CI, strict status checks, linear history, conversation resolution,
  admin enforcement, and force-push/deletion blocking.
- Remove only the independent human-approval requirement for solo maintenance.
- Keep GitHub Actions restricted to approved actions with SHA pinning required.
- Create `webrtc-e3512de97abf` only after the source commit is on `main`.
- Never move or delete a `webrtc-*` tag. Repository rules already enforce this.
- Keep immutable releases enabled.

## Phase 1: Fix server trust boundaries and durable state

1. **Make blocking atomic.**
   - Use one sorted account-pair advisory-lock helper in `createCall`, ordinary
     message sending, `blockAccount`, and `unblockAccount`.
   - Recheck the block row after taking the lock.
   - End requested, ringing, and active calls in the same transaction that creates
     a block.
   - Add deterministic two-transaction tests proving no message or call commits
     after blocking returns success.

2. **Protect call-history delivery.**
   - Give generated history messages a server-only idempotency namespace instead of
     using the client-controlled call UUID directly.
   - Validate the dialog, message kind, and generated payload before treating an
     existing idempotency row as a successful duplicate.
   - Do not delete ended calls while their history outbox row is still pending.
   - Add spoofing, retry, and retention tests.

3. **Make device revocation atomic with call termination.**
   - Run device revocation and matching call termination in one database
     transaction for sign-out and remote device removal.
   - Preserve the existing lock order used by account deletion.
   - Test rollback and the active-call lease cleanup path.

4. **Close abuse and listener races.**
   - Serialize caller, callee, and network call-attempt budgets before counting and
     inserting attempts.
   - Enforce one telemetry report per owning call device with a durable uniqueness
     gate.
   - Fence PostgreSQL notification reconnect callbacks by connection generation so
     stale clients cannot create duplicate listeners.

## Phase 2: Fix call establishment under real timing

1. **Resolve simultaneous cross-calls.**
   - Preserve `existingCallId` from a server `busy` response.
   - Pivot the losing outgoing runtime to the server-selected call.
   - Defer same-peer PushKit decline while outgoing creation is unresolved.
   - Test both `push-before-busy` and `busy-before-push` interleavings.

2. **Remove VoIP push head-of-line blocking.**
   - Process claimed deliveries with a small bounded worker pool.
   - Keep per-delivery retry and terminal-status behavior unchanged.
   - Use a gated sender test to prove a stalled request cannot consume the full
     30-second ring window for every later device.

3. **Test the media-security boundary.**
   - Add focused tests for SDP fingerprint parsing, fingerprint mismatch rejection,
     relay-only candidate filtering, and malformed signaling envelopes.

## Phase 3: Make database rollout safe

1. Add the VoIP environment check constraint as `NOT VALID` in the fast schema
   transaction, then validate it in a separate bounded-lock phase.
2. Build indexes on existing high-write tables with `CREATE INDEX CONCURRENTLY`
   outside the schema transaction.
3. Apply a bounded `lock_timeout` and make retries repair invalid concurrent indexes.
4. Keep new-table indexes in the atomic schema phase where they cannot block existing
   traffic.
5. Test a clean migration and a retry after an interrupted concurrent index build.

## Phase 4: Establish bootstrap CI

The first PR cannot run Release compilation because the pinned WebRTC release does
not exist yet.

Required checks for this bootstrap PR:

- `server-tests`: frozen Bun install, PostgreSQL migration, and the complete backend
  suite.
- `ios-debug-tests`: signed simulator build and all iOS tests without the optional
  WebRTC pod.
- Workflow lint checks for YAML, shell syntax, pinned action references, and coturn
  policy validation.

The `WebRTC XCFramework` tag workflow must then:

1. Verify the tag points to reviewed `main` history.
2. Build the pinned WebRTC revision and validate its SBOM and slices.
3. Install the local pod.
4. Compile Toj in Release configuration with the real WebRTC implementation.
5. Run the signed Debug iOS test suite.
6. Publish attested immutable assets only if every preceding step passes.

## Phase 5: Verify and ship

1. Run `cd server && bun run migrate && bun test`.
2. Run the signed serialized simulator suite with `xcodebuild test`.
3. Run migration retry tests, script syntax checks, plist checks, workflow parsing,
   action-pin validation, and coturn policy validation.
4. Bump `VERSION` from `0.1.1.0` to `0.2.0.0` and update `CHANGELOG.md`.
5. Commit the branch in reviewable units, push it, and open a PR against `main`.
6. Wait for required checks, resolve failures, and merge using linear history.
7. Create and push exactly:

   ```sh
   git tag -a webrtc-e3512de97abf -m "Pinned Toj WebRTC artifact"
   git push origin webrtc-e3512de97abf
   ```

8. Wait for the tag workflow to publish the immutable release.
9. Run:

   ```sh
   scripts/fetch-webrtc-xcframework.sh
   pod install
   ```

10. Compile Release locally with the fetched artifact and rerun the signed tests.

## Definition of done

- The race, trust-boundary, delivery, migration, and revocation regression tests pass.
- Required GitHub checks pass on the PR.
- `main` remains protected without requiring a second human account.
- The protected tag points to the merged commit.
- The immutable release contains the expected revision, checksum, SBOM, and
  attestation.
- Local Release compilation and signed iOS tests pass with the fetched XCFramework.
- Deferred work is recorded in `voice-calls-v1-follow-up.md` with explicit rollout
  gates.

## User-owned prerequisites

No user action is needed to implement, test, commit, merge, tag, or fetch the
artifact in the current repository.

Before calls can work between real phones, the user must provide or confirm:

- Apple Developer configuration for the app identifier, Push Notifications,
  PushKit/VoIP topic, signing profile, and a production APNs key.
- Deployment secret values listed in `server/OPERATIONS.md`. Do not paste private
  keys or shared secrets into issues, commits, or chat.
- Public TURN hostnames, TLS certificates, firewall rules, and the coturn shared
  secret for at least one reachable relay node.
- Two physical iPhones using two Toj accounts that share an eligible direct dialog
  and have exchanged messages in both directions.
- Final approval before setting `TOJ_TURN_READY=1` and
  `TOJ_VOICE_CALLS_ENABLED=1` in production.
