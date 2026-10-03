# Slack bridge under faults

The design was pre-registered in [slack-bridge-preregistration.md](slack-bridge-preregistration.md)
before the first measured run. Every table below is rendered by `go run ./chaos render` from the
committed JSON, so no number here was copied by hand. **Every Slack-side number is simulated
Slack**: the bridge talks to the fake in `integrations/slack-bridge/internal/slackfake`, not to
Slack. A real-Slack smoke test is listed at the end and has not been run.

## What this shows, and what it does not

- **It runs the real bridge and the real Toj server.** The bridge is a separate process, killed
  with SIGKILL 3 times per run at named points. Toj is `bun run src/cloud.ts` on a local Postgres
  database, reached through Toxiproxy with the five scenarios of the sync chaos harness (#52).
- **Slack is a fake.** It implements the documented contract (request signing, retry headers,
  the 3 s deadline, `429` with `Retry-After`, `message_changed` and `message_deleted`) and injects
  duplicates, reordering, late acknowledgements, 429s and replies lost after a write committed.
  Its retry schedule is compressed to 1 s, 6 s and 30 s (Slack's is about 0 s, 1 min, 5 min), and
  the bridge restarts within 0.5 s of each kill. **An outage longer than Slack's last retry is
  not covered**: Slack would stop delivering those events, and the bridge has no history backfill
  yet.
- **Message events do not carry metadata in the fake**, because whether Slack's do is
  unconfirmed. The loop guard is measured without that layer.
- It is one laptop, one group and one channel, at a burst rate (10 messages per second from each
  side) far above a normal group chat.

## Headline

At `adc6991`, 5 scenarios × 2 runs × 200 messages (half written in Toj, half in Slack), with 3
SIGKILLs per run:

- **0 of 2,000 messages lost, duplicated or echoed**, in both directions, across **30 kills**.
- 304 of 304 edits and 89 of 89 deletes converged.
- All 2,719 Slack deliveries were acknowledged in under 8 ms (p99 2.3 ms). None reached 3 s.
- 0 calls during a `Retry-After` window, out of 34 injected 429s.
- Out of order: **0 of 48,619 pairs** Toj to Slack (one goroutine per channel posts in order);
  **1,662 of 49,302 pairs (3.4%)** Slack to Toj. Slack does not order deliveries and Toj assigns
  `msg_id` at commit, so this direction is reported, not gated.
- Slack-to-Toj latency is high on `3g` (p50 17 s, p99 33 s). The bridge keeps one Toj send in
  flight to preserve order, which is about 2.5 sends per second on that link, and the workload's
  burst queues behind it.

## Final sweep

- Label: `sweep`
- Git SHA: `adc69913b328a287ab94f11af043017ea3231dd4`
- Date: 2026-10-03T07:47:55Z
- Machine: Mac17,9; Apple M5 Pro; 15 cores; 24 GB
- go1.27.1; Bun 1.3.11; PostgreSQL 17.10 (Homebrew) on aarch64-apple-darwin25.4.0; Toxiproxy 2.12.0
- Command (from `integrations/slack-bridge`): `go run ./chaos --runs 2 --messages 200 --kills 3 --seed 1 --label sweep --log-dir logs --out slack-bridge.json`
- Slack: simulated (the fake in `internal/slackfake`)

| Scenario | Runs | Source messages | Lost | Duplicated | Echoed | Text mismatches | Unconverged runs | Kills (fallback) | Kills survived |
|---|---|---|---|---|---|---|---|---|---|
| clean | 2 | 400 | 0 | 0 | 0 | 0 | 0 | 6 (0) | 6 |
| 3g | 2 | 400 | 0 | 0 | 0 | 0 | 0 | 6 (0) | 6 |
| resets | 2 | 400 | 0 | 0 | 0 | 0 | 0 | 6 (0) | 6 |
| reply_dropped | 2 | 400 | 0 | 0 | 0 | 0 | 0 | 6 (2) | 6 |
| reply_cut | 2 | 400 | 0 | 0 | 0 | 0 | 0 | 6 (0) | 6 |
| all | 10 | 2,000 | 0 | 0 | 0 | 0 | 0 | 30 (2) | 30 |

| Scenario | Edits converged | Deletes converged | Out-of-order pairs, Toj to Slack | Out-of-order pairs, Slack to Toj |
|---|---|---|---|---|
| clean | 60 of 60 | 21 of 21 | 0 of 9,900 | 184 of 9,900 |
| 3g | 58 of 58 | 22 of 22 | 0 of 9,702 | 232 of 9,801 |
| resets | 62 of 62 | 17 of 17 | 0 of 9,801 | 463 of 9,801 |
| reply_dropped | 72 of 72 | 7 of 7 | 0 of 9,415 | 274 of 9,900 |
| reply_cut | 52 of 52 | 22 of 22 | 0 of 9,801 | 509 of 9,900 |
| all | 304 of 304 | 89 of 89 | 0 of 48,619 | 1,662 of 49,302 |

| Scenario | Retry deliveries | Duplicate deliveries | Late acks injected | Undeliverable (never answered by the bridge) | 429s injected | Calls during Retry-After | Replies dropped after commit |
|---|---|---|---|---|---|---|---|
| clean | 57 | 24 | 22 | 0 (0) | 5 | 0 | 8 |
| 3g | 68 | 28 | 26 | 0 (0) | 9 | 0 | 9 |
| resets | 81 | 24 | 30 | 0 (0) | 8 | 0 | 10 |
| reply_dropped | 53 | 25 | 28 | 0 (0) | 8 | 0 | 14 |
| reply_cut | 86 | 22 | 28 | 0 (0) | 4 | 0 | 6 |
| all | 345 | 123 | 134 | 0 (0) | 34 | 0 | 47 |

| Scenario | Acks | Ack p50 (ms) | Ack p99 (ms) | Ack max (ms) | Acks at or over 3 s | Toj to Slack p50 / p99 (s) | Slack to Toj p50 / p99 (s) |
|---|---|---|---|---|---|---|---|
| clean | 547 | 1.0 | 2.2 | 7.7 | 0 | 0.02 / 1.57 | 0.17 / 1.30 |
| 3g | 543 | 1.1 | 3.6 | 4.9 | 0 | 1.96 / 4.67 | 16.99 / 32.86 |
| resets | 549 | 1.0 | 2.5 | 5.5 | 0 | 1.02 / 4.09 | 0.21 / 7.23 |
| reply_dropped | 525 | 1.0 | 2.2 | 3.4 | 0 | 3.95 / 15.26 | 0.16 / 7.04 |
| reply_cut | 555 | 0.9 | 2.0 | 2.5 | 0 | 0.01 / 1.14 | 0.19 / 7.11 |
| all | 2,719 | 1.0 | 2.3 | 7.7 | 0 | 0.80 / 14.72 | 0.22 / 30.81 |

Two of the 30 kills in `reply_dropped` were fallbacks: the armed kill point was not reached within
20 s, so the bridge was killed at that moment, as pre-registered.

## Negative controls

Each run turns one protection off. They ran on the same commit as the final sweep, at 60 messages
and 3 kills each, on the `clean` scenario.

- Label: `negative-controls`
- Git SHA: `adc69913b328a287ab94f11af043017ea3231dd4`
- Date: 2026-10-03T07:53:36Z
- Machine: Mac17,9; Apple M5 Pro; 15 cores; 24 GB
- go1.27.1; Bun 1.3.11; PostgreSQL 17.10 (Homebrew) on aarch64-apple-darwin25.4.0; Toxiproxy 2.12.0
- Command (from `integrations/slack-bridge`): `go run ./chaos --scenarios clean --messages 60 --kills 3 --seed 101 --converge-timeout 40s --label negative-controls --control-set loop_guard;event_dedupe;event_dedupe,client_msg_id;reconcile@after_slack_post;cursor_tx@after_cursor_commit;retry_after --log-dir control-logs --out slack-bridge-controls.json`
- Slack: simulated (the fake in `internal/slackfake`)

| Scenario | Runs | Source messages | Lost | Duplicated | Echoed | Text mismatches | Unconverged runs | Kills (fallback) | Kills survived |
|---|---|---|---|---|---|---|---|---|---|
| control:loop_guard | 1 | 60 | 3 | 12 | 42 | 12 | 1 | 3 (0) | 0 |
| control:event_dedupe | 1 | 60 | 0 | 0 | 0 | 0 | 0 | 3 (0) | 3 |
| control:event_dedupe,client_msg_id | 1 | 60 | 0 | 5 | 0 | 0 | 0 | 3 (0) | 0 |
| control:reconcile@after_slack_post | 1 | 60 | 0 | 2 | 0 | 0 | 0 | 3 (0) | 0 |
| control:cursor_tx@after_cursor_commit | 1 | 60 | 6 | 0 | 0 | 0 | 1 | 3 (0) | 0 |
| control:retry_after | 1 | 60 | 0 | 0 | 0 | 0 | 0 | 3 (0) | 3 |
| all | 6 | 360 | 9 | 19 | 42 | 12 | 2 | 18 (0) | 6 |

| Scenario | Edits converged | Deletes converged | Out-of-order pairs, Toj to Slack | Out-of-order pairs, Slack to Toj |
|---|---|---|---|---|
| control:loop_guard | 1 of 3 | 2 of 4 | 0 of 105 | 138 of 406 |
| control:event_dedupe | 8 of 8 | 4 of 4 | 0 of 435 | 76 of 435 |
| control:event_dedupe,client_msg_id | 9 of 9 | 1 of 1 | 0 of 435 | 32 of 276 |
| control:reconcile@after_slack_post | 7 of 7 | 1 of 1 | 0 of 378 | 94 of 435 |
| control:cursor_tx@after_cursor_commit | 9 of 9 | 5 of 5 | 0 of 276 | 72 of 435 |
| control:retry_after | 5 of 5 | 4 of 4 | 0 of 435 | 40 of 406 |
| all | 39 of 41 | 17 of 19 | 0 of 2,064 | 452 of 2,393 |

| Scenario | Retry deliveries | Duplicate deliveries | Late acks injected | Undeliverable (never answered by the bridge) | 429s injected | Calls during Retry-After | Replies dropped after commit |
|---|---|---|---|---|---|---|---|
| control:loop_guard | 34 | 4 | 6 | 0 (0) | 1 | 0 | 2 |
| control:event_dedupe | 24 | 0 | 1 | 0 (0) | 0 | 0 | 1 |
| control:event_dedupe,client_msg_id | 15 | 3 | 1 | 0 (0) | 3 | 0 | 0 |
| control:reconcile@after_slack_post | 22 | 3 | 2 | 0 (0) | 2 | 0 | 1 |
| control:cursor_tx@after_cursor_commit | 18 | 3 | 4 | 0 (0) | 0 | 0 | 3 |
| control:retry_after | 17 | 2 | 2 | 0 (0) | 0 | 0 | 1 |
| all | 130 | 15 | 16 | 0 (0) | 6 | 0 | 8 |

| Scenario | Acks | Ack p50 (ms) | Ack p99 (ms) | Ack max (ms) | Acks at or over 3 s | Toj to Slack p50 / p99 (s) | Slack to Toj p50 / p99 (s) |
|---|---|---|---|---|---|---|---|
| control:loop_guard | 89 | 0.9 | 3.3 | 3.3 | 0 | 0.77 / 1.62 | 0.26 / 7.29 |
| control:event_dedupe | 78 | 1.0 | 3.2 | 3.2 | 0 | 0.03 / 0.48 | 0.20 / 7.21 |
| control:event_dedupe,client_msg_id | 79 | 1.2 | 2.2 | 2.2 | 0 | 1.79 / 2.61 | 0.25 / 1.62 |
| control:reconcile@after_slack_post | 80 | 1.0 | 2.1 | 2.1 | 0 | 1.47 / 2.81 | 0.22 / 7.16 |
| control:cursor_tx@after_cursor_commit | 77 | 1.0 | 2.2 | 2.2 | 0 | 0.01 / 0.52 | 0.20 / 7.23 |
| control:retry_after | 76 | 1.0 | 2.9 | 2.9 | 0 | 0.02 / 0.46 | 0.19 / 1.19 |
| all | 479 | 1.0 | 2.6 | 3.3 | 0 | 0.23 / 2.71 | 0.22 / 7.29 |

| Control | Pre-registered expectation | Result |
|---|---|---|
| `loop_guard` | echoed > 0 | 42 echoes; the echo loop also kept the run from converging |
| `event_dedupe` (event_id table and message-map check) | duplicated = 0, Toj's `clientMsgId` still collapses retries | 0 duplicated |
| `event_dedupe,client_msg_id` | duplicated > 0 | 5 duplicated |
| `reconcile`, kills at `after_slack_post` | duplicated > 0 | 2 duplicated |
| `cursor_tx`, kills at `after_cursor_commit` | lost > 0 | 6 lost |
| `retry_after` | calls during Retry-After > 0 | **inconclusive here**: the fake drew no 429 in this run, see below |

### Retry-After, at a 30% 429 rate

With the pre-registered 3% rate, the `retry_after` control drew no 429 at all, so it proved
nothing. It was re-run at a 30% rate (`--p-429 0.3`) alongside the same run with every protection
on. Both runs include 3 kills, so the second also exercises the restart fix below.

- Label: `retry-after-control`
- Git SHA: `909954e12e8492de4dc9c5832edf64ef5ba34371`
- Date: 2026-10-03T07:56:47Z
- Machine: Mac17,9; Apple M5 Pro; 15 cores; 24 GB
- go1.27.1; Bun 1.3.11; PostgreSQL 17.10 (Homebrew) on aarch64-apple-darwin25.4.0; Toxiproxy 2.12.0
- Command (from `integrations/slack-bridge`): `go run ./chaos --scenarios clean --messages 60 --kills 3 --seed 201 --p-429 0.3 --converge-timeout 60s --label retry-after-control --control-set retry_after;none --log-dir retry-logs --out slack-bridge-retry-after.json`
- Slack: simulated (the fake in `internal/slackfake`)

| Scenario | Runs | Source messages | Lost | Duplicated | Echoed | Text mismatches | Unconverged runs | Kills (fallback) | Kills survived |
|---|---|---|---|---|---|---|---|---|---|
| control:retry_after | 1 | 60 | 0 | 0 | 0 | 0 | 0 | 3 (0) | 3 |
| control:none | 1 | 60 | 0 | 0 | 0 | 0 | 0 | 3 (0) | 3 |
| all | 2 | 120 | 0 | 0 | 0 | 0 | 0 | 6 (0) | 6 |

| Scenario | Edits converged | Deletes converged | Out-of-order pairs, Toj to Slack | Out-of-order pairs, Slack to Toj |
|---|---|---|---|---|
| control:retry_after | 9 of 9 | 3 of 3 | 0 of 435 | 84 of 435 |
| control:none | 9 of 9 | 3 of 3 | 0 of 406 | 76 of 435 |
| all | 18 of 18 | 6 of 6 | 0 of 841 | 160 of 870 |

| Scenario | Retry deliveries | Duplicate deliveries | Late acks injected | Undeliverable (never answered by the bridge) | 429s injected | Calls during Retry-After | Replies dropped after commit |
|---|---|---|---|---|---|---|---|
| control:retry_after | 20 | 2 | 2 | 0 (0) | 14 | 634 | 0 |
| control:none | 18 | 1 | 5 | 0 (0) | 13 | 0 | 2 |
| all | 38 | 3 | 7 | 0 (0) | 27 | 634 | 2 |

| Scenario | Acks | Ack p50 (ms) | Ack p99 (ms) | Ack max (ms) | Acks at or over 3 s | Toj to Slack p50 / p99 (s) | Slack to Toj p50 / p99 (s) |
|---|---|---|---|---|---|---|---|
| control:retry_after | 79 | 1.1 | 2.0 | 2.0 | 0 | 4.54 / 11.54 | 0.19 / 7.24 |
| control:none | 82 | 1.1 | 2.2 | 2.2 | 0 | 7.46 / 11.99 | 0.23 / 7.22 |
| all | 161 | 1.1 | 2.2 | 2.2 | 0 | 6.64 / 11.99 | 0.22 / 7.24 |

## How the result changed during measurement

- **First sweep, `717282b`.** 0 of 2,000 lost, duplicated or echoed. One event delivery was given
  up by the fake after its last retry. The fake did not yet record whether any attempt had
  reached the bridge, so the cause could not be shown. It now counts that separately.
  ([JSON](slack-bridge-first-sweep.json); its "never answered" count reads 0 only because the
  field did not exist.)
- **Second sweep, `f31513b`.** 0 of 2,000 lost, duplicated or echoed, but **1 call during
  Retry-After**. The pacer's wait lived in memory, so a bridge killed within a second of a 429
  restarted and called at once. Fixed in `adc6991`: the wait is stored per channel in SQLite and
  restored at startup (`TestRetryAfterSurvivesARestart` fails without it).
  ([JSON](slack-bridge-before-retry-after-fix.json))
- **Final sweep, `adc6991`.** The tables above.

<details><summary>Second sweep tables (f31513b)</summary>

- Label: `sweep`
- Git SHA: `f31513b9a764aed8016cb38bf98d74d16ba94a7f`
- Date: 2026-10-03T07:39:10Z
- Machine: Mac17,9; Apple M5 Pro; 15 cores; 24 GB
- go1.27.1; Bun 1.3.11; PostgreSQL 17.10 (Homebrew) on aarch64-apple-darwin25.4.0; Toxiproxy 2.12.0
- Command (from `integrations/slack-bridge`): `go run ./chaos --runs 2 --messages 200 --kills 3 --seed 1 --label sweep --log-dir logs --out slack-bridge.json`
- Slack: simulated (the fake in `internal/slackfake`)

| Scenario | Runs | Source messages | Lost | Duplicated | Echoed | Text mismatches | Unconverged runs | Kills (fallback) | Kills survived |
|---|---|---|---|---|---|---|---|---|---|
| clean | 2 | 400 | 0 | 0 | 0 | 0 | 0 | 6 (0) | 6 |
| 3g | 2 | 400 | 0 | 0 | 0 | 0 | 0 | 6 (0) | 6 |
| resets | 2 | 400 | 0 | 0 | 0 | 0 | 0 | 6 (0) | 6 |
| reply_dropped | 2 | 400 | 0 | 0 | 0 | 0 | 0 | 6 (0) | 6 |
| reply_cut | 2 | 400 | 0 | 0 | 0 | 0 | 0 | 6 (0) | 6 |
| all | 10 | 2,000 | 0 | 0 | 0 | 0 | 0 | 30 (0) | 30 |

| Scenario | Edits converged | Deletes converged | Out-of-order pairs, Toj to Slack | Out-of-order pairs, Slack to Toj |
|---|---|---|---|---|
| clean | 57 of 57 | 26 of 26 | 0 of 9,900 | 300 of 9,900 |
| 3g | 58 of 58 | 22 of 22 | 0 of 9,606 | 186 of 9,703 |
| resets | 62 of 62 | 18 of 18 | 0 of 9,801 | 369 of 9,900 |
| reply_dropped | 70 of 70 | 10 of 10 | 0 of 9,801 | 317 of 9,702 |
| reply_cut | 53 of 53 | 24 of 24 | 0 of 9,801 | 570 of 9,900 |
| all | 300 of 300 | 100 of 100 | 0 of 48,909 | 1,742 of 49,105 |

| Scenario | Retry deliveries | Duplicate deliveries | Late acks injected | Undeliverable (never answered by the bridge) | 429s injected | Calls during Retry-After | Replies dropped after commit |
|---|---|---|---|---|---|---|---|
| clean | 59 | 16 | 22 | 0 (0) | 13 | 0 | 7 |
| 3g | 72 | 25 | 24 | 0 (0) | 8 | 0 | 6 |
| resets | 84 | 22 | 31 | 0 (0) | 6 | 1 | 6 |
| reply_dropped | 69 | 35 | 26 | 0 (0) | 10 | 0 | 13 |
| reply_cut | 87 | 29 | 28 | 0 (0) | 7 | 0 | 6 |
| all | 371 | 127 | 131 | 0 (0) | 44 | 1 | 38 |

| Scenario | Acks | Ack p50 (ms) | Ack p99 (ms) | Ack max (ms) | Acks at or over 3 s | Toj to Slack p50 / p99 (s) | Slack to Toj p50 / p99 (s) |
|---|---|---|---|---|---|---|---|
| clean | 544 | 0.8 | 1.9 | 2.4 | 0 | 1.42 / 4.77 | 0.16 / 7.10 |
| 3g | 537 | 0.9 | 2.2 | 6.7 | 0 | 1.57 / 3.66 | 15.14 / 31.84 |
| resets | 551 | 0.8 | 2.1 | 2.4 | 0 | 0.70 / 2.55 | 0.19 / 7.10 |
| reply_dropped | 547 | 0.8 | 1.9 | 2.1 | 0 | 1.01 / 14.02 | 0.21 / 7.16 |
| reply_cut | 564 | 0.6 | 1.9 | 3.5 | 0 | 0.12 / 1.51 | 0.17 / 7.19 |
| all | 2,743 | 0.8 | 2.0 | 6.7 | 0 | 0.83 / 13.66 | 0.23 / 29.75 |

</details>

<details><summary>First sweep tables (717282b)</summary>

- Label: `sweep`
- Git SHA: `717282b62a50203446e80a5be7d11d6389733063`
- Date: 2026-10-03T07:33:37Z
- Machine: Mac17,9; Apple M5 Pro; 15 cores; 24 GB
- go1.27.1; Bun 1.3.11; PostgreSQL 17.10 (Homebrew) on aarch64-apple-darwin25.4.0; Toxiproxy 2.12.0
- Command (from `integrations/slack-bridge`): `go run ./chaos --runs 2 --messages 200 --kills 3 --seed 1 --label sweep --log-dir logs --out slack-bridge.json`
- Slack: simulated (the fake in `internal/slackfake`)

| Scenario | Runs | Source messages | Lost | Duplicated | Echoed | Text mismatches | Unconverged runs | Kills (fallback) | Kills survived |
|---|---|---|---|---|---|---|---|---|---|
| clean | 2 | 400 | 0 | 0 | 0 | 0 | 0 | 6 (0) | 6 |
| 3g | 2 | 400 | 0 | 0 | 0 | 0 | 0 | 6 (0) | 6 |
| resets | 2 | 400 | 0 | 0 | 0 | 0 | 0 | 6 (0) | 6 |
| reply_dropped | 2 | 400 | 0 | 0 | 0 | 0 | 0 | 6 (0) | 6 |
| reply_cut | 2 | 400 | 0 | 0 | 0 | 0 | 0 | 6 (0) | 6 |
| all | 10 | 2,000 | 0 | 0 | 0 | 0 | 0 | 30 (0) | 30 |

| Scenario | Edits converged | Deletes converged | Out-of-order pairs, Toj to Slack | Out-of-order pairs, Slack to Toj |
|---|---|---|---|---|
| clean | 59 of 59 | 21 of 21 | 0 of 9,900 | 184 of 9,801 |
| 3g | 58 of 58 | 21 of 21 | 0 of 9,507 | 255 of 9,900 |
| resets | 62 of 62 | 19 of 19 | 0 of 9,900 | 365 of 9,900 |
| reply_dropped | 70 of 70 | 11 of 11 | 0 of 9,900 | 417 of 9,801 |
| reply_cut | 52 of 52 | 21 of 21 | 0 of 9,801 | 593 of 9,801 |
| all | 301 of 301 | 93 of 93 | 0 of 49,008 | 1,814 of 49,203 |

| Scenario | Retry deliveries | Duplicate deliveries | Late acks injected | Undeliverable (never answered by the bridge) | 429s injected | Calls during Retry-After | Replies dropped after commit |
|---|---|---|---|---|---|---|---|
| clean | 64 | 27 | 23 | 0 (0) | 9 | 0 | 6 |
| 3g | 69 | 27 | 28 | 0 (0) | 8 | 0 | 10 |
| resets | 85 | 26 | 27 | 0 (0) | 8 | 0 | 6 |
| reply_dropped | 74 | 33 | 33 | 1 (0) | 2 | 0 | 12 |
| reply_cut | 80 | 21 | 26 | 0 (0) | 3 | 0 | 11 |
| all | 372 | 134 | 137 | 1 (0) | 30 | 0 | 45 |

| Scenario | Acks | Ack p50 (ms) | Ack p99 (ms) | Ack max (ms) | Acks at or over 3 s | Toj to Slack p50 / p99 (s) | Slack to Toj p50 / p99 (s) |
|---|---|---|---|---|---|---|---|
| clean | 551 | 0.8 | 2.2 | 8.8 | 0 | 0.24 / 3.02 | 0.18 / 1.42 |
| 3g | 539 | 0.9 | 2.2 | 2.9 | 0 | 1.51 / 4.77 | 16.01 / 32.33 |
| resets | 549 | 0.8 | 2.1 | 2.4 | 0 | 1.19 / 2.98 | 0.22 / 7.10 |
| reply_dropped | 571 | 0.8 | 2.0 | 2.2 | 0 | 0.01 / 1.20 | 0.17 / 7.20 |
| reply_cut | 551 | 0.6 | 1.9 | 2.4 | 0 | 0.01 / 2.06 | 0.18 / 7.26 |
| all | 2,761 | 0.8 | 2.1 | 8.8 | 0 | 0.50 / 4.55 | 0.23 / 30.40 |

</details>

## Real Slack

Not run yet. It needs a free Slack workspace with the app from
`integrations/slack-bridge/slack-app-manifest.yaml` and a tunnel to the events endpoint. When it
runs, it will be about 100 messages each way plus edits and deletes, reconciled against
`conversations.history`, reported here separately as real but small. It also settles the two
unconfirmed points: whether message events carry metadata, and whether `conversations.history`
returns it.
