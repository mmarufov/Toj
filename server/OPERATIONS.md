# Toj cloud operations

This file documents public, provider-neutral procedures. Keep hostnames, credentials, phone numbers,
database URLs, encryption identities, and other deployment values in the server secret store or local
gitignored notes.

## Probes and request logs

- `GET /health` is process liveness and does not touch PostgreSQL.
- `GET /ready` checks PostgreSQL and reports only `configured`/`development`/`disabled` provider
  state. It returns `503` until the complete Saved Messages, dialog-preference, and
  draft/media-group catalog contracts are present: exact runtime columns/defaults/nullability,
  validated checks, conflict uniqueness, required indexes, mixed-writer/deletion/compatibility
  triggers, versioned contract markers, completed migration cursors, and empty reconciliation
  state. These requirements remain active even when rollout switches are off. A database failure
  returns `500`; deployment tooling must require `200` before switching traffic.
- Every HTTP response includes `X-Request-ID`. A safe incoming value is preserved; malformed values
  are replaced. JSON request logs contain only time, request ID, method, normalized route, status,
  and duration—never query strings, bodies, bearer tokens, phone numbers, or account IDs.
- `GET /metrics` exists only when `TOJ_METRICS_TOKEN` is set and requires that value as a bearer token.
  Metrics use normalized route labels to avoid secrets and unbounded label cardinality. Preference
  metrics remain available before expand and report `toj_dialog_preference_schema_available 0`;
  retained idempotency size uses PostgreSQL's planner estimate rather than scanning the permanently
  retained dedupe table.

## Maintenance

The server runs an hourly, bounded cleanup. It repeatedly claims eligible rows with `SKIP LOCKED`
until the row or runtime budget is exhausted. Defaults are 1,000 rows per table per pass, 10,000 total
rows, and five seconds; deployments can tune `TOJ_MAINTENANCE_BATCH_SIZE`,
`TOJ_MAINTENANCE_MAX_ROWS_PER_TICK`, and `TOJ_MAINTENANCE_MAX_RUNTIME_MS`.

Cleanup covers expired OTP challenges older than 24 hours, expired bootstrap snapshots, terminal
push deliveries older than seven days, bounded messaging-feature receipts, and already-stamped
message expiries. Expiry enforcement is independent of feature admission: server reads hide an
expired message immediately, then cleanup replaces live ciphertext with a tombstone and removes
reactions, pins, polls/votes, preview data, and unreferenced media. Incomplete media uploads are
resumable for 24 hours and are
then removed with their encrypted chunks; expired upload-attempt rate records and unattached
completed media are also removed. Completed dialog-preference idempotency records are retained until
account deletion because an offline client can retry a lost response after any fixed cleanup window.
Pending records are also never aged out. Message history and attached media are not deleted by this
worker; account events follow the separately configured synchronization retention floor.

## Session security and two-step verification rollout

Authentication v2 and two-step verification are additive and dark by default. Run the migration and
deploy the dual-stack server before shipping the compatible iOS client. The readiness probe requires
the v2 session, access-token, rotation-receipt, two-step, recovery-code, challenge, and throttle tables
even while admission is disabled.

- `TOJ_AUTH_SESSIONS_V2_ENABLED=1` advertises `auth_sessions_v2`, enables legacy in-place upgrade,
  and accepts rotating refresh credentials. Access tokens last 15 minutes, refresh activity lasts 30
  days, and the device session has a non-extendable 180-day lifetime.
- `TOJ_TWO_FACTOR_ENABLED=1` advertises `two_factor_v1`. It is ignored unless auth v2 is also enabled.
  Do not set it until production SMS delivery, the migrated catalog, and v2 refresh metrics are healthy.
- `TOJ_SECURITY_ALERT_SMS_WEBHOOK` is the optional provider adapter for non-secret security alerts.
  Keep its authorization value in `TOJ_SECURITY_ALERT_SMS_TOKEN` in the deployment secret store.

Roll out auth v2 to internal accounts first, then increase compatible-client admission through 1%,
5%, 25%, 50%, and 100% release cohorts. Keep legacy authentication available for at least 30 days and
until 95% of recently active eligible devices have upgraded. Announce a further 30-day deadline before
rejecting legacy tokens. Enable two-step enrollment only after the v2 ramp is stable. Roll back by
disabling enrollment first and then auth-v2 advertisement; retain the additive database objects,
continue accepting credentials already issued to upgraded clients, and continue enforcing existing
two-step enrollments. A rollback closes only new admission: already-created login challenges can be
completed and already-enrolled accounts can inspect, disable, or recover their protection. Rotation
receipts are fenced to the session generation so a late retry can never restore superseded credentials.

Alert on sustained increases in `refresh_failure`, `refresh_replay_revocation`, or `session_expired`
within `toj_auth_security_events_total`. Track `second_factor_failure`, `second_factor_locked`,
`recovery_used`, `recovery_codes_regenerated`, `two_factor_configured`, and
`two_factor_disabled` as aggregate counters only. No
metric or log label may contain an account, phone number, token, recovery code, password, challenge,
rotation ID, or network identifier.

Ordinary idle or absolute expiry requires authentication but preserves the encrypted local replica and
pending outbox. Explicit device revocation and refresh-token replay remain destructive client security
events. Before broad release, verify signed-simulator Keychain and LocalAuthentication tests, then use
physical devices to cover Face ID/passcode fallback, background refresh, push and VoIP notifications,
CallKit answering, weak-network rotation response loss, and remote-device socket revocation.

Only abandoned `pending` send claims expire after 24 hours. Completed send receipts remain durable so
a device retrying after days can recover the canonical `client_msg_id`.

## Abuse-reporting rollout and response

`abuse_reports_v1` is hidden unless the additive schema and every operational gate is present:

- `TOJ_ABUSE_REPORTS_ENABLED=1`
- `TOJ_ABUSE_REPORTS_OPERATOR_READY=1`, set only while a named moderator is on call
- `TOJ_MODERATION_OPERATOR_ID`, identifying that on-call moderator in the audit trail
- `TOJ_ABUSE_REPORTS_ALERTING_READY=1`, set only after urgent/standard age alerts are live
- `TOJ_ABUSE_REPORTS_ESCALATION_CONTACT`, containing the private escalation route in the secret store

