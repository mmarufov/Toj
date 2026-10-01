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

<!-- HEADLINE -->

<!-- TABLES -->

## How to read the fault columns

- **Replies lost after commit.** A retry that came back `duplicate: true`, meaning an earlier
  attempt had committed on the server but its reply never arrived. Every one of them became
  exactly one message, which is the server's idempotent send doing its job.
- **Failed after echo.** An HTTP send attempt that failed after the same device had already
  received its own message through sync. That is the precise condition in which the old iOS
  store relabelled a delivered message as failed.
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
4. **The machine was shared.** Other work ran on the same laptop. Load averages sampled once a
   minute during the sweeps are in the JSON's companion log (see the build notes). Timings are
   indicative, not a benchmark. The correctness counts do not depend on timing.

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
