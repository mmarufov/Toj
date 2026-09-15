# Groups v1 — Engineering Plan (Final)

Status: ready to implement
Baseline: `f245d96` (`origin/main`)
Branch: `mmarufov/pasted-spec-plan`
Capability policy: `groups_v1` stays unadvertised and its routes stay closed until the final rollout gate.

---

## 0. Outcome

Build Groups v1 as the first production use of Toj's generic dialog model. Reuse the existing message,
media, outbox, bootstrap, difference-sync, and push machinery. Add the missing group contract,
authorization rules, replica state, and UI.

Ship as six gated slices. Slice 0 hardens shared hot paths that groups will multiply by 100×; it ships
with the feature switched off and is judged on latency, not features. Slice 1 is a walking skeleton:
three registered accounts create a named group, see it on a second device, and exchange text online and
offline. Administration follows only after that path is solid.

Calls stay out of this epic. No group UI may add call controls or touch `CallCoordinator`, `CallScreen`,
CallKit, PushKit, or WebRTC.

### Changes from the previous draft

The previous draft was reviewed against the codebase. Fourteen findings changed the design. They are
folded in below; this table exists so reviewers of the earlier draft know what moved.

| # | Finding | Where it lands |
|---|---|---|
| 1 | Orphan-media reaper deletes group photos; FK could kill the whole maintenance loop | §5.1, §5.6 |
| 2 | Revision gating as written silently drops messages | §4.3 |
| 3 | Event fanout is a per-member round-trip loop that holds the dialog lock and 200 account locks | §5.4 |
| 4 | No profile hydration for departed senders or service-message subjects | §4.2, §5.5 |
| 5 | Bootstrap member query leaks the full historical membership | §5.5 |
| 6 | No consent or rate limit on being added to a group | §5.7 |
| 7 | No retention for events or idempotency rows | §5.6 |
| 8 | Client-supplied dialog id collision is an existence oracle | §4.1 |
| 9 | Read-side dialog locks are unnecessary and block administration | §5.3 |
| 10 | Lock-order inversion between media send and group-photo update | §5.3 |
| 11 | Forwarding defeats the media-revocation claim | §4.6, §12 |
| 12 | Re-add semantics undefined (`joined_at`, `last_read_msg_id`) | §4.4 |
| 13 | Async local purge has no durable queue | §6.5 |
| 14 | Routes must hard-fail when the flag is off, not merely stop advertising | §5.8, §11 |

---

## 1. Non-negotiable invariants

Every design decision below serves one of these. If an implementation choice violates one, the choice is
wrong, not the invariant.

1. **No silent, non-recoverable failure.** Every failure is either retried automatically or surfaced to
   the user with a recoverable action.
2. **PTS never advances past an unapplied message.** Group metadata may be revision-gated. Message
   content may not be.
3. **The dialog row is the linearization point** for membership and message ordering. A concurrent send
   and removal cannot both act on a stale membership snapshot.
4. **Local-first is unconditional.** No group API call is on the critical path to the first cached frame
   of the chat list or a conversation.
5. **Direct-chat behavior is unchanged**, byte-for-byte in presentation fixtures and behaviorally in
   receipts, ordering, and push.
6. **Fanout is O(members) events, O(1) round trips.** Any per-member SQL loop is a defect.
7. **Every account id in a payload arrives with a profile.** A client never renders an id it cannot name.
8. **No false privacy claim.** Groups use the cloud-chat model. They are not labelled end-to-end
   encrypted and do not reuse the direct-chat lock pill.

---

## 2. What already exists

| Primitive | Location | Decision |
|---|---|---|
| `dialogs.type IN ('direct','group')`; roles owner/admin/member | `server/src/schema.sql:136-164` | Keep, extend |
| Unlocked active-member check | `server/src/sync.ts:52-57` | Replace with lock-aware helper |
| Per-dialog ordered `msg_id`, account-event fanout | `server/src/sync.ts:327-360` | Keep shape, make set-based |
| Idempotent sends and message mutations | `server/src/schema.sql:317-348` | Reuse; mirror for group mutations |
| Resumable bootstrap | `server/src/sync.ts:658-812` | Reuse, de-N+1, add group metadata |
| History and read watermarks | `server/src/sync.ts:814-929` | Reuse with group read semantics |
| Media access check | `server/src/media.ts:475-489` | Extend for group photos |
| Global lock order comment | `server/src/sync.ts:10-13` | **Amend** — it is the only written record |
| Maintenance cleanup | `server/src/ops.ts:106-174` | **Extend** — group photos, retention |
| WS hints + durable APNs outbox | `server/src/cloud.ts`, `server/src/push.ts` | Reuse |
| Local replica tables | `Toj/Core/Store/CloudLocalStore.swift:2451-2575` | Extend via migration `v9-groups` |
| Global local `profiles` table (no GC) | `CloudLocalStore.swift:2473` | Reuse as-is; **do not add GC** |
| Atomic/resumable bootstrap staging | `CloudLocalStore.swift:539-745`, `3380-3658` | Reuse |
| Registered-contact discovery | `ContactsFeature.swift:48-76` | Reuse for the member picker |
| Capability bit `.groups` | `MessagingPresentation.swift:21` | Map only from `groups_v1` |
| Demo group sheet | `RichDemoSurfaces.swift:283-343` | Replace, do not extend |

Xcode uses `PBXFileSystemSynchronizedRootGroup`. New Swift files in `Toj/`, `TojTests/`, `TojUITests/`
are picked up automatically; no `project.pbxproj` edits are required.

### Gaps that matter

- No `groups_v1` capability (`server/src/cloud.ts:94-112`), no group routes.
- `account_events` type constraint lacks role-change, leave, profile-update, close (`schema.sql:299-314`).
- Difference and local inserts hardcode `direct` (`CloudLocalStore.swift:872`, `1455`, `1493`, `1216`).
- Local `dialog_members` has no active state, no `joined_at`/`left_at`.
- `TimelinePresentationBuilder` clusters by `mine` only — no sender identity (`TimelinePresentationBuilder.swift:3-7`, `:57-67`).
- The service row understands call-history strings only.
- The demo group sheet picks chat dialogs, not contacts, and creates nothing.

---

## 3. Fixed product decisions

1. **Identity and idempotency.** The client generates a UUIDv4 `groupId` once; it becomes `dialogs.id`.
   The same UUID is the creation idempotency key. Using the final id from the start removes the
   local-id-to-server-id remap class of bugs entirely.

