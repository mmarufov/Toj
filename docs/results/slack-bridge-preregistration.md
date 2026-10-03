# Slack bridge under faults: pre-registration

Written and committed before the first measured run. The results file,
[slack-bridge.md](slack-bridge.md), reports against these definitions. If a definition changes
after a measured run, the change and its reason go in the results file.

## What is measured

The bridge (`integrations/slack-bridge`) mirrors one Toj group into one Slack channel and back.
The chaos driver (`integrations/slack-bridge/chaos`) runs:

- the real Toj server (`bun run src/cloud.ts`) on a disposable local Postgres database;
- Toxiproxy between the bridge and Toj, with the five scenarios from the sync chaos harness
  (#52): `clean`, `3g`, `resets`, `reply_dropped`, `reply_cut`;
- the fake Slack (`internal/slackfake`), which injects Slack-side faults in every scenario;
- the bridge as a separate process, killed with SIGKILL during the run.

Every number that involves Slack comes from the fake and is reported as **simulated Slack**.
The real-Slack smoke test is reported separately.

## Workload per run

- One new Toj group with three members: two human accounts and the bridge account.
- `--messages` source messages, half written in Toj (alternating between the two humans) and half
  in Slack (alternating between two fake Slack users). Default 200.
- Every source text carries a unique token, so a mirror can be attributed to its source without
  trusting any bridge mechanism. About one in five also contains `&`, `<` or `>` to exercise
  Slack's escaping.
- Edits: each source message is edited once by its author with probability 0.15, and a second
  time with probability 0.05. Edits keep the token.
- Deletes: each source message is deleted by its author with probability 0.05, after any edits.
- Edits and deletes are scheduled 0 to 2 s after the message, so some land before the bridge has
  mirrored the message.
- Seeds: run *i* of a sweep uses seed `--seed + i`. The seed fixes the workload and the fake's
  fault draws. Process timing is not deterministic.

## Slack-side faults (all scenarios)

| Fault | Setting |
|---|---|
| Duplicate delivery of an event (no retry headers) | probability 0.05 |
| Reordering | each event's first delivery is delayed by a uniform 0 to 300 ms |
| Acknowledgement treated as late (Slack retries with `http_timeout`) | probability 0.05 |
| Retry schedule after a failed delivery | 1 s, 6 s, 30 s (Slack's is about 0 s, 1 min, 5 min; compressed so a run ends in minutes) |
| Delivery timeout | 3 s, as Slack |
| 429 on a channel call, with `Retry-After: 1` | probability 0.03 per call |
| Write committed, then the connection closed with no reply | probability 0.03 per `chat.postMessage`, `chat.update`, `chat.delete` |
| Metadata in message events | off: whether real Slack includes it is unconfirmed, so the bridge is measured without that layer |

The bridge's pacer spaces calls per channel by 20 ms in these runs. Slack documents about one post
per second per channel; the real-Slack smoke test uses 1 s.

## Kill points

`--kills` kills per run (default 3). Kill *k* of a run uses point `k mod 4` of this list:

1. `after_slack_post`: Slack accepted `chat.postMessage`, the ts is not recorded.
2. `after_toj_send`: Toj committed a send from Slack, the message map row is not written.
3. `after_event_ack`: a Slack event was stored and acknowledged, the worker has not run it.
4. `random`: SIGKILL after a uniform 0.5 to 3 s of running.

The bridge is armed with `TOJ_BRIDGE_KILLPOINT=<point>@<n>` (*n* uniform in 1 to 5). It prints a
line on reaching the point and blocks; the driver then sends SIGKILL. If an armed point is not
reached within 20 s, the driver kills at that moment and records the kill as `random (fallback)`.
After each kill the driver restarts the bridge within 0.2 to 0.5 s. After the last kill the bridge
runs unarmed until the run ends.

## Definitions

A **source message** is a message a human wrote, on either side, during the run. Its **origin** is
the side it was written on. A **mirror** is a message the bridge created on the other side. A
message is attributed to a source by the source's token in its text, or for a Toj message that is
now a tombstone (text emptied), by the Slack metadata or the deterministic `clientMsgId` the
driver can recompute. Order on Toj is `msg_id`; order on Slack is `ts`.

- **Lost**: a source message that is live at the end of the run (not deleted by its author) and
  has no live mirror once the run has converged or timed out.
- **Duplicated**: a source message for which more than one mirror was ever created, live or
  deleted.
- **Echoed**: a mirror of a mirror, that is, a message created by the bridge on the same side as
  its source's origin.
- **Out-of-order pair**: two source messages from the same origin, each with exactly one mirror,
  whose mirrors are in the opposite order to the sources. Reported per direction as a count of
  pairs, out of the number of pairs compared. Slack-to-Toj is not expected to be 0: Slack does
  not order deliveries, and Toj assigns `msg_id` at commit.
- **Edit convergence**: for each live source message that was edited, its mirror's final text
  equals the expected rendering of the source's final text. Toj to Slack: the same text, Slack
  escaped. Slack to Toj: `<slack name>: <unescaped text>`.
- **Delete convergence**: for each deleted source message whose mirror was created, the mirror is
  deleted.
- **Retries absorbed**: Slack deliveries that were retries or injected duplicates (from the
  fake's counters), with the duplicates count above as the check that they were absorbed.
- **429s honoured**: injected 429s, and calls the bridge made to that channel while
  `Retry-After` was still running (a violation). Honoured = 429s with no violation.
- **Kills survived**: kills performed in runs that then converged with 0 lost, duplicated and
  echoed.
- **Mirror latency**: Toj to Slack, from the Toj send acknowledgement to the fake Slack creating
  the post. Slack to Toj, from the fake Slack creating the message to Toj's `server_ts` on the
  mirror. Both clocks are this machine's. Reported as p50 and p99 (nearest rank) per scenario,
  including kill downtime.
- **Ack latency**: the fake's measured time from sending an event to receiving the bridge's
  HTTP response, for every delivery that got a response. Reported as p50, p99, max, and the
  number over 3 s.

A run **converges** when every live source message has a live mirror with the expected text,
every deleted source message's mirror is deleted, the fake has no delivery in flight, and this has
held for 2 s. The run times out after 120 s; a timed-out run is reported as unconverged and its
counts are still reported.

## Pass criteria for the headline

- 0 lost, 0 duplicated, 0 echoed, in both directions, across every run of the sweep.
- 0 unconverged runs.
- Every acknowledgement under 3 s.

Out-of-order pairs, latency and fault counts are reported, not gated.

## Negative controls

Each is a separate short run with one protection off (`TOJ_BRIDGE_NEGATIVE_CONTROL`), and is
expected to make its count non-zero:

| Control | Expected |
|---|---|
| `loop_guard` | echoed > 0 |
| `event_dedupe` (event_id table and message-map check) | duplicated = 0, because Toj's deterministic `clientMsgId` still collapses retries |
| `event_dedupe,client_msg_id` | duplicated > 0 |
| `reconcile` (kills at `after_slack_post`) | duplicated > 0 |
| `cursor_tx` (kills at `after_cursor_commit`) | lost > 0 |
| `retry_after` | 429 violations > 0 |

## Commands

From `integrations/slack-bridge`, with Toxiproxy on 127.0.0.1:18474 and a migrated local database:

```
DATABASE_URL=postgres://localhost:5432/toj_slackbridge_chaos \
  go run ./chaos --runs 2 --messages 200 --kills 3 --out ../../docs/results/slack-bridge.json
```

The driver refuses a non-local database, a hosted `NODE_ENV`, and Toxiproxy's default port 8474.
