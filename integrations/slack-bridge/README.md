# Toj Slack bridge

A Go service that mirrors a Toj group into a Slack channel and back: new messages, edits and
deletes, in both directions, without losing, duplicating or echoing anything when Slack retries,
the network drops, or the bridge is killed.

Results under injected faults: [docs/results/slack-bridge.md](../../docs/results/slack-bridge.md).

## Status and decision

Decided 2026-10-02 by the founder: this ships as a **developer integration**, not a product
feature. Bots and integrations stay post-MVP for the app itself. The bridge uses only Toj's public client protocol, adds no server
endpoint and no bot account type, and is not deployed anywhere. Mirroring sends group text to
Slack, a US service, so bridging is opt-in per group, the bridge is a visible group member, and
Secret Chats can never be bridged. The privacy terms are in
[docs/privacy-data-map.md](../../docs/privacy-data-map.md#slack-bridge-developer-integration).

## How it works

```
Toj server ──difference pages + WebSocket hints──▶ bridge ──chat.postMessage/update/delete──▶ Slack
Toj server ◀──send / edit / delete (idempotent)─── bridge ◀──signed Events API deliveries──── Slack
                                                     │
                                               SQLite (one file)
```

**Toj to Slack.** The bridge is an ordinary signed-in Toj account. It keeps a pts cursor and pages
`/v1/sync/difference` whenever a WebSocket hint, a reconnect or a 15 s poll says there may be
more. Each page becomes rows in `outbound_intents` in the **same SQLite transaction** that
advances the cursor, so a crash either replays the page or finds its intents already written.
One goroutine per Slack channel drains that channel's intents in order through a pacer.

`chat.postMessage` has no idempotency key. So the intent is written first, `attempts` is
committed before each request, and an intent that was attempted before is looked up in
`conversations.history` by the metadata every post carries (the Toj group and message id) before
anything is reposted. A 429 or an `ok:false` answer means Slack wrote nothing, so the attempt is
undone and no lookup is needed.

**Slack to Toj.** The events handler verifies the signature (HMAC-SHA256 over
`v0:{timestamp}:{body}`, 5-minute window, constant-time compare), inserts the `event_id` into
`slack_events` with the payload, answers 200, and wakes the worker. A retry of a stored
`event_id` is answered 200 and dropped. One worker drains stored events in arrival order and
sends to Toj with `clientMsgId = UUIDv5(channel, ts)`, so Toj's own idempotency collapses a retry
even if the bridge lost every table. Edits carry `expectedEditVersion`; a 409 `edit_conflict`
retries on the version the server reports, and an older Slack edit delivered after a newer one is
dropped by comparing `edited.ts`.

**Loop guard, three layers.**
1. The bridge's own Toj messages (copies of Slack messages) are never mirrored.
2. Slack events whose `bot_id` or `app_id` is the bridge's, or whose `ts` is a post the bridge
   made, are dropped.
3. Events carrying the bridge's metadata are dropped. This layer covers the window where Slack
   accepted a post but the bridge died before recording its ts. Whether real Slack includes
   metadata in message events is not confirmed, so the measurement runs without it.

**Out of scope for the minimum bridge:** threads, reactions, files, private channels, more than
one workspace.

## Code

| Path | What |
|---|---|
| `cmd/bridge` | the service: configuration, login, HTTP server, shutdown |
| `internal/store` | SQLite schema and every durable decision |
| `internal/slack` | signature check, events handler, Web API client, per-channel pacer |
| `internal/toj` | Toj client: v2 session with crash-safe refresh rotation, difference loop, hints |
| `internal/bridge` | the two directions and the loop guard |
| `internal/faults` | negative controls and kill points used by the measurement |
| `internal/slackfake` | fake Slack that injects retries, duplicates, reordering, late acks, 429s and lost replies |
| `internal/tojfake` | in-memory Toj for unit tests |
| `chaos` | fault driver: real Toj server, Toxiproxy, fake Slack, SIGKILLs |

## Running it

1. Create the Slack app from [slack-app-manifest.yaml](slack-app-manifest.yaml) (the scopes are
   explained there) and install it to the workspace. Invite the bot to the channel.
2. Expose the events endpoint, for example `cloudflared tunnel --url http://127.0.0.1:8790`, and set
   the manifest's request URL to `https://<tunnel host>/slack/events`.
3. Sign the bridge's Toj account in once. Outside production the server returns the code; on a
   hosted server it is sent out of band and the command prompts for it:

   ```
   TOJ_BASE_URL=http://127.0.0.1:8788 BRIDGE_DB=bridge.db go run ./cmd/bridge login --phone +1650...
   ```
4. Add that account to the Toj group, then run:

   ```
   TOJ_BASE_URL=http://127.0.0.1:8788 BRIDGE_DB=bridge.db BRIDGE_PAIRS=<groupId>=<channelId> \
   SLACK_SIGNING_SECRET=... SLACK_BOT_TOKEN=xoxb-... SLACK_APP_ID=A... go run ./cmd/bridge
   ```

The bridge's Toj session expires after 180 days at most (30 days idle), after which it must sign
in again.

## Tests

```
go test -race ./...                                   # unit tests, no network or database
DATABASE_URL=postgres://localhost:5432/toj_slackbridge_chaos go run ./chaos --runs 2   # fault sweep
```

Each mechanism has a unit test and a negative control that turns it off and shows the failure it
prevents (`TOJ_BRIDGE_NEGATIVE_CONTROL`, refused unless `TOJ_BRIDGE_ALLOW_NEGATIVE_CONTROL=1`).