Migrate with the feature disabled, configure alerts for `toj_abuse_reports_open` and
`toj_abuse_reports_oldest_seconds`, rehearse the operator workflow, and then enable it universally.
Page at four hours for urgent child-safety/violence reports and 24 hours for standard reports. Do not
percentage-roll out a safety mechanism or advertise the capability without an active response owner.

Use `TOJ_MODERATION_OPERATOR_ID` to identify every read and mutation. Operator notes are accepted
only on stdin, encrypted at rest, and never passed as process arguments. Examples:

```bash
bun run moderation:reports -- list 50
bun run moderation:reports -- view REPORT_UUID
printf '%s' 'triage note' | bun run moderation:reports -- claim REPORT_UUID
printf '%s' 'resolution note' | bun run moderation:reports -- resolve REPORT_UUID
```

`list` returns the unresolved queue in stable priority/age order. `view` refuses to emit decrypted
evidence when stdout is redirected; `--redacted-json` emits only metadata and omits sensitive notes.
`remove` and `ban` additionally require `TOJ_MODERATION_DESTRUCTIVE_CONFIRM` to equal the report UUID.
Those commands respectively replace the live message with the normal deletion tombstone, or ban the
reported account, end its active direct calls, revoke its group-call participation, hand off groups
it owns, and revoke its sessions and push registrations. A commit-scoped account-security event
closes sessions on every connected server; a five-second database reconciliation pass closes any
session whose notification was missed. Workflow mutations are appended to
`abuse_report_actions`; every list/view access is appended to the separate, immutable
`content_access_audit` log, including whether evidence was decrypted.

Production uses separate PostgreSQL roles. The migration owner owns the audit tables and the bounded
`toj_cleanup_abuse_reports_v1(integer)` security-definer function. The application/operator role is
granted `SELECT`/`INSERT`/`UPDATE` on `abuse_reports`, `SELECT`/`INSERT` on submission budgets and
actions, `INSERT` on `content_access_audit`, and `EXECUTE` on the cleanup function. It is never
granted direct `DELETE` or `TRUNCATE` on moderation tables, or `UPDATE` on budgets/actions/access
audit, and it must not own either append-only table. The schema revokes public function execution.
`abuse_reports_v1` remains hidden when production readiness detects missing required rights, unsafe
extra rights, role ownership, or cleanup execution. Caller-set session variables cannot bypass the
owner-checked append-only triggers.

Unresolved encrypted evidence is retained until resolution. The bounded maintenance worker clears
evidence 90 days after resolution, retains non-content report/audit metadata for 365 days, and removes
submission-budget rows after 24 hours.

## Envelope encryption and blind-index rotation

`TOJ_CRYPTO_MODE` has three explicit states: `legacy`, `envelope-canary`, and `envelope`. Legacy
continues to read and write `dev-v1`. Canary dual-reads every format but writes wrapped per-account
DEKs only for `TOJ_ENVELOPE_CANARY_ACCOUNTS` and the deterministic
`TOJ_ENVELOPE_CANARY_PERCENT`; service scopes always use envelope writes in canary mode. Envelope
writes every new payload through a wrapped DEK while retaining legacy reads for migration.

`TOJ_KEY_ENCRYPTION_PROVIDER=local` is test/development-only and the process rejects it in
production. A production provider must implement the `KeyEncryptionProvider` contract and be
registered in the deployment build. Provider credentials, KEK identifiers, and IAM policy stay in
the secret store. `/ready` remains `503` in production while the server is in legacy mode or a real
provider is unhealthy, and `/metrics` exports `toj_envelope_crypto_launch_blocking`.

The separate blind-index keyring protects cross-account deterministic lookup and must never use an
account DEK. `TOJ_BLIND_INDEX_KEYRING` is a JSON object of version IDs to base64 32-byte keys;
`TOJ_BLIND_INDEX_ACTIVE_KEY_ID` selects new phone, OTP/rate-limit, token, media-digest, and
idempotency writes. The legacy HMAC key remains readable during migration. Production readiness is
blocked while only `legacy-v1` is active. Remove a historical key only after all rows carrying its
key ID have expired or been backfilled and every application node has stopped writing it.
Media-group fallback message IDs are durable protocol state and use a separate, immutable
`TOJ_PROTOCOL_ID_KEY`. Before disabling `legacy-v1`, set that value to the current `TOJ_HMAC_KEY`
on every node; it is not a rotating database blind-index key.

Rotate in two deployments: first add the new key as readable on every node while the old key remains
active, then verify every node reports the same readable set before switching the active key. Mixed
active-key nodes are safe only when all of them know both versions, because identity and rate-limit
mutations lock every candidate digest. Backfill recoverable phone rows after the active-key switch;
keep old keys readable until the database audit reaches zero for opaque tokens, call-attempt/network
budgets, media digests, URL/cache keys, and idempotency receipts that expire or rotate on use.

Inspect state and perform bounded operations with:

```bash
bun run crypto:keys -- status
bun run crypto:keys -- rotate account ACCOUNT_UUID
bun run crypto:keys -- rotate service moderation-evidence
bun run crypto:keys -- migrate all --from=dev-v1 --batch=100
TOJ_CONFIRM_CRYPTO_WRITE_MODE=envelope-canary \
  bun run crypto:keys -- activate-mode envelope-canary
TOJ_CONFIRM_CRYPTO_WRITE_MODE=envelope \
  bun run crypto:keys -- activate-mode envelope
TOJ_BLIND_INDEX_KEYRING='{"lookup-v2":"BASE64_32_BYTE_KEY"}' \
TOJ_BLIND_INDEX_ACTIVE_KEY_ID=lookup-v2 \
  bun run crypto:keys -- migrate-blind phones --from=legacy-v1 --batch=100
TOJ_ALLOW_CRYPTO_BENCHMARK=1 bun run benchmark:envelope-migration -- \
  messages --from=dev-v1 --batch=500 --max-batches=1000
bun run crypto:keys -- audit DATA_KEY_UUID
bun run crypto:keys -- rewrap DATA_KEY_UUID
TOJ_CONFIRM_RETIRE_KEY=DATA_KEY_UUID bun run crypto:keys -- retire DATA_KEY_UUID
```

