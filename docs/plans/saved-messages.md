# Saved Messages v1 - Engineering Plan

Status: implementation plus independent launch-review remediation complete on
`mmarufov/saved-messages-plan`. Automated backend, production-sized migration, serialized iOS
unit/UI, exact forwarding/account-deletion, and Release simulator/device compile gates were
reverified 2026-07-27. Physical-device runtime performance and production rollout/canary gates
remain open; the production provisioning backfill has not been run.

Baseline: `0df5aa9` (`origin/main`)

Branch: `mmarufov/saved-messages-plan`

Primary capability: `saved_messages_v1`

Rollout rule: schema and routes deploy dark; the server must not advertise or materialize Saved
Messages until a compatible client is available.

---

## 0. Outcome

Build one automatic Saved Messages conversation for each Toj account.

It is a first-class `saved` dialog, owned by and visible to one account. It reuses the production
text, reply, edit, delete, reaction, forward, media, voice-note, outbox, history, bootstrap,
difference-sync, WebSocket hint, APNs wake-up, and encrypted local-cache paths.

The finished experience:

- appears as **Saved Messages** in the Chats list;
- permanently opens from the existing Settings row in
  `Toj/Features/Cloud/CloudRootView.swift`;
- opens from SQLCipher immediately when it has been provisioned before, including without a network;
- accepts text, photos, videos, files, voice notes, replies, and forwarded messages;
- writes optimistically to the local replica before any send request;
- synchronizes to every signed-in device through the existing account PTS stream;
- never shows peer-only UI such as calls, profile, last seen, typing, unread, or block controls;
- offers a one-tap **Save** action on messages from other dialogs and puts Saved Messages first in the
  forwarding picker.

Telegram's official Saved Messages description validates the basic product shape: one personal chat
for notes, links, media, bookmarks, and messages forwarded from other chats. Tags, chat-grouped views,
and reminders are useful later layers, not requirements for this walking skeleton:
<https://telegram.org/blog/new-saved-messages-and-9-more/ms?setln=en>.

---

## 1. Non-negotiable invariants

1. **One account, one Saved Messages dialog.** PostgreSQL enforces at most one live `saved` dialog
   for an account. Provisioning, retries, concurrent devices, and backfill all return the same UUID.
2. **Provisioning is idempotent at both the row and event layers.** A retry must not allocate another
   dialog, increment PTS again, or emit another `dialog.created` event.
3. **No invented message pipeline.** A saved message is an ordinary message in an ordinary dialog
   after authorization. No `saved_messages` message table, special upload endpoint, or second outbox.
4. **Local-first after one successful provision.** Chat-list display and conversation open never wait
   for capabilities, an ensure request, bootstrap, or history once the local `saved` row exists.
5. **No fake offline UUID.** If a legacy account has never provisioned Saved Messages and is offline,
   show a recoverable "Connect once to set up Saved Messages" state. A temporary dialog identifier
   would require key remapping and could strand queued messages.
6. **PTS never advances past unapplied content.** Saved-dialog creation and messages use the same
   ordered account event stream, gap handling, `difference_too_long`, and resumable bootstrap as every
   other dialog.
7. **No peer semantics leak into a self-dialog.** No calls, video, profile, presence, typing,
   read-receipt drain, mute, block, or "seen by" behavior.
8. **No false privacy claim.** Saved Messages uses Toj's cloud-chat model and encrypted-at-rest
   storage. UI copy says "Synced across your devices", not "end-to-end encrypted".
9. **Account deletion removes the personal archive.** The saved dialog and its message rows are
   deleted transactionally when the account is deleted. Media still referenced by a forwarded copy
   remains; the existing orphan-media cleanup removes unreferenced blobs.
10. **The feature is reversible.** With `saved_messages_v1` off, the route family is closed and new
    dialogs are not provisioned. Existing saved dialogs remain readable to clients that already have
    them; disabling a flag must never delete user data.
11. **Saved access is owner-only at every boundary.** Read, mutation, media, fanout, difference, and
    bootstrap paths require the creator's active `owner` membership. PostgreSQL rejects new active
    non-owner memberships; cursor-based reconciliation repairs every legacy Saved dialog and stages
    ordered revocations before member removal.
12. **Revocation is file-first and crash-resumable.** SQLCipher hides the dialog and removes
    outbox/transfer payloads immediately. A session-scoped coordinator cancels media activity,
    deletes exclusive encrypted files through the media engine, and only then finalizes SQL removal.
    Media still referenced by a forwarded destination is retained.

---

## 2. What already exists

| Existing primitive | Current location | Decision |
|---|---|---|
| Generic `dialogs`, `dialog_members`, and per-dialog `msg_id` | `server/src/schema.sql` | Extend `dialogs.type` with `saved` |
| Idempotent message sends and mutations | `server/src/sync.ts` | Reuse unchanged |
| Set-based account-event and silent APNs fanout | `server/src/fanout.ts` | Reuse for the one account member |
| Difference, bootstrap, history, and read access | `server/src/sync.ts` | Reuse; teach payloads the `saved` type |
| Message/media authorization by active membership | `server/src/dialog-access.ts`, `server/src/media.ts` | Reuse |
| SQLCipher/GRDB dialog, message, outbox, media, and observation tables | `Toj/Core/Store/CloudLocalStore.swift` | Reuse, plus the v10 crash-resumable access-purge state machine |
| Optimistic text and forwarding outbox | `CloudLocalStore.insertSending`, `CloudAppModel.forwardMessage` | Reuse |
| Resumable encrypted media and persistent cache | `CloudMediaEngine.swift` | Reuse under the user's existing cache policy |
| Bounded timeline windows and local history hydration | `CloudLocalStore.swift`, `CloudAppModel.swift` | Reuse |
| Settings placeholder | `CloudRootView.swift` | Replace with a real navigation path |
| Capability negotiation and caching | `MessagingPresentation.swift`, `CloudAppModel.refreshServerCapabilities` | Extend and widen |
| Local-first UI fixture and relaunch tests | `TelegramFastUITestFixture.swift`, `TelegramFastLocalFirstUITests.swift` | Extend |

