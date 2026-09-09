# Private staging on Render + Supabase

This is a disposable iPhone-testing deployment of the existing Bun backend. It is not a
production launch or evidence of capacity. The iOS app talks to Bun over HTTPS/WSS; Supabase
hosts PostgreSQL only. Media chunks remain encrypted in PostgreSQL.

## Render selections

Use the reviewed `render.staging.yaml` Blueprint from the current branch after deployment approval.
The root directory is `server`, runtime is Node (which includes Bun), Bun is pinned to 1.3.11,
build is `bun install --frozen-lockfile`, start is `bun run staging`, and health check is `/ready`.
Use one Frankfurt web instance, plan `0.5c-512mb` (formerly Starter). As checked 2026-09-08,
the base compute cost is $7/month; the Hobby workspace and Supabase Free add no base charge.
Taxes and usage beyond included allowances can add charges. No separate worker, database,
disk, custom domain, or paid backup service is included. Confirm the dashboard total before creation.

Automatic deploys and previews are off. A first deployment still creates a public `onrender.com`
HTTPS/WSS endpoint. Get the owner's approval for that exposure and recurring charge before creating it.
Do not put the phone allowlist, keys, database URL, or deployment identities in GitHub.

Both productivity workers run inside the Bun process, along with existing maintenance/push/call
cleanup. Feature admission remains at its default off state. This keeps staging to one paid service;
production uses independently managed workers. SIGTERM/SIGINT drain workers and close the database,
with a 25-second application deadline inside Render's 30-second shutdown window.

## Secrets and connections

Enter the database URL and test-phone allowlist using Render's secret environment editor, never chat,
shell arguments, or repository files. The Blueprint asks Render to generate each encryption key and
metrics token independently when first created. Existing values are preserved on subsequent syncs.
No key value needs to pass through the agent or chat. The resulting settings are:

| Variable | Selection |
| --- | --- |
| `DATABASE_URL` | Exact Supabase Connect **Session pooler**, port 5432, PostgreSQL database; URL-encode the password and use `sslmode=verify-full` |
| `TOJ_DEV_OTP_ALLOWLIST` | Exact international test phone numbers, comma-separated; no wildcard |
| `TOJ_LOCAL_KEY_ENCRYPTION_KEY` | Render generates a random 32-byte wrapping key, base64 |
| `TOJ_MESSAGE_KEY` | Render generates a random 32-byte legacy-read compatibility key, base64 |
| `TOJ_HMAC_KEY` | Render generates a random 32-byte compatibility lookup key, base64 |
| `TOJ_PROTOCOL_ID_KEY` | Render generates a random 32-byte stable protocol-ID key, base64 |
| `TOJ_STAGING_BLIND_INDEX_KEY` | Render generates a random 32-byte versioned lookup key, base64 |
| `TOJ_METRICS_TOKEN` | Render generates an independent random bearer token |

Keep a recoverable private copy of all encryption keys separately from the database. Never regenerate
them on restart or redeploy. A lost wrapping key makes the encrypted staging history unreadable.
The default profile uses the database owner for staging only. Separate least-privilege runtime,
migration, and moderation roles remain a production requirement.

Use the real pooler hostname from Supabase's Connect panel; do not infer it from the region.
Supabase's direct Free endpoint is IPv6; session pooling is the persistent-client IPv4 option.
Do not use transaction pooling on port 6543: Bun prepared queries and the six long-lived PostgreSQL
notification listeners need session semantics. Staging limits the Bun query pool to five connections,
leaving room for those six listeners. `TOJ_CALL_NOTIFY_DATABASE_URL` can hold a separate
verified session URL but normally inherits `DATABASE_URL`. Verify listener reconnects, worker
heartbeats, and actual connection counts after deployment. Do not disable TLS certificate validation
to work around certificate errors. The staging package command loads the bundled public
`certs/supabase-root-2021.crt` using `NODE_EXTRA_CA_CERTS` **before** starting Bun. This extends
the trust store used by both Bun.SQL and all six pg notification clients, preserving public roots,
chain verification, and hostname verification. Setting this variable after process startup is too late.
For standalone migration/operator commands on this host, set the same environment variable first.

The certificate is fetched from Supabase's [official distribution](https://supabase-downloads.s3-ap-southeast-1.amazonaws.com/prod/ssl/prod-ca-2021.crt),
whose URL is defined in Supabase Studio's [source](https://github.com/supabase/supabase/blob/master/apps/studio/hooks/custom-content/custom-content.json).
Its SHA-256 fingerprint is `807025AD50D4ED219D2C9C7D299C004F824EB00CF7F65AFEF607D07B72E6CAFA`,
and it expires on 2031-04-26. It is a public CA certificate, not a secret or private key.
Review and replace it from the official source when Supabase rotates its CA; do not trust a
certificate merely because an unverified server sent it. The regression test checks provenance
fingerprint, expiry, and startup trust loading. Never set `NODE_TLS_REJECT_UNAUTHORIZED=0`.

`TOJ_TRUST_PROXY=0` is deliberate until the edge's forwarded-header handling has been verified.
It can group staging OTP rate limits by proxy IP; use only a few test accounts and respect cooldowns.
The template lowers media to 5 MiB per object and 20 MiB per account because the Free database is
small. Those are per-account limits, not a global database cap; monitor total storage.