DEK rotation switches new writes immediately. Re-encryption then claims bounded `SKIP LOCKED`
batches for phone identity, messages and service messages, drafts and cached responses, push/VoIP
tokens, media metadata/chunks, moderation evidence/notes, chat-folder titles, scheduled payloads,
and link-preview URLs/metadata/assets. Each update compares the old key ID,
so a concurrent edit wins rather than being overwritten. A worker that encounters a writer-held
scope fence yields the locked row and automatically retries after committing the bounded batch;
it never waits in the inverse row/key lock order. Durable cursors make restarts observable, and a
failed batch is transactional, so the next invocation safely resumes without partial-batch state.
`rotate` changes the DEK. `rewrap` changes only the provider KEK wrapping. `retire` refuses until the
configured rollback/backup window has elapsed and the database-wide ciphertext reference audit is
zero. Retirement is deliberately two-phase across processes: the first confirmed invocation writes
a durable revocation marker, fences all new unwraps, and reports `state: "draining"`. Rerun it only
after the returned `finalizeAfter`; the second invocation then erases the wrapped key and reports
`state: "retired"`. The drain exceeds the enforced five-minute plaintext-cache TTL, and every cache
entry zeroizes itself on expiry, so a worker that cached the key before revocation cannot retain or
use it after destructive retirement. Never bypass or shorten this drain. The unused private-beta
`user_reports` scaffold is included in the reference audit; any historical
snapshot there must be reviewed and removed under the retention policy because it has no safe
automatic AAD migration. Deleted-account tombstones and their wrapped keys remain while retained
messages or media still reference them.

Final cutover is two-dimensional: every application process must run the matching mode and the
database mode must be advanced with `activate-mode`. The final command takes a short writer fence,
and flips a non-downgradable database epoch even while historical `dev-v1` rows remain. Triggers then
reject any inserted or changed legacy ciphertext tuple, including writes from an old process, while
dual-read migration continues. Production readiness remains launch-blocking until the reference
audit reaches zero; do not retire the legacy key or represent migration as complete before then. Do
not change `crypto_write_state` manually. Phone blind indexes can be recomputed in bounded batches;
opaque session and OTP inputs rotate on successful use or disappear through normal retention.
Upload-only media digests stop being dependencies once completion succeeds. Durable idempotency
operation IDs remain consumed, while their canonical keyed fingerprints are cryptographically
tombstoned after a 90-day retry horizon so dormant receipts cannot pin an old key forever. Keep
every historical blind-index key configured until the exact `crypto:keys status` operator audit
reports zero references across all domains. `/ready` and `/metrics` share that exact audit through a
short, single-flight cache to prevent health probes from repeatedly scanning retained data.

Only after `crypto:keys status` reports zero `legacy-v1` references, deploy
`TOJ_BLIND_INDEX_LEGACY_DISABLED=1` together with the versioned keyring and remove `TOJ_HMAC_KEY`.
Also retain the matching `TOJ_PROTOCOL_ID_KEY` described above. The process refuses the switch
without both a versioned active key and that protocol key, and readiness fails closed if any
persisted legacy label reappears. Likewise, final envelope mode loads `TOJ_MESSAGE_KEY` only when an
actual `dev-v1` ciphertext is read; remove that secret only after the legacy ciphertext audit is
zero and the rollback/backup window has expired. Legacy and canary modes still require it at startup.

During a provider outage, cached DEKs can continue reads until their bounded TTL expires. Cache
misses, new scope keys, rotation, and uncached writes return retryable `crypto_unavailable`; unknown
or corrupt key IDs fail closed. After envelope activation there is no fallback write to the
environment key. Before production enablement, complete a staging provider-outage and rotation
drill, measure migration runtime/WAL on production-sized data, validate backups across the full
retirement window, and canary selected internal accounts. Repository support is not evidence that a
live KMS/HSM or its IAM policy has been deployed.

## Encrypted group-call rollout and drain

Group calls are dark by default. Production requires managed LiveKit Cloud because this version
uses the provider's room-token revocation cutoff when membership changes; the server rejects a
self-hosted LiveKit configuration in production. Keep these values in the deployment secret store:

- `TOJ_GROUPS_V1_ENABLED=1`
- `TOJ_GROUP_CALLS_ENABLED=1`
- `TOJ_GROUP_CALLS_SFU_READY=1`
- `TOJ_GROUP_CALLS_E2EE_REQUIRED=1`
- `TOJ_LIVEKIT_URL`, `TOJ_LIVEKIT_API_KEY`, and `TOJ_LIVEKIT_API_SECRET`
- `TOJ_LIVEKIT_DEPLOYMENT=cloud`
- `TOJ_GROUP_CALLS_ALLOWLIST` and `TOJ_GROUP_CALLS_ROLLOUT_PERCENT` (default zero)
- `TOJ_GROUP_SCREEN_SHARING_ENABLED` and `TOJ_GROUP_SCREEN_SHARING_READY` (both must be `1`)

Deploy in this order:

1. Run the database migration with admission off. Require `GET /ready` to return `200`; the exact
   group-call schema contract is checked even while the feature is disabled.
2. Deploy the server and LiveKit credentials with an empty allowlist and zero-percent rollout.
   Confirm `toj_group_call_schema_available 1` and that the SFU backlog metrics are zero.
3. Ship the compatible iOS build and its provisioned ReplayKit broadcast extension. Screen sharing
   stays independently off until both screen-sharing switches are set.
4. Allowlist internal accounts, then increase the deterministic rollout percentage in stages.
   Stop expansion on any sustained SFU backlog, lease cleanup, rekey, capacity, thermal, or network
   regression.

To drain safely, first set `TOJ_GROUP_CALLS_ROLLOUT_PERCENT=0` and clear the allowlist while keeping
the base group-call switch, SFU-ready switch, E2EE requirement, and LiveKit credentials in place.
This blocks new starts and joins while existing heartbeats, leaves, membership fencing, and the
durable SFU reconciliation worker continue. End remaining rooms through the normal admin controls or
wait for them to close. Do not turn off `TOJ_GROUP_CALLS_ENABLED`, remove the credentials, or stop
the SFU worker until all of these gauges reach zero:

- `toj_group_call_active_rooms`
- `toj_group_call_rekeying_rooms`
- `toj_group_call_sfu_pending_states`
- `toj_group_call_sfu_failed_states`
- `toj_group_call_sfu_oldest_pending_seconds`
- `toj_group_call_expired_media_leases`