### Scope challenge

Saved Messages does **not** require:

- a PostgreSQL drafts table;
- a PostgreSQL dialog-preferences table;
- a GRDB draft or preference migration;
- an FTS5 index;
- a new message kind;
- a new media purpose;
- a second sync cursor;
- a new push channel.

Adding any of those here would mix four independently releasable epics and create avoidable conflicts in
`CloudAppModel.swift` and `CloudRootView.swift`.

The complete Saved Messages implementation still prepares for those siblings:

- widen `MessagingCapabilities.rawValue` from `UInt16` to `UInt64`;
- reserve distinct bits for `.savedMessages`, `.cloudDrafts`, `.dialogPreferences`, and `.localSearch`;
- advertise only `saved_messages_v1` in this feature;
- keep Saved Messages addressable by normal `dialog_id`, so cloud drafts and dialog preferences work
  with it without schema exceptions;
- keep messages in the ordinary local `messages` table, so the future FTS5 external-content index
  covers Saved Messages automatically and can filter by `dialog_id` or dialog type.

GRDB already provides migrations, SQLCipher integration, database observation, and FTS5 support. FTS5
belongs in `local_search_v1`, where its triggers, rebuild behavior, Unicode tokenization, and query
budgets can be tested as one unit:
<https://github.com/groue/GRDB.swift>.

---

## 3. Fixed product decisions

### 3.1 A dedicated `saved` dialog type

Do not represent Saved Messages as a direct pair where `account_low == account_high`.

The current direct-pair model requires two distinct accounts, derives a peer, powers profile/call/block
behavior, and assumes peer read state. Relaxing all of those assumptions would make direct chat less
safe for no user benefit.

`saved` is the third dialog type:

```text
dialogs
  id           UUID
  type         "saved"
  created_by   owner account UUID
  title        NULL

dialog_members
  dialog_id    saved dialog UUID
  account_id   same owner account UUID
  role         "owner"
  left_at      NULL
```

The server may return the English fallback title `Saved Messages` to legacy builds, but compatible
clients derive and localize the title from `dialog.type == "saved"`. The server string is not the
source of truth.

### 3.2 Materialized lazily, then backfilled

- A compatible client automatically calls the ensure endpoint after capability negotiation when no
  local saved dialog exists.
- Tapping the Settings row calls the same deduplicated ensure path.
- Existing local saved dialogs open without any network call.
- A durably claimed operations backfill materializes the invariant for dormant accounts only after
  the global switch and rollout are explicitly at 100% with production confirmation.

This avoids exposing an unknown dialog type during the dark schema deploy while still converging every
account to exactly one row.

### 3.3 List and navigation behavior

- The dialog participates in normal recency sorting.
- It is not force-pinned. A forced pin would override user preference before
  `dialog_preferences_v1` exists.
- The Settings entry is permanent even if a future preference archives the chat.
- Saved Messages is always first in the forwarding picker.
- Future pin and archive preferences may apply.
- Mute is hidden because self-authored account events never alert the same account.
- Delete-chat, leave, block, voice call, and video call are never available.

### 3.4 Conversation behavior

The ordinary message timeline and composer stay in place. Saved Messages changes only the surrounding
semantics:

- bookmark avatar instead of a person's initial;
- title **Saved Messages**;
- ready subtitle **Synced across your devices**;
- actual sync failure title while offline, slow, expired, or unavailable;
- intro pill **Notes and files for your Toj account** with a bookmark/cloud icon;
- no "Private conversation" or E2EE lock claim;
- no profile, call, video, presence, typing, or unread UI;
- delete confirmation says the item is removed from Saved Messages on all devices.

Empty-state copy should teach the job:

> Save notes, links, photos, files and voice messages here. Forward any message with Save.

> Downloaded content stays available offline. New changes sync when Toj reconnects.

The second sentence is deliberately exact. Message history remains in SQLCipher. Full media is
available offline only after it has been downloaded and while it remains under the user's cache policy.

### 3.5 One-tap saving

Add `MessageAction.save` for a server-confirmed, visible message outside the saved dialog.

It resolves the saved dialog, then calls the existing forward path with a fresh `client_msg_id`.
The existing server copies text/provenance and reuses authorized media references. The local optimistic
row appears immediately and the normal outbox survives offline, relaunch, timeout, or duplicate retry.

Do not show Save for:

- a deleted message;
- an optimistic message without a server `msg_id`;
- a message already in Saved Messages;
- a client/server pair without `saved_messages_v1`.

---

## 4. Architecture

### 4.1 Dependency boundary

```text
CloudRootView / ConversationExperience
                  |
                  | user intent only
                  v
          CloudAppModel (thin glue)
                  |
                  | ensure/open/save
                  v
        SavedMessagesService actor
             /                 \
            /                   \
           v                     v
      CloudAPI             CloudLocalStore actor
           |                     |
           v                     v
   Bun ensure endpoint      SQLCipher dialogs/member
           |                     |
           v                     v
   PostgreSQL invariant     GRDB observation publishes UI
```