2. **Size and naming.** Minimum creator + 1 active registered account. Maximum 200 active members
   including the owner. Title: trim surrounding whitespace, 1–128 Unicode scalars, ≤256 UTF-8 bytes.
   Member ids are de-duplicated and sorted before hashing or locking.

3. **History.** Every active member reads complete history. No history-visibility controls in v1. After
   removal or leaving, the account cannot fetch history, media, profile, or message payloads — with the
   single documented exception in §4.6. Re-adding restores full-history access.

4. **Roles.**

   | Action | Owner | Admin | Member |
   |---|---:|---:|---:|
   | Send / read / react / reply / forward | yes | yes | yes |
   | Add members | yes | yes | no |
   | Remove a regular member | yes | yes | no |
   | Remove an admin | yes | no | no |
   | Promote / demote admin | yes | no | no |
   | Change group name or photo | yes | yes | no |
   | Transfer ownership | yes | no | no |
   | Leave | after transfer, or close if last | yes | yes |
   | Change own notification setting | yes | yes | yes |

   The old owner becomes an admin after an explicit transfer. Account deletion transfers ownership to the
   oldest active admin, then the oldest active member, ordered by `(joined_at, account_id)`. If nobody
   remains, the group closes.

5. **Read state.** Direct read receipts unchanged. Group reads update the reader's watermark and sync to
   that account's **own devices only** — never to the other 199. Outgoing group messages show `sent`.
   No per-member "seen by" in v1.

6. **Messages.** Existing text, reply, reaction, forward, media, voice-note, edit/delete, history, and
   outbox paths are the message engine. Mentions use structured entities with UTF-16 offsets and target
   account ids; the server validates ranges and active membership. Service messages are structured and
   localized on-device — never English strings from the server.

7. **Photos.** Group photos reuse the resumable media pipeline with `media_objects.purpose='group_photo'`.
   The optimistic local photo renders immediately; upload and `dialog.profile_updated` may complete after
   creation.

8. **Notifications.** The profile toggle is real. Per-member `notification_mode`; muted members get silent
   sync rows and no alert bit. Mentions-only and custom sounds are later work.

9. **Security language.** Cloud-chat security model, encrypted at rest. Do not label group timelines
   end-to-end encrypted; do not reuse the "Private conversation" pill.

---

## 4. Contract

### 4.1 Group creation and idempotency

`POST /v1/groups` with `{ groupId, title, memberIds[], clientMutationId? }`.

Server algorithm:

1. Validate `groupId` is a well-formed UUIDv4. Reject otherwise (`400 invalid_group_id`).
2. Compute `fingerprint = sha256(normalized_title ‖ sorted_deduped_member_ids)`.
3. Claim `group_create_requests` on `(creator_account_id, client_group_id)`:
   - New row → proceed.
   - Existing row, same fingerprint, `completed` → return the original group (`duplicate: true`).
   - Existing row, same fingerprint, `pending` → `409 create_in_progress`.
   - Existing row, different fingerprint → `409 idempotency_conflict`.
4. `INSERT INTO dialogs (id, ...) VALUES (${groupId}, ...) ON CONFLICT (id) DO NOTHING`.
   **If no row was inserted, return `409 idempotency_conflict`** — the identical response as step 3's
   conflict branch, with no distinguishing detail. This is deliberate: the dialog id may belong to another
   account, and a distinguishable error would be an existence oracle over dialog ids.
5. Insert members, service message, events, push rows. Commit. Send WS hints post-commit.

The client's local row already carries the final UUID, so success is a state transition, not a key rewrite.

### 4.2 Core response types

```text
Group {
  id, title, photo: CloudMedia?, revision, memberCount,
  selfRole, notificationMode, createdBy, createdAt, closedAt?
}

GroupMember {
  accountId, role, joinedAt, isActive
}

Profile {                         // the side-payload element
  accountId, firstName, lastName, displayName, bio, birthday, colorIndex, updatedAt
}
```

`GroupMember` no longer embeds a profile. Instead:

> **Every response that can reference an account id carries a top-level `profiles: Profile[]`
> covering every account id reachable from that payload** — message senders, service-message actors and
> subjects, mention targets, reply-quote authors, members, and forward origins.

This applies to `POST /v1/sync/difference`, `GET /v1/sync/history`, every bootstrap page, and every
`/v1/groups/*` response. This is how Telegram ships `users: Vector<User>` on every response, and it is
the only mechanism that makes two cases renderable at all:

- A member sends 500 messages then leaves. Bootstrap's profile query (`sync.ts:766`) filters
  `left_at IS NULL`, so today their profile is never delivered and every bubble renders nameless.
- "Alice removed Bob" needs Bob's profile. Bob is by definition not an active member.

The local `profiles` table (`CloudLocalStore.swift:2473`) is already global, keyed by `account_id`, with
no per-dialog GC. Profiles land there directly. **Do not add profile garbage collection.** The previous
draft's "retain the profile only if another dialog still references it" would have introduced exactly the
deletion that breaks departed-sender rendering.

Do not flatten group fields onto `CloudUpdate` (`Toj/Core/Cloud/CloudAPI.swift:108-128`) — it already has
19 optional fields. Add nested optional `group` and `member` payloads so decoding stays explicit.

### 4.3 Events and the revision rule

Group lifecycle events: `dialog.created`, `member.added`, `member.removed`, `member.role_changed`,
`member.left`, `dialog.profile_updated`, `dialog.closed`.
Existing: `message.new`, `message.edited`, `message.deleted`, `reaction.updated`, `read.updated`.

Every event carries `dialog_type`. Group lifecycle events additionally carry `group_revision` and
`member_count`.

**The revision rule, stated precisely:**

- `group_revision` gates **group metadata and membership rows only** — title, photo, `member_count`,
  `self_role`, `access_state`, and `dialog_members` rows.
- `group_revision` **never** gates `message.new`, `message.edited`, `message.deleted`,
  `reaction.updated`, or `read.updated`. Message events are ordered by PTS and per-dialog `msg_id` and
  are always applied.
- REST hydrates (`GET /v1/groups/:id`, `GET /v1/groups/:id/members`) are stamped with the same revision
  and pass through the same gate. This is the race the gate actually exists for: a hydrate returning
  revision 7 while the event stream is still at 5.
- Apply metadata only when `incoming_revision > local_revision`, then store the new revision. PTS always
  advances.

The earlier draft said "clients ignore an event older than the locally stored revision" without scoping.
Read literally, a message sent at revision N followed by a rename at N+1 would cause the client to
**discard real messages and advance PTS past them** — unrecoverable without a full bootstrap, and
invisible. That violates invariant 2. The scoping above is not a nicety.