After the drain, disabling admission is an application rollback; retain the additive tables,
constraints, indexes, and migration markers. Page on a nonzero failed-state gauge, a growing oldest
pending age, or expired leases that survive a cleanup interval. Do not enable beyond internal users
until multi-region SFU capacity, Apple provisioning, physical-device carrier/thermal behavior, and
32-participant load and adversarial security tests have passed.

## Media storage

Media works without an Apple Developer account or a third-party storage provider. Resumable chunks
and thumbnails are AEAD-encrypted before PostgreSQL persistence. Deploy the schema before deploying
clients that send media. These optional server settings are byte counts and are bounded to safe ranges:

- `TOJ_MEDIA_CHUNK_BYTES` (legacy offset-v1 only; default 1048576)
- `TOJ_MEDIA_MAX_OBJECT_BYTES` (default and hard maximum 26214400 / 25 MB)
- `TOJ_MEDIA_ACCOUNT_QUOTA_BYTES` (default and hard maximum 262144000 / 250 MB)
- `TOJ_MEDIA_MAX_ACTIVE_UPLOADS` (default 10)
- `TOJ_MEDIA_MAX_DAILY_UPLOADS` (default 100)

The iOS client keeps downloaded media encrypted on disk and, by default, retains it until the user
clears it. Existing user-selected limits remain authoritative. The low-disk reserve is the only
automatic deletion path: it preserves 5% free space, clamped to 1–5 GB, and surfaces a storage notice
when reclamation occurs. Pending uploads are never evicted; new selections fail cleanly when the local
quota cannot accommodate them.

API version 3 adds `media_multipart_v2`. Clients using it upload numbered, idempotent parts out of
order with up to three concurrent requests: 256 KiB parts through 10 MiB and 512 KiB parts above
10 MiB. Completion checks the exact part layout, declared byte count, SHA-256, media signature, and
photo dimensions before making an object usable. The offset-v1 route remains available for older
clients and cannot write into a multipart upload.

The 25 MB object ceiling is a safety boundary, not a rollout default that may be raised casually.
Startup rejects `TOJ_MEDIA_MAX_OBJECT_BYTES` above 26214400. Do not advertise or accept 100 MB
objects until iOS uploads/downloads are file-streamed and media bytes live in external object
storage instead of PostgreSQL chunks. The current 250 MB account quota is subject to the same
architecture review before any increase.

## Productivity workers and dark rollout

Chat folders, scheduled delivery, and link previews retain independent account gates. Scheduled
delivery and link previews must be deployed with their global switches off, rollout percentages at
zero, and allowlists empty. A successful migration, readiness probe, or test run never authorizes
rollout. The relevant variables are:

- `TOJ_SCHEDULED_DELIVERY_V1_ENABLED`, `TOJ_SCHEDULED_DELIVERY_ALLOWLIST`, and
  `TOJ_SCHEDULED_DELIVERY_ROLLOUT_PERCENT`
- `TOJ_LINK_PREVIEWS_V1_ENABLED`, `TOJ_LINK_PREVIEWS_ALLOWLIST`, and
  `TOJ_LINK_PREVIEWS_ROLLOUT_PERCENT`
- `TOJ_SCHEDULED_DELIVERY_WORKER_CONCURRENCY` (default 8, integer 1–32)
- `TOJ_LINK_PREVIEW_WORKER_CONCURRENCY` (default 4, integer 1–16)
- `TOJ_PRODUCTIVITY_WORKER_LEASE_SECONDS` (default 120, integer 30–600)

Workers claim only open concurrency slots. Claims carry token-owned leases, renewed at least every
30 seconds (and every ten seconds at the minimum lease); a superseded token cannot complete or retry
work. Heartbeats run independently every ten seconds. Shutdown stops new claims, aborts active
preview fetches, and gives active jobs a bounded drain. Preview resolution commits quickly, then a
restart-safe fanout drain handles at most 25 waiters per transaction and 100 per tick.

Capability and relevant sync/message routes share one five-second, single-flight heartbeat snapshot.
Freshness is evaluated against the 30-second boundary on each request and database errors fail
closed. Media, call, group, and unrelated authenticated routes do not query productivity heartbeats.
Monitor `toj_productivity_active_jobs`, `toj_productivity_lease_renewal_failures_total`,
`toj_link_preview_resolved_waiters_total`, `toj_link_preview_oldest_fanout_seconds`, and
`toj_productivity_heartbeat_cache_database_errors_total`. Halt rollout on lost leases, growing
fanout age, heartbeat errors, duplicate scheduled sends, or preview backlog growth.

## Messaging parity and multi-account dark rollout

Messaging parity is additive and account-dark by default. Each creation/mutation capability requires
both its global switch and either a matching account allowlist entry or a nonzero deterministic
rollout percentage. Keep every percentage at zero and every allowlist empty after deployment:

- `TOJ_PINNED_MESSAGES_ENABLED` with `TOJ_PINNED_MESSAGES_ALLOWLIST` /
  `TOJ_PINNED_MESSAGES_ROLLOUT_PERCENT`
- `TOJ_AUTO_DELETE_ENABLED` with `TOJ_AUTO_DELETE_ALLOWLIST` /
  `TOJ_AUTO_DELETE_ROLLOUT_PERCENT`
- `TOJ_POLLS_ENABLED` with `TOJ_POLLS_ALLOWLIST` / `TOJ_POLLS_ROLLOUT_PERCENT`
- `TOJ_STICKER_PACKS_ENABLED` with `TOJ_STICKER_PACKS_ALLOWLIST` /
  `TOJ_STICKER_PACKS_ROLLOUT_PERCENT`
- `TOJ_GIPHY_ENABLED` with `TOJ_GIPHY_ALLOWLIST` / `TOJ_GIPHY_ROLLOUT_PERCENT`; this also requires
  `TOJ_GIPHY_AGREEMENT_APPROVED=1` and a valid secret `TOJ_GIPHY_API_KEY`
- `TOJ_MULTI_ACCOUNT_PUSH_ENABLED` with `TOJ_MULTI_ACCOUNT_PUSH_ALLOWLIST` /
  `TOJ_MULTI_ACCOUNT_PUSH_ROLLOUT_PERCENT`