`CloudAppModel` owns the user-visible state and navigation result. The service owns in-flight request
deduplication and the provision workflow. `CloudLocalStore` owns all SQL. No SQL, retry ledger, or
endpoint payload construction enters `CloudAppModel`.

### 4.2 First provision

```text
capability refresh advertises saved_messages_v1
    |
    v
local saved dialog exists? ---- yes ----> do nothing, local-first path remains hot
    |
    no
    v
SavedMessagesService.ensure()
    |
    +--> POST /v1/dialogs/saved
    |       |
    |       +--> account/device authorization
    |       +--> one-account mutation lock
    |       +--> insert-or-return unique saved dialog
    |       +--> insert/repair owner membership
    |       +--> emit dialog.created once when state changed
    |       +--> silent hints to the account's other devices
    |
    +--> CloudLocalStore.ensureSavedDialog(...)
            |
            +--> one SQLCipher transaction
            +--> dialog + owner member + summary + zero unread
            +--> GRDB observation publishes the row
```

The client response and the account event are deliberately redundant:

- response first, app alive: the row appears immediately;
- server commits, response is lost: difference sync creates the row;
- response arrives, app dies before local commit: difference or bootstrap creates the row;
- local row exists and the event is replayed: upserts are idempotent.

### 4.3 Offline send and cross-device sync

```text
Device A offline
    |
    +--> SQLCipher inserts message(local_state="sending")
    +--> pending_outbox inserts client_msg_id
    +--> UI renders immediately
    |
network returns
    |
    +--> existing POST /v1/messages/send
    +--> existing send_requests idempotency gate
    +--> messages row in the saved dialog
    +--> one message.new account event
    +--> silent APNs/WS wake-up to Device B
    |
Device B
    +--> getDifference(pts)
    +--> SQLCipher upsert
    +--> GRDB observation updates timeline
```

There is no read-receipt branch. Every visible saved message is self-authored, unread is always zero,
and no peer delivery state exists.

---

## 5. Server contract

### 5.1 PostgreSQL schema

Amend the `dialogs.type` check to accept `saved`.

Add a constraint that a saved dialog always has an owner:

```sql
CHECK (type <> 'saved' OR created_by IS NOT NULL)
```

Add a unique partial index:

```sql
CREATE UNIQUE INDEX dialogs_one_saved_per_account_idx
  ON dialogs(created_by)
  WHERE type = 'saved';
```

PostgreSQL partial unique indexes are the native mechanism for enforcing uniqueness over a selected
row subset:
<https://www.postgresql.org/docs/current/indexes-partial.html>.

Build the index through `schema-concurrent.sql` before enabling the feature. The dark deploy has no
saved rows, so validation is cheap, but keeping the operation concurrent preserves the production
migration policy.

No new Saved Messages table is required.

### 5.2 Endpoint

```http
POST /v1/dialogs/saved
Authorization: Bearer <device token>
Content-Type: application/json

{}
```

Success:

```json
{
  "dialogId": "uuid",
  "type": "saved",
  "created": true,
  "eventPts": 42
}
```

An exact retry returns `200`, the same `dialogId`, `created: false`, and no new event. The first create
may return `201`.

The endpoint accepts no account id, title, member id, or dialog id from the client. Identity comes only
from the authenticated device session.

### 5.3 Ensure algorithm

Implement in a focused `server/src/saved-messages.ts` module.

Within one transaction:

1. Acquire the account mutation key used by other account-scoped mutations.
2. Revalidate that the account and acting device are active.
3. Select the existing `saved` dialog for `created_by = account_id`.
4. If missing, insert one dialog. The partial unique index is the final concurrency guard.
5. Lock the resolved dialog row before membership repair, matching the existing mutation lock order.
6. Insert or repair the one owner membership with `left_at = NULL`.
7. If neither row changed, return immediately without touching PTS.
8. If the dialog or membership changed, emit one existing `dialog.created` event through
   `fanoutDialogEvent`, with `dialog_type: "saved"` and `alertRecipients: false`.
9. Commit, then deliver same-process and PostgreSQL wake-up hints exactly like message sends.

The update event remains `dialog.created`. A new `saved.created` event type would duplicate semantics
and force unnecessary server/client event migrations.

### 5.4 Difference and bootstrap

Teach the existing serialization queries:

- `dialog_type` is `saved`;
- compatible clients localize the title from the type;
- a legacy title fallback is `Saved Messages`;
- `peer_account_id` is absent;
- bootstrap includes exactly one active owner member;
- `member_count` is `1`;
- unread count is `0`.

No special history endpoint is added. `getHistory`, message mutation, reaction, forward, media
authorization, and bootstrap message previews already authorize by active membership.

### 5.5 Capability and route closure

Add `saved_messages_v1` to `/v1/capabilities` only for an authenticated account in the rollout bucket.

Configuration:

```text
TOJ_SAVED_MESSAGES_V1_ENABLED=1
TOJ_SAVED_MESSAGES_ALLOWLIST=<account UUIDs>
TOJ_SAVED_MESSAGES_ROLLOUT_PERCENT=0..100
```

Use the existing deterministic account-bucket pattern from video-call rollout. When unavailable:

- do not advertise the capability;
- return `404` for `POST /v1/dialogs/saved`;
- do not run provisioning or backfill.

Capability advertisement without route closure is a rollout bug.

### 5.6 Existing-account convergence

Add an idempotent, resumable backfill command that:

