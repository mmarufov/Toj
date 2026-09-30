# Results: session, receipt, client-address and fan-out hardening

Every number below comes from a command in this file. All measurements ran on a laptop against a
local PostgreSQL, not on staging and not under real traffic. Toj has zero real users.

| | |
|---|---|
| Code measured | `e8258bdc8f35519726dfa8360dacfe8f62007609` (this branch; later commits change only comments and docs) |
| Date | 2026-09-30 |
| Machine | Apple M5 Pro, 24 GB, macOS 27.0.1 (26A434) |
| Runtime | Bun 1.3.11, PostgreSQL 17.10 (Homebrew), local socket |

## 1. How Render delivers the client address

Checked with curl on 2026-09-30, from a residential connection. The client's own address is
written `<client>` here. `httpbin.onrender.com` is a public header-echo service hosted on Render,
which shows exactly what a Render app receives; `api.tojchat.tech` is Toj staging on Render.

```
curl -s -H 'X-Forwarded-For: 203.0.113.7' https://httpbin.onrender.com/headers
  "cf-connecting-ip": "<client>"
  "true-client-ip":   "<client>"
  "x-forwarded-for":  "203.0.113.7,<client>, 162.159.115.23, 10.25.18.179"

curl -s -H 'True-Client-IP: 203.0.113.9' https://httpbin.onrender.com/headers
  "true-client-ip":   "<client>"          (overwritten)

curl -s -o /dev/null -w '%{http_code}' -H 'CF-Connecting-IP: 203.0.113.8' https://httpbin.onrender.com/headers
  403  (body: "error code: 1000")
curl -s -o /dev/null -w '%{http_code}' -H 'CF-Connecting-IP: 203.0.113.8' https://api.tojchat.tech/health
  403  (body: "error code: 1000")
curl -s -o /dev/null -w '%{http_code}' https://api.tojchat.tech/health
  200
```

What this establishes:

- The request reaches the app from Render's proxy (`10.x`, the last `X-Forwarded-For` hop), so the
  socket peer is shared by every client.
- `X-Forwarded-For` keeps whatever the client sent and appends to it. Its leftmost entry is
  client-controlled.
- `CF-Connecting-IP` cannot be supplied by a client: Cloudflare refuses such a request at the edge,
  on Toj's own domain as well as on the echo service. On every other request it carries the
  connecting address.

The server therefore reads `TOJ_CLIENT_IP_HEADER=cf-connecting-ip`
(`server/src/cloud.ts`, `clientNetworkAddress`). What was not verified: the echo service's Render
region (staging is Frankfurt); requests from inside Cloudflare's own network (Workers), which
Cloudflare documents as carrying a fixed Worker address; and IPv6 clients.

## 2. Statements per message send, at 2 and 200 members

```
DATABASE_URL=postgres://localhost:5432/<fresh migrated db> bun run scripts/measure-fanout-statements.ts
```

The script counts every SQL statement one `sendMessage` issues, after a warm-up send, with a
`Proxy` over the connection (`server/src/statement-count.ts`). Groups did not exist before
`0df5aa9`, so on every tree the extra members are rows inserted into a direct dialog's
`dialog_members`; each tree fans out to every active member. For the two older trees the script
and `src/statement-count.ts` were copied into a detached worktree at that commit.

| Tree | 2 members | 200 members | Per extra member |
|---|---|---|---|
| `2ab4b42` (`0df5aa9^`, before group chats) | 20 | 812 | 4 |
| `a796a92` (main before this branch) | 23 | 221 | 1 |
| `e8258bd` (this branch) | 22 | 22 | 0 |

Per-member statements on `2ab4b42`, classified by statement text at 2 and 5 members:
`UPDATE account_sync_states`, `INSERT INTO account_events`, `INSERT INTO push_deliveries` (the
fan-out, 3 per member) and `SELECT pg_notify` (the sync wake-up, 1 per member). On `a796a92` the
fan-out was already constant and the remaining 1 per member was the wake-up, which this branch
sends as one statement (`server/src/sync-wakeup.ts`).

The fan-out function alone (`fanoutDialogEvent`, `server/src/fanout.ts`) issues 4 statements at 2
and at 200 members: the unarchive update, the recipient select, one statement that locks every
recipient's sync state in account-UUID order, bumps it and inserts the events, and the push rows.
Pinned by `server/src/fanout.test.ts`, "a group event costs the same statements at 2 and 200
members", in a real group.

Not measured here: the 4 catalog queries of the dialog-preference schema probe that run on every
send. `dialogPreferenceSchemaState` caches per connection object and each transaction is a new
one. They are constant in group size.

## 3. Overlapping group sends