`TOJ_SUPPORT_ENABLED` is a global documentation switch; `TOJ_SUPPORT_EMAIL` is published only when
syntactically valid. Read/render and expiry enforcement remain installed when creation switches are
closed. Never remove the additive schema to roll back. Before any internal enablement, require clean
schema readiness plus physical-device APNs/VoIP routing proof; GIPHY also requires the production
agreement, attribution, and privacy smoke test. Stop immediately for cross-account routing,
post-expiry exposure, anonymous-voter disclosure, or unauthorized mutation.

## Encrypted backups

`scripts/backup-postgres.sh` streams a PostgreSQL custom-format dump directly into `age`, writes it
atomically with mode `0600`, and creates a SHA-256 sidecar. Required environment variables:

- `TOJ_BACKUP_DATABASE_URL`
- `TOJ_BACKUP_DIR`
- `TOJ_BACKUP_AGE_RECIPIENT` (public recipient only)

Keep the age private identity off the application server. Copy both the encrypted backup and its
checksum to separate storage. Retention deletion is intentionally outside this script so a broken job
cannot erase the last good backup.

The production timer templates are under `ops/`. Install the script separately at
`/usr/local/sbin/toj-backup-postgres` rather than executing it inside a private application directory;
the `postgres` service user should not be granted traversal access to the application files. Store the
three variables above in `/etc/toj/backup.env`, readable only by root and the database service group.

## Restore drill

Run `scripts/restore-drill.sh` against a newly created, empty, disposable PostgreSQL database. It
verifies the checksum, decrypts to a private temporary file, validates the archive, refuses a
non-empty target, restores with `--exit-on-error`, and verifies critical tables. It requires:

- `TOJ_BACKUP_FILE`
- `TOJ_BACKUP_AGE_IDENTITY`
- `TOJ_RESTORE_DATABASE_URL`
- `TOJ_RESTORE_CONFIRM=DISPOSABLE_DATABASE`

Do not point the drill at production. A restore is not considered proven until this command passes.

## Legacy WebSocket rollout switch

`TOJ_ALLOW_LEGACY_WS_QUERY_TOKEN=1` temporarily accepts old clients whose WebSocket bearer token is
in the URL query. New clients use the `Authorization` header. Enable the switch only for a coordinated
upgrade because URLs can appear in proxy and access logs. After all active test installs are updated,
remove the variable from the private service environment and restart the service. The secure default
is off; an unset variable rejects query tokens.

`TOJ_RETURN_OTP=1` is a separate private-development switch that can return the OTP in the auth
response when no SMS provider exists. In production it also requires `TOJ_DEV_OTP_ALLOWLIST`, a
comma-separated server-secret list of the exact international phone numbers permitted to receive a
code in the response. All other numbers fail closed without an SMS adapter. Readiness labels this
mode `development` without exposing the allowlist. Remove both variables as soon as real SMS delivery
is configured.

Profile updates are mixed-version safe: an omitted `username` key preserves the current handle,
while explicit JSON `null` or an empty string clears it. New clients send an explicit null when the
user removes a handle. Reject non-string, non-null values rather than interpreting them as clears.

## Profile photo rollout

Profile photos are additive and dark by default. Run the ordinary migration first, deploy the
server with `TOJ_PROFILE_PHOTOS_V1_ENABLED` unset, and confirm that `/v1/capabilities` does not
advertise `profile_photos_v1`. The server admits the feature only when the purpose-constraint
migration, account reference/revision constraints, and durable mutation table are all validated.

Ship the compatible client before setting `TOJ_PROFILE_PHOTOS_V1_ENABLED=1` for an internal
environment. During expansion, monitor the existing route/status metrics for
`/v1/profile/photo`, media upload/complete latency and 4xx responses, plus cleanup backlog. Alert on
sustained 409 growth (stale edits or idempotency misuse), terminal upload validation failures,
unexpected media-download 401/403/404 changes, and a cleanup backlog that does not drain.

Validate with two real accounts and two owner devices under packet loss: set, terminate/relaunch,
conflicting edits, explicit conflict resolution, removal, partner visibility, membership revocation,
and cache eviction/redownload. Roll back by clearing `TOJ_PROFILE_PHOTOS_V1_ENABLED`; canonical
metadata and encrypted pending client work remain intact so a later re-enable can reconcile safely.

## Presence and typing rollout

Presence is dark by default and requires the additive `account_presence` and
`device_presence_leases` contract. Run the migration before deploying this binary; `/ready` fails
closed when the contract or expiry indexes are missing.

- `TOJ_PRESENCE_V1_ENABLED=1` enables the authenticated protocol globally.
- `TOJ_PRESENCE_ALLOWLIST` admits comma-separated internal account UUIDs.
- `TOJ_PRESENCE_ROLLOUT_PERCENT` is a deterministic account rollout and defaults to zero.

Deploy the schema with admission off, ship the compatible client, then validate foreground,
background, force-quit, reconnect, multi-device, group membership, and block behavior with an
allowlisted cohort. Expand only while `toj_presence_expired_leases` stays at zero after a cleanup
interval and `toj_presence_oldest_expired_seconds` does not grow. Presence metrics contain aggregate
counts only; never add account or dialog identifiers as labels.

Rollback by setting the percentage to zero or clearing `TOJ_PRESENCE_V1_ENABLED`. Clients remove
ephemeral online and typing state and show status unavailable; the additive tables and encrypted
last-seen cache can remain. Do not use `devices.last_seen_at` as user presence: background requests
also authenticate devices, while presence_v1 records only foreground leases.

## Account deletion

Account deletion is a reauthenticated two-step flow: authenticated `POST /v1/account/deletion/start`
issues an `account_deletion` OTP, then authenticated `DELETE /v1/account` consumes that purpose-bound
code. Login OTPs cannot delete accounts and deletion OTPs cannot create sessions.

Deletion atomically marks the account deleted, replaces the phone lookup identity and encrypted phone
with non-identifying values, changes the profile name to `Deleted Account`, destroys every device
credential hash and device name, removes push tokens, kills pending push work, removes OTP rows, and
revokes all sessions. Existing message rows remain so other participants do not lose their history and
foreign-key integrity is preserved. A later registration with the same phone creates a new account ID.

Saved Messages is the exception to retained conversation history: it has only the deleting account as
an active member, so account deletion removes that dialog and its messages in the same transaction.
Before removal, any direct/group copy forwarded from that archive has its source-account/dialog/message
foreign keys cleared atomically. The copy retains its immutable `is_forwarded` classification,
ciphertext, and media references, so recipients keep the forwarded content without retaining a dangling
identity or a dependency on the deleted archive. Media owned by the deleted account is removed only
when no retained message still references it.