1. reads active/limited accounts lacking a saved dialog in bounded batches;
2. writes worker-owned durable leases before provisioning so multiple workers cannot duplicate work;
3. invokes the same ensure transaction used by the HTTP endpoint;
4. emits one silent `dialog.created` event per changed account;
5. records completion, unavailable accounts, attempts, and stale claims durably;
6. stops safely on `SIGTERM` between accounts;
7. applies configurable bounded per-account throttling and reports only aggregate counts and timings.

Run it only after the client canary succeeds, with `NODE_ENV=production`, the global switch enabled,
an explicit `100` rollout, and `PROVISION_ALL_ACTIVE_ACCOUNTS` confirmation. Do not log account ids,
phone numbers, message content, tokens, or media paths.

### 5.7 Account deletion

Inside the existing account-deletion transaction, first detach internal provenance from copies that
point into the archive while preserving their immutable ciphertext, media reference, and
`is_forwarded` marker:

```sql
UPDATE messages SET
  forwarded_from_account_id = NULL,
  forwarded_from_dialog_id = NULL,
  forwarded_from_msg_id = NULL
WHERE is_forwarded = TRUE AND source_dialog_is_the_deleting_accounts_saved_dialog;

DELETE FROM dialogs
WHERE type = 'saved' AND created_by = $account_id;
```

The dialog cascade removes membership and saved message rows. Existing media reference and orphan
cleanup semantics decide whether each encrypted blob remains because another forwarded message still
uses it.

This is intentionally different from a direct chat, whose delivered messages remain in the other
participant's history.

---

## 6. iOS data and service layer

### 6.1 Capability capacity

`MessagingCapabilities` currently uses `UInt16` and already consumes bits 0 through 13. Four planned
features do not fit.

Change the raw value to `UInt64` and reserve:

```text
bit 14  savedMessages       <- saved_messages_v1
bit 15  cloudDrafts         <- cloud_drafts_v1
bit 16  dialogPreferences   <- dialog_preferences_v1
bit 17  localSearch         <- local_search_v1
```

Update cached decoding from `NSNumber.uint16Value` to `uint64Value`. Existing cache values keep the
same lower bits. Do not enable unimplemented bits in `.demo` or from a similarly named server string.

### 6.2 API

Add:

- `SavedDialogResponse: Codable, Sendable`;
- `CloudAPI.ensureSavedMessages(token:)`;
- request/response contract tests using `CloudAPIMockURLProtocol`;
- failure classification through `cloudOperationFailureDisposition(...,
  serverAdvertisesFeature: true)`.

### 6.3 `SavedMessagesService`

Add one actor in `Toj/Core/Cloud/SavedMessagesService.swift`.

Responsibilities:

- return a local saved dialog immediately when one exists;
- deduplicate concurrent auto-provision, Settings-tap, and Save-action calls into one task;
- scope work by account, token, SQLCipher store identity, and session generation;
- cancel and await the exact previous task before a new account/session can provision;
- check cancellation immediately before SQLCipher persistence and revalidate scope before publishing;
- call the ensure endpoint only when needed;
- persist the returned dialog/member atomically through `CloudLocalStore`;
- classify transient, authentication, unsupported-server, and permanent failures;
- clear only the matching in-flight task on cancellation or completion;
- never own view state or user-facing copy.

It does not own message sends, forwarding, uploads, search, drafts, or preferences.

### 6.4 `CloudLocalStore`

No GRDB migration is needed because:

- `dialogs.type` is already `TEXT`;
- all message/media/outbox tables are dialog-generic;
- `upsertDialog` already prevents a generic `"direct"` optimistic write from downgrading a
  non-direct dialog.

Add focused APIs:

```swift
func savedMessagesDialogId(accountId: String) throws -> String?
func ensureSavedDialog(dialogId: String, accountId: String, updatedAt: String?) throws
```

`ensureSavedDialog` performs one write transaction:

- upsert `dialogs(type: "saved", title: nil, memberCount: 1, selfRole: "owner")`;
- upsert the owner `dialog_members` row;
- ensure dialog and exact-zero-unread summaries;
- preserve newer `last_msg_id`, `updated_at`, optimistic messages, and outbox rows.

Update `applyDifference` so `dialog.created` with `dialog_type == "saved"` inserts the current account
as the owner member even though no `peer_account_id` exists. Route this branch through the same local
helper so `member_count = 1`, `self_role = "owner"`, exact unread zero, and type preservation cannot
drift between response-first and event-first paths.

Bootstrap already carries the member and needs only type coverage tests.

### 6.5 `CloudAppModel`

Keep additions small:

- own one `SavedMessagesService`;
- map `saved_messages_v1` to `.savedMessages`;
- map every local `Dialog(type: "saved")` to the localized Saved Messages title regardless of the
  server fallback string;
- expose the published local `savedMessagesDialogId`;
- delegate `ensureSavedMessages()` and `saveMessage(_:)`;
- trigger a non-blocking ensure after a successful capability refresh when the local row is missing;
- never block `afterSignIn` local publication or first sync on provisioning;
- skip read-receipt queuing when the active dialog type is `saved`;
- keep all SQL and in-flight deduplication outside this file.

Target: less than roughly 60 lines of Saved Messages orchestration in `CloudAppModel.swift`.

---

## 7. UI implementation

### 7.1 Settings

Replace the `settingsLink(...)` placeholder at the existing Saved Messages row with a functional row.

Behavior:

- local dialog exists: navigate immediately;
- capability available, row missing: show an inline progress state while the service provisions;
- transient network failure before first provision: keep the row and offer retry with
  **Connect once to set up Saved Messages**;
- capability absent: show **Unavailable on this server** rather than "Coming soon";
- prepare the conversation locally before navigation through `prepareConversationOpen`.

Both compact and regular-width navigation use `TojConversationExperience`; no second Saved Messages
screen is built.