`member_count` rides on every group lifecycle event so a client that misses one event and recovers via a
later one cannot drift.

For a newly added member, emit `dialog.created` to that account (triggering a group/profile/member
hydrate); existing members receive `member.added`. A removed account receives a non-sensitive
access-revocation event, never a final message payload.

### 4.4 Membership epochs and re-adding

`dialog_members` keeps one row per `(dialog_id, account_id)`. On re-add:

- `left_at → NULL`, `joined_at → now()`, `role → 'member'`, `invited_by → actor`.
- `last_read_msg_id` **resets to the group's `last_msg_id` at re-add time.** Preserving the stale
  watermark would show a re-added member an unread count spanning their entire absence, which for a busy
  group is a five-digit badge.
- Ownership succession orders by `(joined_at, account_id)` and therefore uses the re-join time. This is
  intended and documented: succession favours continuous presence.

Membership history is not auditable in v1; the service-message timeline is the record.

### 4.5 Routes

| Method | Route | Purpose |
|---|---|---|
| `POST` | `/v1/groups` | Idempotent create from `groupId`, title, member ids |
| `GET` | `/v1/groups/:id` | Group summary, caller role, revision |
| `GET` | `/v1/groups/:id/members` | Keyset-paginated active members |
| `POST` | `/v1/groups/:id/members` | Add one or more members (all-or-nothing) |
| `DELETE` | `/v1/groups/:id/members/:accountId` | Remove a member |
| `PATCH` | `/v1/groups/:id/members/:accountId` | Promote / demote |
| `PATCH` | `/v1/groups/:id` | Change title or photo |
| `POST` | `/v1/groups/:id/transfer-owner` | Atomic ownership transfer |
| `POST` | `/v1/groups/:id/leave` | Leave, with successor when required |
| `PUT` | `/v1/groups/:id/notifications` | Update caller's notification mode |

Every mutating route after create takes a `clientMutationId`. Reuse with different normalized input →
`409 idempotency_conflict`.

**Multi-member add is all-or-nothing.** If any target fails validation the whole call fails and names the
failing account ids in the error body so the UI can deselect them. Partial success would leave the client
with no way to reconcile which adds landed.

### 4.6 Errors

`group_not_found`, `not_group_member`, `group_access_revoked`, `insufficient_group_role`,
`owner_transfer_required`, `member_unavailable`, `member_limit_reached`, `idempotency_conflict`,
`create_in_progress`, `stale_group_revision`, `invalid_group_id`, `add_not_permitted`, `rate_limited`.

`410 group_access_revoked` for a former member, so iOS marks queued work terminal rather than treating the
session as expired. `429 rate_limited` carries `Retry-After`, matching `calls.ts:606`.

**Documented limitation.** `requireMediaAccess` (`media.ts:475-489`) grants access when the media object
is referenced by a visible message in *any* dialog the caller belongs to. A member who forwards group
media into their own direct chat before removal retains server-side access to that object. Telegram
behaves identically. Copy-on-forward would close it at the cost of duplicate storage; it is out of scope
for v1. The Definition of Done in §14 is scoped to match reality rather than overstating the guarantee.

---

## 5. Backend

### 5.1 Schema

Extend `server/src/schema.sql` and `schema-concurrent.sql`. All DDL idempotent. Indexes on populated hot
tables via `CREATE INDEX CONCURRENTLY` in `schema-concurrent.sql` (which already has the invalid-shell
repair pattern). Migrations run with the capability flag off.

