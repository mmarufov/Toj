# Sync under injected network faults

The design was pre-registered in [sync-chaos-preregistration.md](sync-chaos-preregistration.md)
before the first measurement run. Every table below is rendered by `server/chaos/report.ts` from
the committed JSON ([after](sync-chaos-after.json), [before](sync-chaos-before.json)), so no
number here was copied by hand.

## What this shows, and what it does not

- **It tests the server and the sync protocol.** Four headless TypeScript clients (2 accounts ×
  2 devices, one direct dialog) talk to the real server through Toxiproxy. Each client follows the
  app's protocol rules: one send in flight, retried with the same `clientMsgId` until
  acknowledged, and catch-up paged by pts on every WebSocket hint and every reconnect.
- **It does not run the iOS app.** `CloudAppModel` and `CloudLocalStore` are not in the loop.
  - The iOS outbox fix shipped alongside this harness is proven by
    `CloudLocalStoreTests.testLateSendFailureCannotDowngradeMessageAlreadyAcknowledgedBySync`,
    which fails on the old code.
  - This harness only counts how often that bug's precondition occurs ("Failed after echo"
    below).
- **It is localhost plus Toxiproxy on one laptop.** It is not a phone radio, not a Tajik SIM,
  and not the national gateway. Only the network is faulted: there is no database crash and no
  server kill.

## Headline

| | After the fix (`47120dc`) | Before the fix (`1d10014`) |
|---|---|---|
| Messages sent (5 scenarios × 20 runs × 500) | 50,000 | 50,000 |
| Lost, server duplicates, device mismatches | 0, 0, 0 | 0, 0, 0 |
| Runs where a device was re-sent an update it already had | **0 of 100** | **97 of 100** (1,241 updates) |
| Worst scenario's convergence p99 (`reply_dropped`) | 4.01 s | 3.89 s |

- **Messages were not lost or duplicated** either way. Retries with the same `clientMsgId` and the
  server's idempotent send held under every fault.
- **The `getDifference` fix removed re-delivery entirely.** Before it, the bug showed up even on a
  clean link (17 of 20 runs), because four concurrent senders are enough to commit an event
  between two statements.
- **Convergence did not measurably change**, and was not expected to. Re-delivered updates are
  small and idempotent, so the fix saves bytes, not seconds, at this scale.

## Tables

### After the fix: environment

- Label: `after-fix`
- Git SHA: `47120dc70a3a67d43d4354f33836d65321039fbd`
- Date: 2026-09-30T22:37:34.897Z
- Machine: Mac17,9; Apple M5 Pro; 15 cores; 24 GB
- Bun 1.3.11; PostgreSQL 17.10 (Homebrew) on aarch64-apple-darwin25.4.0; Toxiproxy 2.12.0
- Command (from `server/`): `bun run chaos/run.ts --runs 20 --messages 500 --label after-fix --out ../docs/results/sync-chaos-after.json`

### Correctness

| Scenario | Runs | Messages | Lost | Server duplicates | Conflicting echoes | Device mismatches | pts mismatches | Unconverged runs | Fatal errors |
|---|---|---|---|---|---|---|---|---|---|
| clean | 20 | 10,000 | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| 3g | 20 | 10,000 | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| resets | 20 | 10,000 | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| reply_dropped | 20 | 10,000 | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| reply_cut | 20 | 10,000 | 0 | 0 | 0 | 0 | 0 | 0 | 0 |

### Convergence

| Scenario | Convergence p50 (s) | Convergence p99 = max of 20 (s) | Send phase p50 (s) |
|---|---|---|---|
| clean | 0.14 | 0.22 | 6.30 |
| 3g | 0.62 | 1.08 | 43.48 |
| resets | 0.21 | 0.71 | 8.93 |
| reply_dropped | 2.12 | 4.01 | 44.46 |
| reply_cut | 0.20 | 0.47 | 10.70 |

### Faults the clients hit