### 7.2 Chat list and forwarding picker

For `dialog.type == "saved"`:

- use a bookmark glyph in a raised monochrome tile with a restrained gold accent, matching Toj's
  black-and-gold design system;
- localize the fixed title;
- retain normal last-message preview, pending spinner, delivery check, and timestamp;
- enforce zero unread/mention UI;
- hide mute;
- keep Saved Messages first in the forwarding picker.

Extend `TojAvatar` with an optional semantic system image so the same visual primitive is reused in the
chat list, conversation header, and forwarding picker. Existing avatars render identically when the
parameter is `nil`.

### 7.3 Conversation

Add one `isSavedMessages` derived property and route presentation through it:

| Surface | Direct chat | Saved Messages |
|---|---|---|
| Header title | Peer name | Saved Messages |
| Header subtitle | Presence / typing | Synced across your devices |
| Avatar tap | Profile | Disabled |
| Voice/video | Available by capability | Hidden |
| Timeline intro | Private conversation | Notes and files for your Toj account |
| Empty state | Start a conversation | Save notes, media, links and files |
| Delete copy | Removes for everyone | Removes from Saved Messages on all devices |
| Read receipt | Peer semantics | Not queued |

Also rename the generic local-replica loading/failure copy that currently says "saved messages".
Once Saved Messages is a product name, phrases such as "Saved messages could not be opened" are
ambiguous. Use **offline copy** or **conversation** for generic local-replica states.

### 7.4 Accessibility, localization, and motion

- Add complete Russian and Tajik localization for title, subtitle, setup/retry state, empty state,
  intro pill, Save action, accessibility hints, deletion copy, and stale-session errors.
- Give the bookmark avatar and Settings row explicit VoiceOver labels.
- Keep every target at least 44 by 44 points.
- Preserve Dynamic Type, Reduce Motion, and Reduce Transparency behavior from shared components.
- Add stable accessibility identifiers:
  - `settings-saved-messages`
  - `saved-messages-avatar`
  - `saved-messages-empty-state`
  - `message-action-save`

---

## 8. Failure modes

| Production failure | Handling | Test | User experience |
|---|---|---|---|
| Two devices provision simultaneously | Account lock plus partial unique index | 25-way concurrency integration test | One dialog appears |
| Ensure response is lost after commit | Retry returns same id; difference carries creation | Dropped-response test | Brief retry, no duplicate |
| App dies after response but before local upsert | Difference/bootstrap repairs local replica | Kill-boundary store test | Dialog appears after reconnect |
| Local upsert commits, event later replays | Idempotent dialog/member upsert | Replay test | No visible change |
| First-ever setup while offline | No temporary id; service returns recoverable transient state | UI offline-first-provision test | "Connect once" plus Retry |
| Already-provisioned app is offline | Read SQLCipher immediately; queue ordinary outbox writes | Offline relaunch UI test | Full cached experience |
| Capability is unknown on first offline launch | Preserve unknown; local rows still open, first provision asks to connect | Offline first-provision test | "Connect once" rather than false unavailable |
| Ensure route returns 404 after advertisement | Mark unsupported immediately and withdraw the capability | 404-after-advertisement test | Server unavailable; existing local archive remains |
| Saved membership is missing server-side | Ensure repairs it and emits one creation event | Repair integration test | Dialog returns |
| Local event has `saved` type and no peer | Apply current account as owner member | Difference test | Correct row/title |
| Forward source is deleted before an offline Save retries | Classify as permanent and retain a failed local row with Remove/Retry | Source-deleted outbox test | Clear failure, no infinite loop |
| Media upload succeeds but message send times out | Existing media ledger and message idempotency retry | Existing media retry plus saved target test | Pending bubble becomes sent |
| Difference cursor is pruned | Existing replacement bootstrap includes saved dialog/history | `difference_too_long` test | Old local copy stays readable during rebuild |
| Low disk evicts full media | Existing metadata remains; redownload is available later | Cache policy regression test | Placeholder/retry, text remains |
| Account is deleted | Detach forwarding provenance, cascade Saved rows, retain destination copies/media | Saved-to-direct/group deletion tests | Personal archive is gone; forwarded copies remain |
| Old app build receives a `saved` type | String type decodes, fallback title supplied, no data corruption | legacy decoder fixture | Degraded UI only; rollout gate limits exposure |

Any failure that would silently lose a locally queued note, file, or forward is a release blocker.

---

## 9. Performance budgets

Saved Messages must not add work to ordinary chat opening.

- No ensure request on normal open when the local row exists.
- Provisioning runs after local publication and never delays the first cached chat-list frame.
- Optimistic text Save/send is visible within one display frame after the SQLCipher transaction
  completes; target **under 50 ms p95** on the representative private-beta iPhone.
- Opening a cached Saved Messages timeline of 120 rows: target **under 100 ms p95** from tap to
  locally rendered content on the representative device.
- Existing 1,000-dialog / 100,000-message performance fixture: no more than **5%** regression in
  dialog-list and initial-window query time.
- Ensure endpoint: one transaction and one account event; target **under 100 ms p95** excluding
  client network time on staging.
- Concurrent ensure test produces one saved dialog, one active member, and one `dialog.created`
  account event.
- Timeline memory remains bounded by `TimelineWindow.maximumRetainedMessages`.
- Backfill is bounded, interruptible, and rate-limited so it does not contend with message sends.

Record before/after signposts with `TOJ_PERFORMANCE_FIXTURES=1`; do not replace measured baselines with
simulator-only intuition.

---

## 10. Implementation slices