`server/src/fanout.test.ts`, "64 overlapping group sends on shared members never deadlock":
16 accounts in 8 groups of 10, each group a different rotation of the same people, and 64
`sendMessage` calls launched at once through a 64-connection pool, so every transaction is open at
the same time.

| Lock order in the fan-out | Runs | Sends failing with SQLSTATE 40P01 |
|---|---|---|
| account-UUID order (this branch) | 2 (the N7 unmutated run and the full suite, both at `e8258bd`) | 0 of 64 in both |
| `ORDER BY random()` (negative control N7) | 3 | 41, 37 and 47 of 64 |

The negative-control runner reports only pass or fail. The per-run counts for N7 came from the
same mutation in a detached worktree at `e8258bd` with one added line in the test that printed the
rejection codes (`bun test src/fanout.test.ts -t "64 overlapping"`, three times): every rejection
was `errno 40P01`, message `deadlock detected`.

The test also asserts `pg_stat_database.deadlocks` did not move, and that every account's event
log is gapless with exactly one event per send it received.

## 4. Concurrent identical sends

`server/src/m3.test.ts`, "50 concurrent sends with the same client_msg_id collapse to one
message": 50 identical `sendMessage` calls at once. Result: 1 message, 1 `message.new` event per
participant, one non-duplicate answer, and all 50 answers carry the same `msgId` and `senderPts`.
With both idempotency layers disabled (the `send_requests` claim and the `recoverCanonical`
rebuild, control N10), the test fails. With either layer alone it passes, because the other one
still collapses the sends.

## 5. Negative controls

```
cd server && bun run scripts/negative-controls.ts
```

For each claim the runner checks out HEAD into a temporary worktree, runs the test unmodified (it
must pass), applies one mutation and runs it again (it must fail). Run at `e8258bd`, 2 min 32 s:

| Id | Claim | Mutation | Unmutated | Mutated runs failing |
|---|---|---|---|---|
| N1 | Legacy bearer tokens stop at the session idle and absolute bounds | expiry check removed | pass | 1/1 |
| N2 | A v2 server refuses to mint legacy credentials | 426 branch removed | pass | 1/1 |
| N3 | A lost upgrade response is replayed | retired legacy token answered with 401 | pass | 1/1 |
| N4 | The per-network window keys on the edge-set client address | key on leftmost `X-Forwarded-For`, else the peer | pass (6 tests) | 1/1 |
| N5 | A late retry never re-runs a message mutation | receipts deleted at 24 h | pass | 1/1 |
| N5g | A late retry never re-runs a group mutation | receipts deleted at 24 h | pass | 1/1 |
| N6 | A mutation id reused with different input is a 409 | fingerprint not compared | pass | 1/1 |
| N7 | 64 overlapping group sends never deadlock | random lock order | pass | 3/3 |
| N8 | A group send costs the same statements at 2 and 200 members | one `pg_notify` per recipient | pass | 1/1 |
| N9 | The fan-out is 4 statements at any size | one lock statement per recipient | pass | 1/1 |
| N10 | 50 identical sends give one message and one answer | both idempotency layers off | pass | 1/1 |
| N11 | `/ready` fails closed without the receipt columns | check left out of the status | pass | 1/1 |
| N12 | Refresh-rotation receipts replay after any delay (PR #38) | read predicate `receipt.expires_at > now` restored | pass | 1/1, `refresh token reuse detected` |

N12 re-verifies the claim in PR #38 that its first test fails against the previous predicate.

## 6. Full backend suite

Run as CI runs it: fresh databases, `bun run migrate`, then `bun test --timeout 15000 <file>` one
file at a time (a single parallel `bun test` exhausts local PostgreSQL connections), then the
envelope-canary and envelope passes over `m3`, `drafts`, `cloud-productivity` and `reports`.

| Tree | Per-file suite | envelope-canary pass | envelope pass |
|---|---|---|---|
| `e8258bd` (this branch) | 437 pass, 0 fail, 4 skipped by design (search benchmark) | 148 pass, 0 fail | 148 pass, 0 fail |
| `a796a92` (main) | 419 pass, 0 fail, 4 skipped | not run | not run |

The 18 added tests: 6 in `auth-security`, 6 in `client-address`, 2 in `fanout`, 3 in `m3`
(late mutation retries, mutation-id conflicts, receipt-schema readiness) and 1 in `groups`. The
identical-send test in `m3` was widened from 2 to 50 requests.

## Caveats

- Local PostgreSQL on one laptop. Statement counts are exact and do not depend on the machine;
  the concurrency results depend on timing, and a pass is evidence rather than proof.
- Nothing here was measured on staging. At the time of writing staging runs an older revision
  (its `/ready` has no `otpSchema` key); the deployment of this branch is a separate step.