| Scenario | Send attempts | Failed attempts | Replies lost after commit (`duplicate: true`) | Failed after echo | Failed catch-up calls | WebSocket connects |
|---|---|---|---|---|---|---|
| clean | 10,000 | 0 | 0 | 0 | 0 | 80 |
| 3g | 10,000 | 0 | 0 | 0 | 0 | 80 |
| resets | 11,541 | 1,541 | 85 | 0 | 1,396 | 300 |
| reply_dropped | 12,339 | 2,339 | 1,917 | 1,518 | 1,818 | 123 |
| reply_cut | 12,492 | 2,492 | 2,015 | 313 | 1,540 | 97 |

### Re-delivery before and after the `getDifference` fix

| Scenario | Re-delivered updates before the fix | After the fix |
|---|---|---|
| clean | 68 (17 of 20 runs) | 0 (0 of 20 runs) |
| 3g | 99 (20 of 20 runs) | 0 (0 of 20 runs) |
| resets | 389 (20 of 20 runs) | 0 (0 of 20 runs) |
| reply_dropped | 299 (20 of 20 runs) | 0 (0 of 20 runs) |
| reply_cut | 386 (20 of 20 runs) | 0 (0 of 20 runs) |

### Before the fix: environment

- Label: `before-fix`
- Git SHA: `1d1001412eab0f512401dd98c3890ab4521e516f` (working tree differs from this SHA; see notes)
- Date: 2026-10-01T00:13:57.063Z
- Machine: Mac17,9; Apple M5 Pro; 15 cores; 24 GB
- Bun 1.3.11; PostgreSQL 17.10 (Homebrew) on aarch64-apple-darwin25.4.0; Toxiproxy 2.12.0
- Command (from `server/`): `bun run chaos/run.ts --runs 20 --messages 500 --label before-fix --out ../docs/results/sync-chaos-before.json`

### Before the fix: correctness

| Scenario | Runs | Messages | Lost | Server duplicates | Conflicting echoes | Device mismatches | pts mismatches | Unconverged runs | Fatal errors |
|---|---|---|---|---|---|---|---|---|---|
| clean | 20 | 10,000 | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| 3g | 20 | 10,000 | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| resets | 20 | 10,000 | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| reply_dropped | 20 | 10,000 | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| reply_cut | 20 | 10,000 | 0 | 0 | 0 | 0 | 0 | 0 | 0 |

### Before the fix: convergence

| Scenario | Convergence p50 (s) | Convergence p99 = max of 20 (s) | Send phase p50 (s) |
|---|---|---|---|
| clean | 0.15 | 0.22 | 6.30 |
| 3g | 0.58 | 1.30 | 43.78 |
| resets | 0.20 | 0.93 | 8.84 |
| reply_dropped | 2.18 | 3.89 | 48.46 |
| reply_cut | 0.21 | 0.49 | 10.70 |

## How to read the fault columns

- **Replies lost after commit.** A retry that came back `duplicate: true`, meaning an earlier
  attempt had committed on the server but its reply never arrived. Every one of them became
  exactly one message, which is the server's idempotent send doing its job.
- **Failed after echo.** An HTTP send attempt that failed after the same device had already
  received its own message through sync. That is the precise condition in which the old iOS
  store relabelled a delivered message as failed. Under dropped replies it happened 1,518 times
  in 10,000 messages, so on a lossy link the bug was not a corner case.
- **Re-delivered updates.** Updates a device received whose pts it had already applied. Before
  the `getDifference` fix, the cursor and the event page came from two statements, so an event
  committing between them was delivered twice. Nothing was lost either way, because clients
  apply messages idempotently.
- **Convergence** runs from the moment the last send is acknowledged until every device holds the
  server's digest and pts, with the toxics still active.
  - Each client waits at least 100 ms between catch-up calls, so convergence has a floor near
    0.1 s even on a clean link.
  - With 20 runs, p99 by nearest rank is the maximum.

## Findings while building the harness

These are recorded in the pre-registration and the deviations section, not tuned away.