### Slice 0 - Shared capability foundation

Files:

- `Toj/Features/Cloud/MessagingPresentation.swift`
- `Toj/Features/Cloud/CloudAppModel.swift`
- `TojTests/MessagingPresentationTests.swift`

Work:

1. Widen raw capability storage to `UInt64`.
2. Reserve all four daily-use capability bits.
3. Preserve legacy cache decoding.
4. Map only `saved_messages_v1`.

Gate:

- all existing capability tests pass;
- a cached value containing old bits decodes identically;
- bits 14 through 17 are unique and round-trip through `UserDefaults`.

This slice should merge before the drafts, preferences, and search branches to remove the main shared
enum conflict.

### Slice 1 - Server invariant and dark contract

Files:

- `server/src/schema.sql`
- `server/src/schema-concurrent.sql`
- `server/src/dialog-access.ts`
- `server/src/saved-messages.ts` (new)
- `server/src/cloud.ts`
- `server/src/saved-messages.test.ts` (new)

Work:

1. Add `saved` dialog type and partial unique index.
2. Add ensure algorithm and contract.
3. Add capability allowlist/percentage rollout.
4. Hard-close the route when disabled.
5. Teach difference/bootstrap serialization.
6. Add aggregate metrics.

Gate:

- feature off: no advertisement, `404`, no database mutation;
- a `saved` dialog with no `created_by` owner is rejected by PostgreSQL;
- feature on: one dialog/member/event under concurrent retries;
- bootstrap, difference, history, text, media, forward, edit, delete, and reaction work through the
  existing pipeline;
- migration is idempotent on both empty and populated test databases.

### Slice 2 - Encrypted local replica and service

Files:

- `Toj/Core/Cloud/CloudAPI.swift`
- `Toj/Core/Cloud/SavedMessagesService.swift` (new)
- `Toj/Core/Store/CloudLocalStore.swift`
- `TojTests/SavedMessagesTests.swift` (new)

Work:

1. Add endpoint model and API call.
2. Add local lookup/upsert and saved-event member handling.
3. Add the deduplicating service actor.
4. Prove type preservation through optimistic text/media writes.
5. Prove relaunch and event replay behavior.

Gate:

- a local saved row opens after process restart with no network;
- queued text and forward survive restart;
- event replay creates no duplicate and never downgrades type to `direct`;
- no parallel Saved-message schema is introduced; the only later GRDB addition is the generic
  crash-resumable access-purge state machine required for revocation.

### Slice 3 - Real Settings route and saved-dialog presentation

Files:

- `Toj/Features/Cloud/CloudAppModel.swift`
- `Toj/Features/Cloud/CloudRootView.swift`
- `Toj/Features/Cloud/ConversationExperience.swift`
- `Toj/DesignSystem/TojTheme.swift`
- `Toj/Localizable.xcstrings`
- `TojTests/SavedMessagesTests.swift`
- `TojUITests/TelegramFastLocalFirstUITests.swift`
- `Toj/Features/Cloud/TelegramFastUITestFixture.swift`

Work:

1. Replace the Settings placeholder.
2. Auto-provision after capability negotiation without blocking local launch.
3. Add bookmark presentation and saved-specific copy.
4. Remove peer-only actions and read receipts.
5. Add offline setup/retry states.
6. Extend the UI fixture.

Gate:

- Settings opens the real conversation;
- chat-list and Settings routes reach the same dialog id;
- offline relaunch renders the cached conversation;
- calls/profile/presence/unread/private-lock copy are absent;
- direct and group UI fixture behavior is unchanged.

### Slice 4 - One-tap Save and forwarding polish

Files:

- `Toj/Features/Cloud/MessagingPresentation.swift`
- `Toj/Features/Cloud/CloudAppModel.swift`
- `Toj/Features/Cloud/ConversationExperience.swift`
- `TojTests/SavedMessagesTests.swift`
- `TojUITests/TelegramFastLocalFirstUITests.swift`

Work:

1. Add `MessageAction.save`.
2. Resolve/provision the target through `SavedMessagesService`.
3. Reuse the existing optimistic forward path.
4. Sort Saved Messages first in the forwarding picker.
5. Permanently classify source-deleted forward failures.

Gate:

- online Save appears immediately and confirms;
- offline Save survives kill/relaunch and sends once;
- repeated taps cannot create duplicate saved dialogs;
- saving an already-saved or unsent message is not offered.

### Slice 5 - Deletion, backfill, canary, and performance

Files:

- `server/src/auth.ts`
- `server/src/saved-messages.ts`
- `server/scripts/backfill-saved-messages.ts` (new)
- `server/src/saved-messages.test.ts`
- `TojTests/LocalFirstPerformanceTests.swift`
- `server/OPERATIONS.md`

Work:

1. Delete the personal saved dialog with account deletion.
2. Add resumable backfill and runbook.
3. Run load, migration, failure, and physical-device fixtures.
4. Add dashboards and rollout alerts.

Gate:

- deletion and media-reference tests pass;
- backfill can stop/restart and converges without duplicate events;
- performance budgets hold;
- canary shows zero duplicate-dialog invariant violations and zero silent local data loss.

---

## 11. Test plan

### 11.1 Code-path coverage