The same database-owned status trigger purges account-private cloud drafts and attachments,
draft/album replay receipts and mutation budgets, dialog preferences and their requests/budgets,
draft/preference sync events, and bootstrap snapshots. It runs for a raw legacy
`UPDATE accounts SET status = 'deleted'` as well as the current API. Media deletion is reference
checked after all private rows are removed: any surviving message, dialog photo, or another draft
keeps the encrypted object and chunks. The migration reconciles already-deleted accounts before
publishing `account-private-cleanup-v1`.

## Saved Messages rollout

Saved Messages is dark by default. Migrate PostgreSQL before enabling it; API version 5 adds the
authenticated `saved_messages_v1` capability and `POST /v1/dialogs/saved`.

- `TOJ_SAVED_MESSAGES_V1_ENABLED=1` enables the route family globally.
- `TOJ_SAVED_MESSAGES_ALLOWLIST` is a comma-separated list of account UUIDs that bypass percentage
  rollout.
- `TOJ_SAVED_MESSAGES_ROLLOUT_PERCENT` accepts 0 through 100 and defaults to zero.

The route returns `404` and performs no mutation when the global switch or the authenticated
account's rollout bucket is off. Deploy the schema and endpoint at zero percent, ship the compatible
iOS client, then allowlist internal multi-device accounts before increasing deterministic buckets.
Rollback by setting the percentage to zero or clearing the global switch; existing server and
encrypted local data is preserved.

After the compatible client is stable at full rollout, provision existing accounts in bounded,
restart-safe batches:

```bash
NODE_ENV=production \
TOJ_SAVED_MESSAGES_V1_ENABLED=1 \
TOJ_SAVED_MESSAGES_ROLLOUT_PERCENT=100 \
TOJ_SAVED_MESSAGES_BACKFILL_CONFIRM=PROVISION_ALL_ACTIVE_ACCOUNTS \
TOJ_SAVED_MESSAGES_BACKFILL_BATCH_SIZE=100 \
TOJ_SAVED_MESSAGES_BACKFILL_THROTTLE_MS=25 \
bun run backfill:saved-messages
```

The command fails closed unless production mode, the global switch, an explicit 100% rollout, and
the exact confirmation value are all present. It logs aggregate counts only, handles
`SIGINT`/`SIGTERM` between accounts, and stops on a failed batch rather than hot-looping. Durable
worker-owned claims prevent concurrent workers from selecting the same account; abandoned claims
become reclaimable after 15 minutes. A worker refreshes and verifies ownership immediately before
each account, so a reclaimed lease is never processed by its former owner. The throttle is per
processed account, defaults to 25 ms, and is bounded to 60 seconds.

The dialog type constraint deploys in expand/validate/contract phases. `schema-dialogs-expand.sql`
adds the wider constraint as `NOT VALID`, PostgreSQL validates it without blocking ordinary
reads/writes, and `schema-dialogs-swap.sql` holds `ACCESS EXCLUSIVE` only for the short name swap.
The forward marker has its own expand/backfill/contract sequence. Expand adds the column and trigger;
old writers that omit the marker are classified from complete provenance. The temporary partial
index contains only unfinished legacy rows, and the Bun worker advances a durable `(dialog_id,
msg_id)` cursor in bounded transactions. Contract validates the invariant and removes the empty
temporary index. Normal `schema.sql` reruns never update `messages.is_forwarded`, and completed
migrations skip both temporary-index creation and the keyset worker.

Keep Saved Messages at zero percent until both contracts complete. An application rollback is safe
only while these database artifacts remain installed. The account-status trigger performs Saved
archive deletion and provenance detachment at the database boundary, so an older application binary
cannot strand an archive or cascade-delete forwarded copies. The new binary also refuses readiness
and capability advertisement if that trigger or any required catalog object is absent. Never roll
the database contract back while Saved rows may exist; close advertisement/ensure with the feature
switch instead. The mixed-node regression covers old-writer insertion, new-reader derivation, and
account deletion. The production-like migration test is:

```bash
bun run test:migration:forward
```

It refuses non-local databases unless the database name ends in `_migration_test`, loads 100,000
messages, runs concurrent writes during bounded backfill, verifies WAL/runtime budgets and both query
plans, checks interrupted-index cleanup, and reruns the normal migration twice. It does not run the
production Saved-dialog provisioning backfill.

Protected `/metrics` output includes `toj_saved_messages_ensure_total` by bounded result,
ensure duration sum/count, and `toj_saved_messages_invariant_violation_total`. Page immediately on
invariant repairs or sustained ensure errors; none of these series contains account or dialog data.

## Dialog preference rollout

`dialog_preferences_v1` and `PUT /v1/dialogs/:id/preferences` are advertised only when
both switches permit them at process startup:

- `TOJ_DIALOG_PREFERENCES_V1_ENABLED=1` enables the client entrypoint (capability and route).
- `TOJ_DIALOG_PREFERENCES_BEHAVIOR_ENABLED=0` is the behavior kill switch. It suppresses the
  capability/route, disables preference-driven auto-unarchive, and makes every application fanout
  path read the legacy notification mode. Its secure rollout default is enabled when unset so
  existing deployments need only gate the client entrypoint.

With either gate closed, the preference route family hard-404s. The legacy group-notification route
stays available and writes `dialog_members.notification_mode`. The database compatibility trigger
mirrors that value and emits the account PTS update needed by new clients, including while old and
new server nodes overlap. The trigger deliberately remains active when behavior is killed so a
rollback cannot strand a durable legacy mute or create a sync gap.

Readiness always requires every preference table and exact runtime column signature, every primary
or unique constraint used by `ON CONFLICT`, the enabled
`dialog_members_notification_mode_mirror` trigger bound to the final versioned function, the exact
validated `account_events_type_check`, contract version 1 with its completion timestamp, the
completed `dialog_preferences_v1` backfill cursor, and an empty legacy reconciliation table. This is
independent of the rollout switches because ordinary message fanout, direct-dialog creation, and
bootstrap SQL are compiled against the expanded schema. Until all conditions hold, the process must
not receive traffic; capability advertisement, the preference route, and preference-driven fanout
also remain disabled. Rerunning only the expand phase atomically clears the contract marker and
installs the versioned staging trigger, so readiness remains `503` until contract completes again.