1. **`dialogs`** — `revision BIGINT NOT NULL DEFAULT 0`, `closed_at TIMESTAMPTZ NULL`,
   `photo_media_id UUID NULL REFERENCES media_objects(id) ON DELETE SET NULL`.

   `ON DELETE SET NULL` is load-bearing. With the default `NO ACTION`, the orphan reaper's `DELETE FROM
   media_objects` (`ops.ts:156-164`) raises an FK violation, `cleanupExpiredData` throws, and the whole
   maintenance loop (`ops.ts:187`) dies — taking OTP, push-delivery, and bootstrap-snapshot cleanup with
   it. See §5.6 for the reaper predicate that prevents the delete in the first place; the FK action is the
   second line of defence.

2. **`dialog_members`** — `invited_by UUID NULL REFERENCES accounts(id)`,
   `notification_mode TEXT NOT NULL DEFAULT 'all' CHECK (notification_mode IN ('all','muted'))`.
   Keep `joined_at`/`left_at` as the membership epoch. Add:
   - `CREATE UNIQUE INDEX ... ON dialog_members(dialog_id) WHERE role='owner' AND left_at IS NULL`
   - `CREATE INDEX ... ON dialog_members(dialog_id, joined_at, account_id) WHERE left_at IS NULL`
     (member paging and deterministic owner succession)

3. **`media_objects`** — `purpose TEXT NOT NULL DEFAULT 'message' CHECK (purpose IN ('message','group_photo'))`.
   Message send accepts only `message`; group-photo update accepts only `group_photo`.

4. **`group_create_requests`** — `(creator_account_id, client_group_id)` PK, `fingerprint BYTEA`,
   `status`, `result_revision`, `created_at`.

5. **`group_mutation_requests`** — `(actor_account_id, client_mutation_id)` PK, `dialog_id`, `operation`,
   `fingerprint BYTEA`, `status`, `result_revision`, `created_at`.

6. **`messages`** — `service_type TEXT NULL`, `service_data JSONB NULL`, with a CHECK constraining
   `service_type` to the group lifecycle values plus the existing call values.

7. **`message_mentions`** — `(dialog_id, msg_id, account_id)` PK, `offset INT`, `length INT`.
   Index `(account_id, dialog_id, msg_id)`.

8. **`account_events`** — extend the type CHECK (`schema.sql:312-314`) with `member.role_changed`,
   `member.left`, `dialog.profile_updated`, `dialog.closed`, `dialog.access_revoked`.

9. **`group_action_budgets`** — see §5.7.

### 5.2 Modules

- New `server/src/groups.ts` — validation, idempotent create, profile/member reads, administration,
  transfer, leave, service-message construction.
- New `server/src/dialog-access.ts` — the shared lock-aware authorization primitive used by send, edit,
  delete, reaction, read, history, media, and every group route.
- New `server/src/fanout.ts` — the set-based event/push fanout of §5.4, used by every write path.
- Routes and capability composition stay in `server/src/cloud.ts`.
- Generic message transport stays in `server/src/sync.ts`. Do not build a parallel group-message service.

### 5.3 Concurrency and lock order

The current send path checks membership (`sync.ts:52-57`, called at line ~296) **before** taking the
dialog lock (`sync.ts:333`). That is safe only while membership never changes.

**Amend the global lock-order comment at `sync.ts:10-13` to:**

```
1  idempotency row (send_requests / message_mutation_requests / group_*_requests)
2  accounts                    ascending account_id, FOR SHARE
3  acting device
4  media_objects               FOR UPDATE            ← before dialogs
5  direct_dialog_pairs
6  dialogs                     FOR UPDATE            ← linearization point
7  dialog_members              ascending account_id, FOR UPDATE
8  messages
9  account_sync_states         ascending account_id, FOR NO KEY UPDATE
10 account_events insert
11 push_deliveries insert
```

Step 4 is new and mandatory. `sendMessage` already locks `media_objects FOR UPDATE` at `sync.ts:308-310`,
before the dialog row. If a group-photo update took the dialog lock first and then validated the photo
media, a media send and a photo change would deadlock. Group-photo validation therefore happens **before**
the dialog lock.

**Every group-capable mutation follows:** claim idempotency row → validate/lock referenced accounts in
sorted UUID order → validate photo media if any → lock dialog `FOR UPDATE` → lock and re-read actor and
target membership rows → authorize against re-read roles → mutate → bump `dialogs.revision` → insert
structured service message → fan out (§5.4) → commit → send in-process WS hints.

**Read paths take no dialog lock.** The previous draft's "shared dialog/member lock for the lifetime of
history/media materialization" is dropped for two reasons:

- It cannot deliver what it promises. Media downloads are per-chunk HTTP requests, each with its own
  transaction (`media.ts:492`). There is no single in-flight read to protect.
- It is actively harmful. A `FOR SHARE` on the dialog row conflicts with the `FOR UPDATE` every
  administrative action takes, so one member paging history would block every add, remove, and role
  change in a 200-member group.

`requireMediaAccess` already demonstrates the correct pattern: a membership predicate inside the read
transaction, `FOR KEY SHARE OF mo` on the media row only. Read-committed snapshot semantics plus that
predicate already give exactly the required behaviour — a read whose snapshot precedes the removal commit
succeeds; every read after it fails. Extend the predicate for group photos:

```sql
WHERE mo.id = ${mediaId} AND (
  EXISTS (SELECT 1 FROM messages m
            JOIN dialog_members dm ON dm.dialog_id = m.dialog_id
           WHERE m.media_id = mo.id AND m.state = 'visible'
             AND dm.account_id = ${accountId} AND dm.left_at IS NULL)
  OR EXISTS (SELECT 1 FROM dialogs d
               JOIN dialog_members dm ON dm.dialog_id = d.id
              WHERE d.photo_media_id = mo.id
                AND dm.account_id = ${accountId} AND dm.left_at IS NULL)
)
```

`getDifference` must not return message bodies for an account no longer active in a group. Materialize the
page, resolve current membership for the referenced dialogs in one set-based query, and rewrite events for
dialogs the account has left into `dialog.access_revoked` — carrying `dialog_id` and nothing else. PTS
still advances. No locks.

### 5.4 Set-based fanout

`sendMessage` (`sync.ts:345-361`) issues three sequential statements **per recipient**. Same shape at
`sync.ts:460-470` (edit/delete), `546-556` (reactions), `918-927` (reads). At 200 members that is roughly
600 sequential round trips inside a transaction that already holds the `dialogs` row lock from
`sync.ts:333`.

Two consequences, the second worse than the first:

- **Latency.** At 0.3–0.5 ms per round trip, 200–300 ms of lock-held time per group message. Every other
  send to that group queues behind it.
- **Cross-dialog contention.** Those 200 `account_sync_states` row locks are held until commit, and *every*
  send to *any* dialog updates the recipient's `account_sync_states`. One chatty 200-member group
  serializes direct-message delivery for all 200 of its members. A group feature degrades the whole app.

O(n) *events* is correct. O(n) *round trips* is not. Replace with three statements in `fanout.ts`:

```sql
-- 1. recipients, ordered, inside the dialog lock
SELECT account_id, (notification_mode <> 'muted') AS alert
  FROM dialog_members
 WHERE dialog_id = ${dialogId} AND left_at IS NULL
 ORDER BY account_id;

-- 2. lock ascending, bump, and append in one statement
WITH locked AS (
  SELECT account_id FROM account_sync_states
   WHERE account_id = ANY(${accountIds}::uuid[])
   ORDER BY account_id
     FOR NO KEY UPDATE
), bumped AS (
  UPDATE account_sync_states s
     SET pts = s.pts + 1, updated_at = now()
    FROM locked l
   WHERE s.account_id = l.account_id
  RETURNING s.account_id, s.pts
)
INSERT INTO account_events (account_id, pts, type, dialog_id, msg_id, actor_account_id, data)
SELECT account_id, pts, ${type}, ${dialogId}, ${msgId}, ${actorId}, ${data}::jsonb
  FROM bumped
RETURNING account_id, pts;

-- 3. push rows in one statement
INSERT INTO push_deliveries (account_id, pts, device_id, alert)
SELECT e.account_id, e.pts, d.id, (e.alert AND e.account_id <> ${actorId})
  FROM unnest(${accountIds}::uuid[], ${ptsList}::bigint[], ${alerts}::bool[])
         AS e(account_id, pts, alert)
  JOIN devices d ON d.account_id = e.account_id
 WHERE d.platform = 'ios' AND d.revoked_at IS NULL
   AND d.push_token_hash IS NOT NULL AND d.push_token_ciphertext IS NOT NULL
   AND (${sourceDeviceId}::uuid IS NULL OR d.id <> ${sourceDeviceId}::uuid)