```text
SERVER PROVISIONING
===================
[+] capability()
    +-- [TEST] flag off -> saved_messages_v1 absent
    +-- [TEST] allowlisted/bucketed account -> advertised
    +-- [TEST] unauthenticated request -> not advertised

[+] POST /v1/dialogs/saved
    +-- [TEST] feature off -> 404 and zero writes
    +-- [TEST] invalid/revoked device -> 401
    +-- [TEST] missing dialog -> create dialog + owner member + one event
    +-- [TEST] healthy existing dialog -> same id + no event
    +-- [TEST] missing member -> repair + one event
    +-- [TEST] 25 concurrent calls -> one id/member/event
    +-- [TEST] retry after simulated response loss -> same result

[+] existing message/media pipeline
    +-- [TEST] text + reply + edit + delete + reaction
    +-- [TEST] photo/file/voice upload and download access
    +-- [TEST] forward into and out of Saved Messages
    +-- [TEST] bootstrap + difference + history
    +-- [TEST] one silent push to another device, no alert

IOS PERSISTENCE
===============
[+] SavedMessagesService.ensure()
    +-- [TEST] local id exists -> no API call
    +-- [TEST] concurrent callers -> one API call
    +-- [TEST] server success -> atomic local dialog/member/summary
    +-- [TEST] transient failure -> retryable state
    +-- [TEST] 404 after advertisement -> permanent rollout mismatch
    +-- [TEST] cancellation -> in-flight slot clears

[+] CloudLocalStore
    +-- [TEST] ensure survives reopen
    +-- [TEST] saved dialog.created inserts owner without peer
    +-- [TEST] repeated event is idempotent
    +-- [TEST] optimistic send/media does not downgrade type
    +-- [TEST] self-authored updates keep unread at zero
    +-- [TEST] replacement bootstrap preserves pending outbox

UI
==
[+] Settings
    +-- [E2E] local saved row -> immediate conversation
    +-- [E2E] first provision online -> spinner then conversation
    +-- [E2E] first provision offline -> clear Retry state

[+] Conversation
    +-- [E2E] text/media/voice optimistic send
    +-- [E2E] offline relaunch and cached-media open
    +-- [TEST] no profile/call/video/presence/unread/private-lock UI
    +-- [TEST] saved-specific empty and delete copy

[+] Save action
    +-- [E2E] save online
    +-- [E2E] save offline, kill, relaunch, reconnect
    +-- [TEST] source deleted before retry -> visible terminal failure
    +-- [TEST] hidden for saved/deleted/unsent messages
```

### 11.2 Required commands

Backend:

```bash
cd server
bun install --frozen-lockfile
bun run migrate
bun test
```

iOS, matching CI:

```bash
scripts/fetch-webrtc-xcframework.sh
pod install
xcodebuild build \
  -workspace Toj.xcworkspace \
  -scheme Toj \
  -configuration Release \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO
xcodebuild test \
  -workspace Toj.xcworkspace \
  -scheme Toj \
  -configuration Debug \
  -destination 'platform=iOS Simulator,name=<available iPhone>' \
  -parallel-testing-enabled NO
```

Performance fixture:

```bash
TOJ_PERFORMANCE_FIXTURES=1 xcodebuild test \
  -workspace Toj.xcworkspace \
  -scheme Toj \
  -destination 'platform=iOS Simulator,name=<available iPhone>' \
  -only-testing:TojTests/LocalFirstPerformanceTests \
  -parallel-testing-enabled NO
```

Run the final performance gate on a representative physical iPhone with LocalFirst signposts in
Instruments.

---

## 12. Observability

Add low-cardinality counters and histograms:

- `saved_messages_ensure_total{result=created|existing|repaired|error}`
- `saved_messages_ensure_duration_seconds`
- `saved_messages_backfill_total{result}`
- `saved_messages_invariant_violation_total`
- existing message send/outbox/difference/bootstrap metrics partitioned by `dialog_type="saved"` only
  if that label is already bounded.

Alert on:

- any invariant violation;
- ensure 5xx rate above 1% for 5 minutes;
- creation-to-first-message failure above baseline;
- repeated repair events;
- backfill errors;
- difference/bootstrap failures above ordinary chat baseline.

Never emit dialog ids, account ids, text, file names, phone numbers, tokens, or media paths.

---

## 13. Rollout

1. Merge Slice 0 so all daily-use branches share the widened capability contract.
2. Deploy server schema, index, endpoint, and metrics with rollout at 0%.
3. Verify migrations twice on a production-like copy and confirm route closure.
4. Ship the compatible iOS build with UI hidden unless capability is present.
5. Allowlist internal accounts. Exercise new account, existing account, two-device, offline, media,
   forward, relaunch, session revocation, and account deletion.
6. Ramp deterministic account buckets: 1%, 10%, 25%, 50%, 100%, holding at least one normal usage
   window at each step.
7. Stop immediately on duplicate-dialog, lost-outbox, bootstrap, or account-deletion failures.
8. Run the bounded backfill only after the 100% client capability is stable.
9. Keep the flag for rollback. Rollback closes provisioning and advertisement but preserves existing
   local/server data.

Launch-review Definition of Done:

- [x] Forward marker migration is expand / bounded keyset backfill / validate-contract; a completed
  normal migration rerun never creates the temporary index or enters the backfill worker.
- [x] Mixed nodes are safe: old provenance-only writes derive the marker, new reads temporarily use
  marker-or-provenance, and deletion detaches provenance while preserving the marker and copy.
- [x] Concurrent partial provenance/reply indexes have invalid-shell cleanup and production-sized
  query-plan proof.
- [x] Database-boundary deletion cleanup makes application rollback compatible while Saved rows
  exist; new binaries fail readiness if the cleanup fence or any schema prerequisite is missing.
- [x] Saved setup/Save/forward are session-generation, token, account, and SQLCipher-store scoped;
  synchronous teardown cancels and awaits tracked work before erasure.