Run `bun run migrate` before enabling either client entrypoint. It applies a short-lock expand,
resumable bounded backfill, concurrent indexes, separately validates the replacement event
constraint, then swaps constraints in a short contract transaction. Its final JSON log includes
runtime, rows, batches, legacy reconciliation count, and WAL bytes. Production automation should set
`TOJ_DIALOG_PREFERENCES_MIGRATION_MAX_RUNTIME_MS` and
`TOJ_DIALOG_PREFERENCES_MIGRATION_MAX_WAL_BYTES` to measured deployment limits.

Roll out in this order: migrate/backfill with the entrypoint off, deploy compatible server nodes,
distribute the iOS build, then enable the entrypoint and restart nodes. Confirm API version 5
advertises `dialog_preferences_v1`, preference-route errors remain flat, account `pts` gaps do not
increase, the client retry backlog drains, and muted deliveries are silent while unmuted deliveries
alert. Roll back client entry by clearing `TOJ_DIALOG_PREFERENCES_V1_ENABLED`; kill preference-driven
server behavior by additionally setting `TOJ_DIALOG_PREFERENCES_BEHAVIOR_ENABLED=0`. Stored
pin/archive/mute values and mirrored legacy group mute remain intact for a later re-enable.

Account deletion purges preference rows, idempotency payloads, budget rows, preference events, and
bootstrap snapshots because they are private presentation state. Delivered message history remains
under the separate message-retention contract.

## Cloud drafts and media-group rollout

`cloud_drafts_v1` and `media_groups_v1` remain independently controlled by
`TOJ_CLOUD_DRAFTS_V1_ENABLED` and `TOJ_MEDIA_GROUPS_V1_ENABLED`, but neither capability is advertised
unless the shared draft/media schema manifest is fully ready. The same effective availability is
used by draft hydration, difference/bootstrap sync, draft consumption, draft routes, and grouped
sends, so a partial schema fails closed even if a node is reached outside the load balancer.

Run `bun run migrate` before enabling either switch. The runner validates and swaps the existing
message/event constraints, builds the cleanup/replay indexes, installs the account-private deletion
boundary, reconciles any deleted-account residue in bounded batches, and only then publishes the
`account-private-cleanup-v1` marker. Require `/ready` to return `200`, then verify authenticated and
unauthenticated capability responses before admitting traffic. Rollback is by clearing the two
feature switches; do not remove the database cleanup function or status trigger while any binary
can create draft, album, Saved, or preference state.

## Cloud folders, scheduled delivery, and link-preview rollout

These three features share the cloud-productivity schema migration but have independent account
rollouts and kill switches. Run `bun run migrate` before deploying the compatible binary. Keep every
switch at zero until `/ready` is healthy and the contract marker
`cloud-productivity-contract-v1` exists.

- Chat folders: `TOJ_CHAT_FOLDERS_V1_ENABLED=1`, `TOJ_CHAT_FOLDERS_ROLLOUT_PERCENT=0..100`,
  and optional `TOJ_CHAT_FOLDERS_ALLOWLIST` account UUIDs.
- Scheduled delivery: `TOJ_SCHEDULED_DELIVERY_V1_ENABLED=1` (or
  `TOJ_SCHEDULED_DELIVERY_V1_ACCEPTING=1`), `TOJ_SCHEDULED_DELIVERY_ROLLOUT_PERCENT`, and
  optional `TOJ_SCHEDULED_DELIVERY_ALLOWLIST`.
- Link previews: `TOJ_LINK_PREVIEWS_V1_ENABLED=1`, `TOJ_LINK_PREVIEWS_ROLLOUT_PERCENT`, and
  optional `TOJ_LINK_PREVIEWS_ALLOWLIST`.

Run the durable workers independently from the HTTP process in production:

```bash
bun run worker:scheduled-delivery
bun run worker:link-preview
```

The HTTP process also starts both workers for local development and single-process test deployments.
Set `TOJ_PRODUCTIVITY_WORKERS_DISABLED=1` there when dedicated worker services are active.
The scheduled-delivery management capability is advertised only when its schema is complete, the
account is in rollout, and the scheduled worker heartbeat is fresh. A stale heartbeat removes the
capability but does not hide previously accepted rows, sync updates, or cancellation from a client
that already knows the route: reads and cancellation remain available. Only create and reschedule
fail closed with `503 scheduled_worker_unavailable` and `Retry-After` until a heartbeat is fresher
than 30 seconds. Link-preview advertisement also requires its worker heartbeat. Folder capability
does not require a worker.

Deploy in this order: expand/validate/contract migration; compatible HTTP nodes with all feature
switches off; both worker services; iOS build; internal allowlists; 1%, 10%, 50%, then 100% account
rollout. Before each increase, verify no account PTS gaps, no growing `processing` leases older than
30 seconds, no stale worker heartbeats, stable dispatch lag, bounded preview failures, and flat 5xx
rates. The migration, route families, account events, maintenance cleanup, and encrypted columns
must remain installed during an application rollback.

Scheduled delivery is server-owned after an idempotent create is accepted, even if the response is
lost. The iOS client durably stages creates and records the attempt before the HTTP commit point; an
uncertain create is resolved with the same key before cancellation, so it cannot become an orphaned
server schedule. Cancel and reschedule intents are also stored locally before networking. Workers
use `FOR UPDATE SKIP LOCKED`, expiring leases, stable
client message IDs, and the existing send idempotency ledger. Dispatch revalidates dialog access,
media ownership, replies, and mentions; a missing reply or stale mention is safely dropped while a
lost dialog becomes a permanent sanitized failure. Terminal rows erase message ciphertext and
release scheduled media references. Cancel and worker claim serialize on the schedule row: cancel
wins before claim, while a processing response means dispatch already owns the linearization point.

Link preview fetching never runs in the request transaction. The request stores only encrypted URLs
and a keyed lookup digest, then a worker resolves every DNS result, rejects private/loopback/link-local
and mapped addresses, pins the selected address, rechecks the connected peer, repeats the policy on
every redirect, permits only HTTP/HTTPS standard ports without credentials, and enforces byte,
time, redirect, image-pixel, and output limits. JavaScript is never executed. Metadata, URLs, and
normalized JPEG assets remain encrypted at rest. Asset downloads require current dialog membership.
Turning the preview switch off stops new jobs and payload sync without affecting text delivery.