ON CONFLICT (account_id, pts, device_id) DO NOTHING;
```

The `locked` CTE is mandatory, not decorative. A bare `UPDATE ... FROM unnest(...)` gives Postgres freedom
to lock rows in plan order, which destroys the ascending-`account_id` deadlock avoidance the current loop
provides. `SELECT ... ORDER BY ... FOR NO KEY UPDATE` is the documented idiom for ordered lock
acquisition. `FOR NO KEY UPDATE` matches the lock strength a plain `UPDATE` already takes and does not
conflict with `FOR KEY SHARE` on `accounts`.

600 round trips → 3. Apply to all four call sites in Slice 0, including the direct path.

**Group reads do not fan out.** `readHistory` (`sync.ts:918-927`) currently appends `read.updated` for
every member, carrying the reader's `unread_count`. For a group that is both a 200× event amplifier and an
information leak. Branch on `dialogs.type`: for groups, fan out only to the reader's own account. Direct
behaviour is untouched.

### 5.5 Bootstrap, history, and profiles

`getBootstrapDialogsPage` (`sync.ts:703-812`) issues five queries per dialog plus one `loadMessage` per
preview message. Replace with bounded set-based reads over the whole page:

1. One dialog-page query (already set-based).
2. One **active** member query for all page dialog ids.
3. One profile query over the union of every referenced account id (§4.2), not just active members.
4. One grouped unread + mention count query.
5. One lateral preview-message query.
6. One batched `loadMessages` call.

**The member query must filter `left_at IS NULL`.** It currently does not (`sync.ts:759-762`) while the
profile query directly below it does. Harmless for two-person direct dialogs; for groups it hands every
bootstrapping device the complete list of everyone who was ever a member, including removed accounts.

The resulting rule, stated once so the two halves cannot drift:

> `dialog_members` carries **active members only**. Everyone else — departed senders, removed accounts,
> service-message subjects — is reachable solely through the `profiles` side-payload.

`getHistory` (`sync.ts:854-862`) calls `loadMessage` singular per row with a limit up to 200 — 400 queries
per page. The batched `loadMessages` already exists two functions above. Fix it; group members will hit
this path hardest.

Member lists page by keyset on `(joined_at, account_id)`, default 50, maximum 100. Never offset.

### 5.6 Retention

`cleanupExpiredData` (`ops.ts:106-174`) prunes OTP challenges, bootstrap snapshots, push deliveries,
contact lookups, and media. It does **not** prune `send_requests`, `message_mutation_requests`, or
`account_events`; `account_sync_states.pruned_through_pts` (`schema.sql:44`) is never advanced by anything,
so `difference_too_long` cannot currently fire. Groups multiply event volume by roughly 100× per message.

Add to `cleanupExpiredData`, each batched and idempotent like the existing blocks:

- `group_create_requests`, `group_mutation_requests`, `send_requests`, `message_mutation_requests` older
  than 24 h — matching the 24 h convention already used for media (`schema.sql:198`).
- `account_events` older than the retention window, advancing `pruned_through_pts` in the same
  transaction so `difference_too_long` correctly routes affected devices to bootstrap.

**Choose the `account_events` retention window before groups ship.** Recommendation: 30 days. After
groups are live the table is too large to alter safely, and the window determines how long a device can be
offline before it pays a full bootstrap — which for a member of several 200-member groups is expensive.

**Fix the orphan-media reaper** (`ops.ts:156-164`). It deletes ready media with no visible-message
reference. A group photo is referenced only by `dialogs.photo_media_id`, so today's predicate deletes every
group photo 24 hours after upload:

```sql
  AND NOT EXISTS (SELECT 1 FROM messages m WHERE m.media_id = mo.id AND m.state = 'visible')
  AND NOT EXISTS (SELECT 1 FROM dialogs d WHERE d.photo_media_id = mo.id)   -- add this
```

A superseded group photo becomes unreferenced and is correctly reaped after 24 h. Consequence: the
"changed the group photo" service message carries **no thumbnail** in v1, because the object it would point
at is collectable. Clients render the current photo, not a historical one.

### 5.7 Abuse and consent

Groups v1 as previously drafted let any account add any other account to a 200-member group with no
consent, exposing the target's display name, bio, and birthday to up to 199 strangers instantly. WhatsApp
shipped that way and retrofitted controls after mass abuse. For Toj it is sharper than spam: an adversary
can place a target in a group of their choosing and make that participation observable to everyone in it.
That is a targeting primitive.

The codebase already has the pattern — `call_signal_budgets` (`calls.ts:907-941`) and
`contact_lookup_attempts` (`schema.sql:125`). Reuse it.

`group_action_budgets` keyed by `account_id`, windowed like `call_signal_budgets`:

- **Per-actor:** max group creations per day, max member-adds per hour.
- **Per-target:** max groups an account can be added to per day *by actors with whom it shares no active
  dialog*. Exceeding returns `429 rate_limited` to the actor. This limit protects the person being added,
  which a per-actor limit alone does not.
- **Stranger default:** when the actor shares no active dialog with the target, the new
  `dialog_members.notification_mode` defaults to `'muted'`. The group appears in the chat list; it does not
  ring. The added member sees the "added you" service message with Leave immediately available.

"Shares an active dialog" is a single server-checkable predicate:

```sql
EXISTS (SELECT 1 FROM dialog_members a
          JOIN dialog_members b ON b.dialog_id = a.dialog_id
         WHERE a.account_id = ${actorId} AND b.account_id = ${targetId}
           AND a.left_at IS NULL AND b.left_at IS NULL)