- [x] Optimistic forwarding clones photo/video/file/voice metadata and target `message_media`,
  survives offline and response-before-difference process death, and reconciles by `client_msg_id`.
- [x] Permanent forward failures terminate immediately and atomic Remove drops only the pending
  target reference, retaining shared encrypted cache bytes.
- [x] Completed send receipts are durable; a legacy missing receipt is rebuilt from the canonical
  message without consuming a new message id.
- [x] Unauthorized Saved membership repair emits access revocation, silent push, sync wakeup, and
  causes the receiving SQLCipher replica and encrypted media ledger to purge.
- [x] Owner-only authorization covers history, mutation, media, difference, bootstrap, and fanout,
  with a database invariant preventing new active rogue memberships.
- [x] Current and raw old-node account deletion use one database-boundary cleanup that revokes rogue
  access, detaches provenance, deletes the archive and true orphan chunks, and preserves forwarded
  media.
- [x] Access purge is account/token/store/session-generation scoped, drains every bounded batch on
  launch and after revocation, overrides active playback, deletes encrypted files before SQL, and
  resumes safely after process death.
- [x] Saved Messages cannot be muted or newly archived and remains first/available in the forwarding
  picker even if an old in-memory archive flag is present.
- [x] Russian and Tajik cover all new setup, failure, purge, retry, Remove, and Saved copy.

Old clients decode dialog types as strings and should not corrupt data, but they may present a saved
dialog as a degraded direct chat. Because account events are shared across devices, rollout must favor
accounts whose active devices have upgraded. Do not treat capability advertisement alone as a
cross-version safety mechanism.

---

## 14. Parallel implementation strategy

| Step | Modules | Depends on |
|---|---|---|
| A. Capability width | iOS presentation/model/tests | - |
| B. Server contract | server schema/sync/routes/tests | A contract names only |
| C. iOS API/store/service | iOS core cloud/store/tests | Endpoint contract frozen |
| D. UI and one-tap Save | iOS cloud features/design/localization/UI tests | C |
| E. Backfill/deletion/performance | server ops/auth + performance tests | B + C + D |

Parallel lanes:

```text
Lane A: capability width
                 \
                  +--> Lane B: server contract --------\
                  +--> Lane C: iOS API/store/service ---+--> Lane D: UI/Save --> Lane E
```

Lane B and Lane C can run in parallel after the JSON contract is frozen. Lane D is sequential because
`CloudRootView.swift`, `ConversationExperience.swift`, and `CloudAppModel.swift` are shared UI/model
hotspots.

Conflict flags:

- `mmarufov/persistent-device-drafts`
- `mmarufov/pin-mute-archive-sync`
- `mmarufov/fts5-message-search`

All three sibling features are likely to touch capability mapping, `CloudAppModel`, and
`CloudRootView`. Merge Slice 0 first, keep Saved Messages persistence in its service/store boundary,
and rebase each UI lane before implementation. Do not implement all four epics in one worktree.

---

## 15. NOT in scope

- Cloud drafts and draft conflict resolution. Separate `cloud_drafts_v1`.
- Pin, mute, archive, or folder preference persistence. Separate `dialog_preferences_v1`.
- FTS5 message search, tokenizer selection, highlighting, or saved-only search UI. Separate
  `local_search_v1`.
- Tags, emoji labels, topics, or "view as chats".
- Reminders, scheduled messages, or notifications to self.
- iOS share extension or Files app integration.
- Export/download-all archive.
- A separate Saved Messages media retention policy.
- Mandatory offline availability for media never downloaded to the device.
- Secret Chat or messenger-wide E2EE changes.
- Android, web, or desktop UI, beyond keeping the wire contract platform-neutral.

These are explicit deferrals, not hidden dependencies. Saved Messages v1 is useful without them and
its ordinary `dialog_id`/message rows are the integration point for each later feature.

---

## 16. Definition of done

Saved Messages v1 is done only when all statements are true:

- [x] PostgreSQL allows `saved` and enforces one per account.
- [x] Concurrent provisioning creates one dialog, one active owner membership, and one creation event.
- [x] Disabled capability means no advertisement and no reachable route.
- [x] Settings opens a real conversation, not `SettingsComingSoonView`.
- [x] The Chats list and Settings route resolve the same dialog UUID.
- [x] A previously provisioned saved dialog opens offline from SQLCipher with no network call.
- [x] Text, reply, edit, delete, reaction, forward, photo, video, file, and voice note reuse the existing
      production pipelines.
- [x] Optimistic sends and Saves survive process death and retry exactly once.
- [x] A second device receives changes through ordinary PTS difference sync.
- [x] Saved Messages never shows peer profile, presence, typing, calls, unread, mute, block, or false
      E2EE copy.
- [x] Generic "saved local copy" wording is no longer confused with the Saved Messages product name.
- [x] Account deletion removes the self-only archive and preserves forwarded direct/group text and media.
- [x] Corrupt memberships are reconciled across every Saved dialog, including provisioning-backfill
      skips, with deterministic revocation PTS, silent pushes, and sync wakeups.
- [x] Revoked offline archives purge file-first across launch, process death, active playback,
      account switches, and queues larger than one 20-job batch.
- [x] Direct and group message regressions are green.
- [x] Backend migration, backend tests, Release WebRTC build, serialized iOS tests, and UI tests are
      green on the final review-remediation commit.
- [ ] Representative physical-device performance gates are green.
- [ ] Rollout dashboards show no invariant violation and no silent data loss.

That is the release gate. The feature is not complete when the Settings row merely opens a chat; it is
complete when the same note can be written offline, survive a kill, arrive once on another device, and
be deleted with the account.
