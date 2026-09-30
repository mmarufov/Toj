# Sync chaos harness: pre-registration

Committed before the first measurement run. Anything run before this commit was a development
run: at most one run per scenario, used only to debug the harness and size the sweep, and none
of it is reported. Any later change to what is below goes in the results file as a named
deviation, with its reason.

## Question

When the network drops, resets, delays or cuts traffic between clients and the server, does
every device still end up with exactly the messages the server has? The harness checks for
messages lost, messages duplicated, and devices that disagree. It also measures how long
convergence takes after the last send is acknowledged.

## What is under test, and what is not

- **Under test:** the server (`server/src`) and its sync protocol. That covers idempotent send by
  `clientMsgId`, WebSocket `sync_hint`s, and `/v1/sync/difference` paged by a pts cursor.
- **Not under test:** the iOS app. `server/chaos/sync-client.ts` is a headless TypeScript client
  that follows the same protocol rules as the app:
  - one send in flight per device;
  - retry with the same `clientMsgId` until acknowledged;
  - catch-up on every hint and every reconnect;
  - the server's returned `state.pts` is the cursor.

  It does not run `CloudAppModel` or `CloudLocalStore`. The iOS outbox fix is covered by
  `CloudLocalStoreTests`, not by this harness.

## Setup

- **Server:** `startCloudServer` in-process on an ephemeral port, with background workers off.
- **Database:** a disposable local PostgreSQL database. The harness refuses any non-local host,
  and truncates the sync tables before every run.
- **Toxiproxy:** 2.12.0, with one proxy (`toj`) in front of the server.
  - All measured traffic goes through it: sends, catch-up and the WebSocket.
  - Sign-in and dialog creation go straight to the server. They are setup, not measurement.
- **Clients:** 4, meaning 2 accounts × 2 devices each, in one direct dialog.
  - Sign-in uses the non-production OTP path, where `/v1/auth/start` returns the code.
  - The second device on each phone is enabled by backdating the harness's own
    `otp_challenges` rows past the 30 s resend cooldown. No production code path changes.
- **Connections:** every measured HTTP request opens a fresh TCP connection (`keepalive: false`).
  Two reasons:
  - Toxiproxy rolls a toxic's toxicity once per link, so on a reused link a 20% fault would hit
    one long-lived link or none.
  - Development runs showed that Bun's `fetch` silently re-sends a request when its reused
    keep-alive socket closes. That hides the failure from the retry logic under test, and only
    the server's idempotency made it harmless.
- **Client timeouts:**
  - send: 8 s; catch-up: 20 s;
  - WebSocket ping every 5 s, declared dead after 12 s of silence;
  - reconnect after 0.25-1 s;
  - retry backoff: jittered, capped at 2 s.
- **Machine:** Mac17,9 (Apple M5 Pro, 15 cores, 24 GB), macOS 27.0.1, Bun 1.3.11,
  PostgreSQL 17.10 (Homebrew), all on localhost.

## Scenarios (full sweep)

| Name | Toxics |
|---|---|
| `clean` | none |
| `3g` | downstream `latency` 300 ms, jitter 200 ms; `bandwidth` 40 KB/s upstream and downstream |
| `resets` | `reset_peer` (timeout 0), both directions, present for 200 ms out of every 1 s starting at once, so any link carrying data in that window is reset |
| `reply_dropped` | downstream `timeout` 1000 ms at toxicity 0.2: the request reaches the server, which may commit it, and the reply is dropped and the link closed after 1 s |
| `reply_cut` | downstream `limit_data` 300 bytes at toxicity 0.2: the link closes 300 bytes into the reply, mid-response |

Toxics stay active through both the send phase and the convergence phase.

## Runs and messages

- **Full sweep:** 5 scenarios × 20 runs. Each run sends 500 messages, 125 from each of the 4
  clients, so each scenario totals 10,000 messages.
- **Before and after the `getDifference` fix:**
  - "after" is the server at the commit that adds this file;
  - "before" is the same harness run against the server at `a796a92` (main before the fix), with
    `server/chaos/` copied in unchanged;
  - both run the full sweep.
- **CI smoke** (`--mild`): 1 run × 40 messages per scenario, with milder toxics:
  - `3g`: 50 ± 25 ms latency;
  - `resets`: 50 ms upstream pulse every 1 s;
  - `reply_dropped` and `reply_cut`: toxicity 0.05.

  It gates only on correctness, never on timing.

## Metrics, per run and per scenario

- **Lost:** `clientMsgId`s the clients generated that are not in the server's `messages` table.
  Target 0.
- **Server duplicates:** `clientMsgId`s with more than one `messages` row. Target 0.
- **Device mismatches:** devices whose final state digest differs from server truth. Target 0.
  - The digest is SHA-256 over sorted `msg_id|clientMsgId|sender|sha256(text)` lines.
  - Server truth is read in-process through `getDifference`, not through the proxy.
- **pts mismatches:** devices whose cursor is not the account's server pts. Target 0.
- **Conflicting echoes:** a `clientMsgId` seen with two different `msg_id`s on one device.
  Target 0.
- **Re-delivered updates:** updates a device receives whose pts it has already applied. Reported
  before and after the fix; target 0 after.
- **Convergence time:** measured from the moment the last send is acknowledged until every device
  has the server's digest and pts and no catch-up is in flight.
  - Reported as p50 and p99 by nearest rank. With 20 runs, p99 is the maximum.
  - Timeout: 180 s. A run that times out counts as unconverged and has no convergence sample.
- **Diagnostics, no target:**
  - send attempts and failures;
  - `duplicate: true` acknowledgements, meaning replies lost after the server committed;
  - late failures after echo;
  - sync failures;
  - WebSocket connects.

  A late failure after echo is an HTTP send attempt that failed after the same device had already
  applied its own message through sync. It is the exact precondition of the iOS outbox bug.

## Exact command

```sh
cd server
createdb toj_chaos && DATABASE_URL=postgres://localhost:5432/toj_chaos bun run src/migrate.ts
toxiproxy-server -host 127.0.0.1 -port 8474 &
DATABASE_URL=postgres://localhost:5432/toj_chaos \
  bun run chaos/run.ts --runs 20 --messages 500 --out ../docs/results/sync-chaos-after.json
```

The results file records the SHA, date, machine, and the Bun, PostgreSQL and Toxiproxy versions
for each sweep. It is written from the JSON the harness emits.