```

A full "who can add me" privacy setting is later work. The default protection is not.

### 5.8 Capability gating

`cloudCapabilities` (`cloud.ts:112-116`) gates *advertisement*. That is insufficient. When
`TOJ_GROUPS_V1_ENABLED=0`, **every `/v1/groups/*` route returns `404`.** Otherwise a modified or stale
client could create real groups during the dark-deploy window, and other members' pre-groups builds would
then receive group events they render as direct chats.

Push payloads and logs never contain group titles, message text, member names, or phone numbers.

---

## 6. iOS replica

New GRDB migration `v9-groups`, registered after `v8-media-presentation-representations`
(`CloudLocalStore.swift:2935`).

### 6.1 Local schema

1. **`dialogs`** += `revision`, `photo_media_json`, `member_count`, `self_role`, `notification_mode`,
   `access_state TEXT NOT NULL DEFAULT 'active'` ∈ `pending | active | removed | left | closed`.
2. **`dialog_members`** += `joined_at`, `left_at`, `is_active`, `revision`.
3. **`profiles`** — unchanged. Already global and keyed by `account_id` (`CloudLocalStore.swift:2473`),
   with no GC. Side-payload profiles land here.
4. **`pending_group_creations`** — group id, title, normalized member ids, local photo reference, retry
   state, error, terminal flag.
5. **`pending_group_mutations`** — same durable retry shape as pending message mutations.
6. **`message_mentions`** — local entity rows for mention counts and composer rendering.
7. **`dialog_unread_summaries`** += `mention_count`.
8. **`messages`** += `service_type`, `service_data_json`.
9. **`group_member_hydration`** — dialog id, `scan_generation`, `scan_revision`, cursor, completed flag.
10. **`pending_purges`** — see §6.5.

Ship an upgrade test from a populated v8 database to v9.

### 6.2 Optimistic creation

```text
draft
  │ Create tapped
  ▼
queued ──────────── no network / timeout ──▶ queued (with retry time)
  │
  ▼
creating ─────────── same-id retry ────────▶ creating
  │
  ├── permanent validation error ──▶ failed (editable, manual retry)
  ▼
active
  ├── queued photo upload / profile mutation
  └── release text and media outbox rows for this groupId
```

Creation drains before any message or media outbox entry for the same `groupId`. Because the local id is
already the final UUID, success is a state change only — no foreign-key rewrite.

### 6.3 Applying sync

- **Never infer `direct`.** `upsertDialog` defaults to `"direct"` (`CloudLocalStore.swift:872`) and
  `applyDifference` passes it literally at `:1455` and `:1493`. Carry `dialog_type` on create, message, and
  profile events — **and when `dialog_type` is absent, leave an existing row's type untouched.** "Never
  infer direct" alone is not sufficient as a rule: one legacy-shaped event would silently convert a group
  into a direct chat.
- Apply group metadata, changed members, profiles, and the service message in the **same** SQLCipher
  transaction as PTS.
- Revision-gate metadata and membership only (§4.3). Never gate messages.
- Local member roles come from the event, not the hardcoded `"member"` at `CloudLocalStore.swift:1478-1487`.

**On self-removal, leave, or close, in one transaction:**

1. Set `access_state` first, so every GRDB observation hides or dismisses the group immediately.
2. Mark text outbox rows, media transfers, and pending group mutations terminal with a recoverable,
   user-facing reason.
3. Cancel download jobs.
4. Stop history and member hydration.
5. Delete unread and mention summaries.
6. **Enqueue `pending_purges` rows** for group messages and cached media.

Then drain purges asynchronously (§6.5).

### 6.4 Member-list reconciliation

Keyset paging over a changing membership can skip or duplicate. The algorithm:

1. Begin scan: record `scan_revision` from page 1 and a fresh `scan_generation` UUID.
2. Each page upserts member rows stamped with `scan_generation`.
3. If a page returns a revision ≠ `scan_revision`, abort and restart with a new generation. Bound at 3
   attempts, then accept the partial scan and re-reconcile on next profile open.
4. On completed scan, delete local member rows for that dialog whose `seen_generation ≠ scan_generation`.

State lives in `group_member_hydration` so process termination resumes cleanly.

### 6.5 Durable purge

The previous draft purged group content "asynchronously after the access-state transaction." A process
kill between the two leaves decrypted message rows and cached media on disk with nothing to retry them —
a silent, non-recoverable failure, violating invariant 1. Creations and mutations already get durable retry
queues; purges need the same.

`pending_purges (id, dialog_id, kind, payload, created_at, attempts)`. Enqueued inside the access-state
transaction, drained by a background task, and **re-drained at every launch**. Purge is idempotent and the
UI never queries purged-but-not-yet-deleted rows, because `access_state` already gates every observation.

### 6.6 Direct-only assumptions to remove

`applyDifference` dialog and message upserts; `applyHistoryPage` and targeted history; `insertSending` and
`insertSendingMedia` (`CloudLocalStore.swift:1213-1241`, `878+`); dialog summary and profile joins that
assume exactly one peer; `maxPeerReadMsgId` (stays direct-only and returns no synthetic group "seen"
state); media policy continues using the durable dialog type.

---

## 7. UI

### 7.1 Creation

Replace `DemoGroupCreationView` (`RichDemoSurfaces.swift:283-343`) with a production feature in its own
file.

- Source members from `TojContactsStore.registeredContacts` (`ContactsFeature.swift:72-76`) — never the
  chat list.
- Search by name or phone, reusing the filter at `ContactsFeature.swift:277-282`.
- Selected-member chips, live count, clear-selection.
- Handle: Contacts permission denied, discovery in progress, no registered contacts, duplicate phone
  identities.
- Details step: generated avatar, optional `PhotosPicker` image, title validation, member review.
- On Create: write the pending group and navigate to it immediately.
- Banner states: creating, waiting for network, failed with retry and edit.
- Rapid double-taps produce one local row and one server group.

### 7.2 Conversation

- Presentation model gains dialog type, group revision, member count, access state.
- Header shows group name and member count, opens `GroupProfileView`.
- No call controls. No "Private conversation" pill.
- Extend `TimelinePresentationInput` (`TimelinePresentationBuilder.swift:3-7`) with `senderId`; amend
  `sameGroup` (`:57-67`) so two incoming messages cluster only when `mine` **and** `senderId` match.
- Sender display name above the first incoming bubble of a cluster; generated color avatar beside the last.
- Rename the call-only service row to a general service row; dispatch call vs. group presentation.
- Reply quotes carry the sender name.
- Mention autocomplete reads cached active members and writes structured entities.
- If access is revoked while the screen is open: dismiss to the chat list and show
  "You no longer have access to this group."

### 7.3 Group profile

Photo, title, member count, caller role. Member list rendered cache-first with paginated refresh. Shared
media from the local `message_media` index, requesting older history through the existing hydrator as the
user pages. Real notification toggle. Role-gated add / remove / promote / demote. Leave and owner-transfer
flows. No audio or video action in v1.

### 7.4 Localization and accessibility

All strings in `Toj/Localizable.xcstrings`. Service messages localized on-device from `service_data` plus
the profiles table. VoiceOver announces selected members, roles, pending and failed creation, service
messages, and destructive confirmations. Dynamic Type and Reduce Motion preserved.

---

## 8. Slices and gates

### Slice 0 — Hot-path hardening (feature off, no new surface)

The riskiest slice. It rewrites locking and fanout on the live send path for a feature nobody can use yet:
all downside, no user-visible upside. It is judged on latency, not features.

Files: `sync.ts`, `media.ts`, `ops.ts`, `push.ts`, new `fanout.ts`, new `dialog-access.ts`, `schema.sql`,
`schema-concurrent.sql`, `m3.test.ts`.

Deliver: set-based fanout at all four call sites; amended lock order with lock-aware authorization on
send/edit/delete/reaction/read/history/media; batched `getHistory`; de-N+1 bootstrap with the `left_at`
filter and the profiles side-payload; reaper fix; retention and `pruned_through_pts` advancement; schema
and typed errors; `groups_v1` off and routes absent.

**Gate:**
- All existing direct-message tests green.
- **p99 send latency does not regress.** Measure before and after on the same fixture. Budget: p99 direct
  send ≤ baseline + 5 ms. Fanout is expected to *improve*; the added dialog lock on the read-then-write
  boundary is the risk being measured.
- Concurrency test: remove-vs-send has exactly one deterministic winner. Group fixtures are created by
  direct SQL in the test harness, since no create route exists yet.
- A removed account cannot obtain message bodies via history, media, or difference.
- Reaper test: a group photo survives 48 simulated hours; a superseded one is collected.
- Retention test: `pruned_through_pts` advances and `difference_too_long` fires correctly.

### Slice 1 — Walking skeleton

Server create / get / member-page; group create events, service row, push hints, bootstrap support; iOS
group DTO decoding and the `v9-groups` migration; pending-creation queue; production contact picker and
name step; chat-list row and header; text send through the existing outbox; second-device bootstrap;
DEBUG-only feature override with production capability still off.

**Gate:** three accounts create one group; a timeout followed by the same create returns one group; all
three see it and exchange text; an offline message appears instantly and sends on reconnect; a second
device receives group and history; process kill during pending creation resumes with no duplicate group or
message rows.

### Slice 2 — Message parity and presentation

Photo, video, file, voice note, reply, reaction, forward, edit, delete parity. Sender-aware clustering,
names, avatars, structured service rows. Mentions and mention counts. Shared-media browser. Group read
semantics.

**Gate:** three users exchange every content type; reply and forward targets never cross unauthorized
dialogs; group edits, deletes, and reactions fan out exactly once per active account; a departed sender's
messages render with a name and avatar (profiles side-payload); direct presentation and receipts unchanged
in regression fixtures.

### Slice 3 — Administration and profile

Add, remove, role changes, title, photo, mute, leave, transfer. Pending retryable group mutations.
Account-deletion owner handoff. Self-removal revocation with the durable purge queue. Full profile and
member UI with generation-based reconciliation. Abuse budgets and the stranger-mute default.

**Gate:** role matrix enforced at API and UI; concurrent add/remove/leave/transfer resolve by dialog
revision; exactly one active owner or the group closes; removed members get 410 from profile, history,
media, and send, and see no cached timeline; pending sends and media become terminal when removal wins;
purge survives a process kill mid-drain; budgets return 429 with `Retry-After`.

### Slice 4 — Reliability and performance

Weak-network, process-kill, reconnect, and push tests. 200-member and large-history fixtures. Upgrade path
from the current local DB and from an old app/server capability combination. Operational metrics and
runbook.

**Gate:** the performance budgets in §10 hold on a representative physical iPhone.

### Slice 5 — Rollout

See §11.

### Parallel lanes

After the Slice 0 contract commit: Lane A `server/src` group API and tests; Lane B iOS DTOs, migration,
store tests. After A and B merge: Lane C creation and profile UI. Lane D conversation presentation may run
beside C, but **only one lane at a time** may edit `CloudAppModel.swift`, `CloudRootView.swift`, or
`ConversationExperience.swift`. Integration and rollout are sequential.

Voice/video stays in its own workspace. If that branch still edits `CloudAppModel.swift` or
`CloudRootView.swift`, merge its stable interface before starting Lane C.

---

## 9. Failure modes

| Failure | Handling | Test | User experience |
|---|---|---|---|
| Create response lost after commit | Client-generated id + fingerprint | Retry-after-commit integration | Pending becomes active |
| Double-tap Create | One local PK, one server idempotency row | UI + server concurrency | One group |
| Idempotency id reused with new payload | Fingerprint conflict | Server unit | "This request changed; start a new group" |
| Group id collides with a foreign dialog | `ON CONFLICT DO NOTHING` → identical 409 | Server unit | Same message; no existence oracle |
| Remove commits while send waits | Dialog lock, then membership re-read | Two-connection race | Sent before removal, or permanently failed after |
| Removed device has unconsumed events | Difference rewrites to `dialog.access_revoked` | Difference security test | Revocation only, no plaintext |
| Media download races removal | Per-transaction membership predicate | Chunk/thumbnail race | In-flight chunk may finish; all later chunks 404 |
| Media forwarded out before removal | Documented limitation (§4.6) | Explicit test asserting current behaviour | Forwarded copy remains readable |
| Owner leaves concurrently with transfer | Dialog lock + partial unique owner index | Concurrency test | One owner, or explicit retry |
| Owner deletes account | Deterministic successor in the deletion transaction | Lifecycle test | Group continues |
| Process dies during local create | Durable pending row, final UUID known | Relaunch test | Stays pending, retries |
| Member removed with queued message/media | Access-state transaction terminalizes queues | Store/model test | Failed reason, no endless retry |
| Process dies mid-purge | `pending_purges` re-drained at launch | Kill/relaunch store test | Content gone on next launch |
| Photo uploads, profile mutation fails | Separate idempotent mutation | Retry test | Local photo with retry indicator |
| Event arrives twice or out of order | Revision (metadata only) + idempotent upserts | Store test | No duplicate members or service rows |
| Stale revision on a message event | Messages are never revision-gated | Store test | Message applied |
| Bootstrap expires midway | Existing resumable replacement | API/store integration | Cached list stays visible |
| 200 members read every message | Group reads fan out to the reader only | Event-count test | Correct unread, no storm |
| Muted member receives message | Silent push row, no alert bit | Push payload test | Syncs quietly |
| Stranger adds you to a group | Per-target budget + stranger-mute default | Budget test | Silent, Leave available |
| Group photo older than 24 h | Reaper excludes `photo_media_id` | Reaper test | Photo persists |
| Old iOS build meets group events | Routes 404 while flag off; min-version enforced | Compatibility test | No creation UI |

---

## 10. Performance budgets

- Message fanout: **3 SQL statements**, independent of member count. Any per-member statement is a defect.
- Dialog lock hold time per group send: **< 15 ms p99** at 200 members.
- Group reads never fan out beyond the reader's own account.
- Bootstrap and difference are set-based. No per-dialog or per-message SQL loop anywhere.
- Member lists use keyset pagination only.
- Chat opening stays local-only on the critical path. No group API call blocks the first cached frame.
- Sender and profile lookups come from local tables, never from row-time network calls.
- Query-plan checks (`EXPLAIN`) for: active-member authorization, member paging, mention counts, owner
  succession, the fanout CTE, and the extended reaper predicate.

Watch in production: create failure rate, mutation conflict rate, access-denied count, fanout latency,
difference payload size, push backlog depth, `account_events` table growth, budget-rejection rate.

---

## 11. Rollout

1. Apply backward-compatible schema (`bun run migrate`, then `schema-concurrent.sql`).
2. Deploy Slice 0 hardening. Confirm the latency gate on production traffic before proceeding.
3. Deploy group routes with `TOJ_GROUPS_V1_ENABLED=0` — **routes return 404, not merely unadvertised.**
4. Release the group-aware iOS build.
5. Enforce it as the minimum beta version before advertising the capability, so no older client can render
   a group as a direct chat.
6. Three-account staging smoke test.
7. Enable `groups_v1` for the private beta.
8. Watch the §10 metrics.

Emergency rollback is capability-only: stop advertising and re-close the routes, while already-created
groups continue to sync. Schema changes are additive and are never rolled back.

---

## 12. Test plan

### Coverage map

```text
GROUP CREATE
  picker → pending SQLCipher row → POST /v1/groups
    validation failure                      [unit + UI]
    transient failure / timeout             [unit + integration]
    duplicate exact request                 [server concurrency]
    conflicting reused id                   [server unit]
    foreign dialog-id collision             [server unit]
    commit → events → push → local apply    [HTTP + store integration]

GROUP MESSAGE
  optimistic row → existing outbox → send
    active membership                       [existing + group regression]
    removal wins the lock race              [PostgreSQL two-connection]
    every media and message kind            [HTTP integration]
    second-device difference / bootstrap    [HTTP + store integration]
    fanout is 3 statements at 200 members   [query-count assertion]

MEMBERSHIP
  add / remove / role / leave / transfer
    role allowed and denied                 [table-driven server unit]
    retry same mutation                     [idempotency]
    concurrent mutation                     [two-connection integration]
    self revocation + durable purge         [store + UI + kill/relaunch]
    account deletion succession             [lifecycle integration]
    budgets and stranger-mute default       [server unit]

DATA INTEGRITY
  departed sender renders with a profile    [store + presentation]
  group photo survives the reaper           [ops unit]
  message applied despite stale revision    [store]
  absent dialog_type preserves local type   [store]
  account_events pruning + too_long         [ops + sync integration]

PRESENTATION
  direct dialog                             [regression]
  group sender clusters                     [pure unit]
  structured service row                    [pure unit]
  mentions and reply sender                 [unit + UI]
  pending / failed / removed states         [UI]
```

### Files

**Server** — new `groups.test.ts` (schema, create, permissions, idempotency, concurrency, sync, lifecycle,
paging, budgets); new `fanout.test.ts` (statement counts, lock ordering, deadlock-freedom under two
connections); extend `m3.test.ts` (generic message/media/history/read against a group, plus direct
regressions); extend `ops` coverage (reaper, retention); HTTP tests via `startCloudServer` (route
validation, structured errors, capability flag returning 404, three accounts, second device); push
assertions in the existing style.

**iOS** — new `TojTests/GroupCloudAPITests.swift` (response and event decoding, profile side-payload, error
disposition, capability mapping); new `TojTests/GroupLocalStoreTests.swift` (v8→v9 migration, bootstrap,
revision gating, queue ordering, self-removal, purge resumption, mentions, member reconciliation); new
`TojTests/GroupPresentationTests.swift` (sender clusters, service localization, reply and mention metadata,
direct regression); extend `LocalFirstPerformanceTests.swift` (200-member group, large timeline); extend
`TelegramFastUITestFixture.swift`; new `TojUITests/GroupChatsUITests.swift` (create, pending retry,
profile and admin actions, offline, relaunch, local-first open).

### Commands

```sh
cd server
bun run migrate
DATABASE_URL="$TEST_DATABASE_URL" bun run migrate
bun test
```

```sh
pod install
xcodebuild test \
  -workspace Toj.xcworkspace \
  -scheme Toj \
  -configuration Debug \
  -destination "platform=iOS Simulator,id=<available-id>" \
  -parallel-testing-enabled NO
```

Use the signed serialized simulator path already used by CI. Run the opt-in large-replica fixture on a
representative physical iPhone before capability enablement.

---

## 13. Not in scope

Group audio and video calls. Channels, topics, public discovery, usernames, join and invite links. Bots.
Granular admin rights beyond owner/admin/member. Ban lists, restrictions, slow mode, approvals, anti-spam
tooling. Configurable history visibility for new members. Per-member read-by lists. Server-side
message/media search. Synced pin, archive, drafts, and the full notification-settings system. Scheduled and
silent messages, polls, albums, stickers, GIFs, link previews. Secret Chats or any group-wide E2E claim.
User-facing group deletion — a last-owner leave may close an empty group as a lifecycle safeguard. A full
"who can add me" privacy setting (the §5.7 defaults ship instead). Copy-on-forward media isolation.

---

## 14. Definition of done

- Contract, migrations, and role rules are tested.
- Walking skeleton and every existing message type pass across three accounts.
- A second device bootstraps the group and its history.
- Offline sends and process-kill recovery work, including purge resumption.
- Concurrent membership operations are deterministic; exactly one active owner or the group is closed.
- Every rendered account id has a profile, including departed senders and service-message subjects.
- Removed members cannot read server content or cached content, **except** media they had already
  forwarded into a dialog they still belong to (§4.6), and queued work stops retrying.
- Group photos survive the maintenance loop; the maintenance loop survives group photos.
- Fanout is 3 statements at 200 members and the §10 budgets hold on device.
- Direct chat behavior is unchanged.
- The UI is accessible, localized, local-first, and makes no false privacy claim.
- `groups_v1` is advertised only after staging smoke, migration, CI, and performance gates pass.

---

## 15. References

- PostgreSQL explicit locking (dialog row as linearization point, ordered `FOR NO KEY UPDATE`):
  <https://www.postgresql.org/docs/current/explicit-locking.html>
- PostgreSQL partial unique indexes (at most one active owner):
  <https://www.postgresql.org/docs/current/indexes-partial.html>
- GRDB migrations and observations: <https://github.com/groue/GRDB.swift>

## 16. Review status

| Review | Status | Notes |
|---|---|---|
| Engineering review | Cleared | 22 issues in the first pass |
| Codebase stress test | Cleared | 14 findings, all folded into this document |
| Design review | **Required before Slice 1** | Slices 1 and 3 ship the user-facing contract |
| CEO review | Not run | Optional; scope is already approved |