Immediate rollback is account percentage zero (and empty allowlists), followed by clearing the
feature switch. To pause only new scheduled acceptance while preserving management, leave the
account rollout enabled and stop the worker: clients retain read/cancel access while create and
reschedule receive retryable `503`s. Do not remove the management route or schema while accepted
schedules remain; wait until `scheduled` and `processing` rows drain or retain the worker service.
The preview worker can be stopped after closing preview
acceptance; pending previews degrade to ordinary links. Folder rows and all local SQLCipher copies
remain for later re-enable.

Useful aggregate checks (never select encrypted payload columns into logs):

```sql
SELECT state, count(*), max(now() - deliver_at) AS max_lag
FROM scheduled_deliveries GROUP BY state;
SELECT worker_kind, max(last_seen_at) AS freshest
FROM worker_heartbeats GROUP BY worker_kind;
SELECT state, count(*) FROM link_preview_cache_entries GROUP BY state;
```


## Voice calls and TURN readiness

`voice_calls_v1` is advertised only when all of the following are configured:

- `TOJ_VOICE_CALLS_ENABLED=1`
- APNs credentials are configured, including the PushKit topic when it differs from `<TOJ_APNS_TOPIC>.voip`
- `TOJ_TURN_URLS` contains the comma-separated TURN UDP/TCP/TLS endpoints
- `TOJ_TURN_SHARED_SECRET` contains the coturn REST-auth shared secret
- `TOJ_TURN_READY=1` is set by deployment automation only after TURN allocation and relay health probes pass

The APNs provider settings are:

- `TOJ_APNS_TEAM_ID` and `TOJ_APNS_KEY_ID` from the Apple Developer account
- `TOJ_APNS_PRIVATE_KEY_BASE64`, containing the complete APNs `.p8` key encoded as base64
- `TOJ_APNS_TOPIC` (defaults to `com.toj.Toj`)
- `TOJ_APNS_VOIP_TOPIC` (defaults to `<TOJ_APNS_TOPIC>.voip`)

All of the first three values must be set together. The app identifier, provisioning profile, and
signed `aps-environment` entitlement must match the APNs topic and environment. A partial APNs
configuration fails server startup; no APNs configuration keeps calls unavailable.

For two TURN nodes, include all usable client transports in measured-preference order, for example:

```text
TOJ_TURN_URLS=turn:turn-a.example.com:3478?transport=udp,turn:turn-a.example.com:3478?transport=tcp,turns:turn-a.example.com:443?transport=tcp,turn:turn-b.example.com:3478?transport=udp,turn:turn-b.example.com:3478?transport=tcp,turns:turn-b.example.com:443?transport=tcp
TOJ_STUN_URLS=stun:turn-a.example.com:3478,stun:turn-b.example.com:3478
```

`TOJ_STUN_URLS` is optional, but configuring both nodes is recommended so ICE can discover direct
server-reflexive paths before falling back to relay. Restart the call-control process after changing
any APNs, TURN, STUN, or voice-readiness setting because capability readiness is calculated at
startup.

`video_calls_v1` additionally requires `TOJ_VIDEO_CALLS_ENABLED=1` and
`TOJ_TURN_VIDEO_READY=1`. The latter may be set only after both failure-independent TURN regions
pass sustained video-capacity tests with UDP, TCP, and TLS 443. Each allocation starts with
`max-bps=512000` bytes/second (about 4.096 Mbps aggregate); the client still caps one outbound
camera stream at 1.5 Mbps. Set `total-quota`, `bps-capacity`, and provider egress budgets from the
measured node limit, not an estimate.

Video eligibility is deterministic per account. `TOJ_VIDEO_CALLS_ALLOWLIST` is a comma-separated
list of internal account UUIDs and always takes precedence. `TOJ_VIDEO_CALLS_ROLLOUT_PERCENT` accepts
0 through 100 and defaults to zero. Use 5 for 48 hours, 25 for 72 hours, and then 100 only after all
release gates pass. Roll back by setting the percentage to zero and restarting: new video calls are
rejected, new audio calls select media profile 1, and in-flight profile-2 calls retain the immutable
selection policy stored when they were created.

The repository's [Video Calls v1 release report](../VIDEO_CALLS_RELEASE_REPORT.md) is the
authoritative checklist for provisioning, two-region TURN capacity, physical-device coverage, and
quantitative rollout gates. Do not set either video readiness flag based on simulator evidence alone.

Clear `TOJ_TURN_READY` or `TOJ_VOICE_CALLS_ENABLED` and restart the process to stop advertising and
accepting new calls. Clear either video readiness flag to stop advertising video globally, or set
the video rollout percentage to zero for a staged rollback. Existing call action, signaling, and
termination routes remain available so in-progress calls can finish cleanly.

For a first rollout, migrate PostgreSQL and deploy with both readiness flags off. Prove authenticated
allocations through each advertised UDP/TCP/TLS path from outside the TURN networks, set
`TOJ_TURN_READY=1` and `TOJ_VOICE_CALLS_ENABLED=1`, restart, then require
`GET /v1/capabilities` to contain `voice_calls_v1` before distributing the calling build.

Only active iOS devices with a complete encrypted PushKit registration are ring targets. TURN
credentials are scoped to the initiating or first-answer device, live for 60 minutes, and are
replaced when fewer than 15 minutes remain. Once key confirmation completes, each encrypted signal
(including the client's periodic encrypted control heartbeat) renews a 120-second active-call lease.
Clients heartbeat at roughly 30 seconds so a process crash, revoked device, or deleted account
cannot strand an active call while ordinary transient network loss still has recovery room.

Use `TOJ_CALL_NOTIFY_DATABASE_URL` for the dedicated PostgreSQL `LISTEN` connection when it differs
from `DATABASE_URL`. Call events are durable database rows and notifications are only low-latency
wake-ups, so clients recover a listener outage through `GET /v1/calls/active` and event catch-up.
Encrypted signaling is removed no later than ten minutes after termination; sanitized call metadata
is retained for 30 days. The terminal transition writes a `call_history_outbox` record atomically;
request and cleanup workers retry its idempotent service message until delivered, preserving the
original caller account identifier even when account deletion ended the call.