## Encryption and login boundary

`NODE_ENV=staging`, `TOJ_CRYPTO_MODE=envelope`, and `TOJ_KEY_ENCRYPTION_PROVIDER=local` are explicit.
The staging entrypoint validates all keys before importing the backend, rejects deterministic defaults
and reused keys, and builds a versioned `staging-v1` blind-index keyring. New payloads use wrapped
per-account/service keys and AES-GCM. The wrapping key lives in the service environment: this lacks
managed KMS isolation, IAM, external access auditing, and outage guarantees. `/ready` truthfully labels
the wrapping provider `development`. The production ban on this provider is unchanged.

Unlike ordinary local development, staging enforces production's OTP return policy: an explicit
`TOJ_RETURN_OTP=1` plus exact test-number allowlist is required without SMS. A non-allowlisted number
fails closed before storing an OTP. Returned test OTPs are not proof of phone ownership; anyone who
knows an allowlisted number could use this testing login. Use synthetic test identities and disposable
content, never real private conversations. Real SMS and stronger private access are launch work.

## Fresh database bootstrap

The canonical implementation is `src/migrate.ts`, including every SQL phase, TypeScript backfill,
reconciliation, constraint validation/swap, and contract marker. Applying `schema.sql` alone is wrong.

When remote credentials are not available, `scripts/export-empty-bootstrap.ts` exports the result of
running that complete migration on an isolated, empty local PostgreSQL 17 database. It only accepts
a loopback source ending in `_bootstrap`, refuses application data and incomplete catalog state, and
exports schema plus the four migration/control tables. It does not copy users, ciphertext, or keys.

1. Create isolated local PostgreSQL databases for bootstrap, replay, and tests on a dedicated port.
2. Point `DATABASE_URL` at the bootstrap database and run `bun run migrate`.
3. Set `TOJ_BOOTSTRAP_SOURCE_URL` to that same local database; run
   `bun run scripts/export-empty-bootstrap.ts`, capturing stdout as a private local SQL artifact.
4. Replay it atomically into a second empty local database with the Supabase API role names present.
   Start the real backend there and require `/ready` HTTP 200.
5. Verify the exact target Supabase project and empty public catalog. Apply the generated artifact
   atomically with Supabase `apply_migration`. Its guard rejects a nonempty public schema.
6. Compare `scripts/verify-staging-catalog.sql` locally and remotely. Check constraints/index validity,
   progress markers, extensions, privileges, and both advisors. Keep Data API disabled.

The bootstrap revokes table, sequence, and function access from Supabase API roles and PUBLIC,
revokes future default grants for the migration owner, enables deny-by-default RLS on all tables,
and pins otherwise-unset function search paths. RLS without policies is intentional: all client
authorization goes through Bun. Do not add permissive policies to remove an informational notice.

The fresh database begins in the canonical `legacy` writer-fence state with no payloads.
After the approved staging deployment has its final keys, use the existing operator commands to
advance `envelope-canary` then `envelope`, under the same staging key environment. Never update
`crypto_write_state` manually. Require `/ready` and the key audit to agree after activation.

For later upgrades, run the **canonical migration** once using an owner connection in session/direct
mode before switching traffic. Never replay the empty bootstrap onto a populated database. Capture
migration output privately and report only sanitized status; shell failures may include connection
arguments. Recheck RLS/default privileges and function search paths after any new schema migration.
Render native runtimes include psql; verify its installed version before the first remote migration.

## Verification and remaining launch work

Run backend test files serially, matching `.github/workflows/ci.yml`, with both `DATABASE_URL` and
`TEST_DATABASE_URL` pointing to an isolated local test database. Some tests truncate application
tables or create/drop temporary fixture databases. Never run them against shared staging.

After approval and deployment, require HTTPS `/health` and `/ready`, inspect sanitized logs, verify
workers and persistent listeners, reject an outsider login, then exercise two test accounts: login,
authenticated WSS, send, sync/history, retry without duplicate delivery, and reconnect after restart.
Check database encryption labels without selecting message plaintext or secret material into logs.
Only then choose a staging hostname and update the iOS endpoint; the current Release URL stays intact
until that live evidence exists. Bun serves `/v1/*` directly, so confirm the client base-path convention.

Supabase Free does not supply the production backup/PITR posture. Keep staging content disposable.
For retained testing data, the existing `backup-postgres.sh` streams a custom pg_dump through age;
the private age identity stays off the app host. Use PostgreSQL 17-or-newer dump tooling against this
PostgreSQL 17 server, separate storage, and `restore-drill.sh` against an empty disposable target.
No scheduled remote backup is configured by this Blueprint.

Production remains blocked on managed KMS/provider integration and IAM, least-privilege roles,
SMS/APNs/TURN as appropriate, backups/PITR and restore drills, monitoring, operational response,
physical iPhone and Tajik-network testing, and measured load/failure capacity.

References: [Render compute](https://render.com/docs/compute-plans),
[pricing](https://render.com/pricing), [Blueprint fields](https://render.com/docs/blueprint-spec),
[WebSockets](https://render.com/docs/websocket),
[Supabase connection modes](https://supabase.com/docs/guides/database/connecting-to-postgres).