1. **Bun's `fetch` silently re-sends a request when its reused keep-alive socket closes.**
   - With keep-alive on, a development `reply_dropped` run produced two `duplicate: true`
     acknowledgements and zero failures visible to the client.
   - So a POST was retried below the application's own retry logic. Only the server's
     idempotency key made it harmless.
   - The harness therefore opens a fresh connection for every measured request. That also makes
     Toxiproxy's per-link toxicity mean "per request".
2. **`reset_peer` only resets a link that carries data while the toxic is present.** An idle
   keep-alive link survives a pulse. The first design pulsed every 3 s and never fired inside a
   2.3 s send phase.

## Deviations from the pre-registration

Commit SHAs below are on this branch after its rebase onto `1d10014`.

1. **Request pacing** (`33d2625`).
   - The first full sweep was stopped after 21 runs.
   - 5 of its 20 `clean` runs hit `FailedToOpenSocket`: a fresh connection per request across
     two hops left thousands of sockets in TIME_WAIT (30 s on macOS), and the machine ran out of
     ephemeral ports.
   - Those runs still lost nothing and all converged. But a `clean` scenario with local socket
     failures is not clean, so the sweep was restarted from scratch.
   - Each client now waits at least 50 ms between sends and 100 ms between catch-up calls. The
     TIME_WAIT peak over five 500-message clean runs was 7,190 of about 16,000 ports.
   - The stopped attempt is not reported.
2. **A diagnostic field, `failureReasons`, was added** (`26fa43b`) after the pre-registration.
   It changes no metric, toxic or pass condition.
3. **Re-measured after a rebase.**
   - A complete pair of sweeps had been run on the branch before it was rebased onto `1d10014`
     (#50, which changed `server/src/sync.ts`). Its output lived in `/tmp` and was lost to a
     machine restart before it was committed, so none of it is reported here.
   - The sweeps below were re-run from scratch on the rebased branch, with the same harness.
   - "Before" is therefore `1d10014`, main without the fix, not the pre-registered `a796a92`.
     The comparison stays like-for-like.
4. **The machine was shared.** Other work ran on the same laptop.
   - The 1-minute load average was sampled 56 times, once a minute, from 2026-09-30T23:55Z
     (two thirds of the way through the "after" sweep) to 2026-10-01T01:17Z (the end of the
     "before" sweep). It ranged from 1.45 to 3.74 on 15 cores.
   - Timings are indicative, not a benchmark. The correctness counts do not depend on timing.
5. **The `--out` path recorded in each JSON** pointed at a local scratch directory. It was
   rewritten to the committed location (`../docs/results/…`) in both `environment.command` and
   `environment.options.out`. No other field was changed.
6. **Unidentified client errors.** A few failed attempts carry Bun error code `23`, which I did
   not identify:
   - "after", `reply_dropped`: 16 sends and 10 catch-up calls;
   - "before", `3g`: 8 sends and 7 catch-up calls.

   Each was retried like any other failure, and none affected the correctness counts.

## Where the measured commits live

- **"Before" (`1d10014`)** is on main.
- **"After" (`47120dc`)** is a commit on the branch of PR #52, which was squash-merged.
  - It stays reachable through the pull request:
    `git fetch origin pull/52/head && git checkout 47120dc`.
  - Its `server/src` and `server/chaos` match the squash commit, except for changes that merged
    to main afterwards (#51, outside the sync path).

## Reproduce

```sh
cd server
createdb toj_chaos && DATABASE_URL=postgres://localhost:5432/toj_chaos bun run src/migrate.ts
toxiproxy-server -host 127.0.0.1 -port 8474 &
DATABASE_URL=postgres://localhost:5432/toj_chaos \
  bun run chaos/run.ts --runs 20 --messages 500 --out after.json
bun run chaos/report.ts after.json before.json
```

For "before":
1. Check out `1d10014`.
2. Copy `server/chaos/` from `47120dc` into it.
3. Run the same command against a second disposable database.

The harness refuses any non-local `DATABASE_URL`. CI runs a mild version on every push
(`sync-chaos-smoke` in `.github/workflows/ci.yml`), one 40-message run per scenario, gated on
correctness only.
