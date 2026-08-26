-- Toj M3 cloud store schema. Idempotent (safe to re-run).
-- Reflects .context/m3-cloud-data-model-and-sync.md + the B1–B4/cleanup fixes in
-- .context/m3-review-and-corrections.md. TEXT+CHECK instead of enums (C5, no ALTER TYPE friction).

CREATE EXTENSION IF NOT EXISTS pgcrypto;
CREATE TABLE IF NOT EXISTS schema_migrations (
  name TEXT PRIMARY KEY,
  completed_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- ============ identity ============
CREATE TABLE IF NOT EXISTS accounts (
  id                    UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  phone_lookup_hash     BYTEA NOT NULL UNIQUE,       -- HMAC-SHA256(E.164, server pepper) — enumerable otherwise
  phone_e164_ciphertext BYTEA NOT NULL,              -- AEAD-encrypted phone (server can decrypt; never plaintext at rest)
  phone_nonce           BYTEA NOT NULL,
  phone_key_id          TEXT  NOT NULL,
  first_name            TEXT  NOT NULL DEFAULT '',
  last_name             TEXT  NOT NULL DEFAULT '',
  display_name          TEXT  NOT NULL DEFAULT '',
  bio                   TEXT  NOT NULL DEFAULT '',
  birthday              DATE,
  profile_color         INT   NOT NULL DEFAULT 0 CHECK (profile_color BETWEEN 0 AND 7),
  profile_photo_media_id UUID,
  profile_photo_revision BIGINT NOT NULL DEFAULT 0 CHECK (profile_photo_revision >= 0),
  status                TEXT  NOT NULL DEFAULT 'active'
                          CHECK (status IN ('active','limited','banned','deleted')),
  created_at            TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at            TIMESTAMPTZ NOT NULL DEFAULT now()
);
ALTER TABLE accounts ADD COLUMN IF NOT EXISTS first_name TEXT NOT NULL DEFAULT '';
ALTER TABLE accounts ADD COLUMN IF NOT EXISTS last_name TEXT NOT NULL DEFAULT '';
ALTER TABLE accounts ADD COLUMN IF NOT EXISTS bio TEXT NOT NULL DEFAULT '';
ALTER TABLE accounts ADD COLUMN IF NOT EXISTS birthday DATE;
ALTER TABLE accounts ADD COLUMN IF NOT EXISTS profile_color INT NOT NULL DEFAULT 0;
ALTER TABLE accounts ADD COLUMN IF NOT EXISTS username TEXT;
ALTER TABLE accounts ADD COLUMN IF NOT EXISTS profile_photo_media_id UUID;
ALTER TABLE accounts ADD COLUMN IF NOT EXISTS profile_photo_revision BIGINT NOT NULL DEFAULT 0;
ALTER TABLE accounts ADD COLUMN IF NOT EXISTS phone_lookup_key_id TEXT NOT NULL DEFAULT 'legacy-v1';
DO $$ BEGIN
  ALTER TABLE accounts ADD CONSTRAINT accounts_profile_color_check
    CHECK (profile_color BETWEEN 0 AND 7);
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;
UPDATE accounts
SET first_name = display_name
WHERE first_name = '' AND last_name = '' AND display_name <> '';

-- ============ provider-neutral envelope encryption ============
-- KMS/HSM providers wrap small random data-encryption keys (DEKs); message/media payloads never
-- cross the provider boundary. Account rows are retained as deleted tombstones, so these foreign
-- keys also remain available for ciphertext that other conversation members still retain.
CREATE TABLE IF NOT EXISTS account_data_keys (
  id                     UUID PRIMARY KEY,
  account_id             UUID NOT NULL REFERENCES accounts(id),
  version                INT NOT NULL CHECK (version > 0),
  state                  TEXT NOT NULL CHECK (state IN ('active','retiring','retired')),
  provider_id            TEXT NOT NULL,
  provider_key_reference TEXT NOT NULL,
  wrapped_key            BYTEA NOT NULL,
  created_at             TIMESTAMPTZ NOT NULL DEFAULT now(),
  activated_at           TIMESTAMPTZ NOT NULL DEFAULT now(),
  retiring_at            TIMESTAMPTZ,
  revocation_started_at  TIMESTAMPTZ,
  retired_at             TIMESTAMPTZ,
  UNIQUE (account_id, version)
);
CREATE UNIQUE INDEX IF NOT EXISTS account_data_keys_one_active_idx
  ON account_data_keys(account_id) WHERE state = 'active';
CREATE INDEX IF NOT EXISTS account_data_keys_retirement_idx
  ON account_data_keys(retiring_at) WHERE state = 'retiring';

CREATE TABLE IF NOT EXISTS service_data_keys (
  id                     UUID PRIMARY KEY,
  service_name           TEXT NOT NULL,
  version                INT NOT NULL CHECK (version > 0),
  state                  TEXT NOT NULL CHECK (state IN ('active','retiring','retired')),
  provider_id            TEXT NOT NULL,
  provider_key_reference TEXT NOT NULL,
  wrapped_key            BYTEA NOT NULL,
  created_at             TIMESTAMPTZ NOT NULL DEFAULT now(),
  activated_at           TIMESTAMPTZ NOT NULL DEFAULT now(),
  retiring_at            TIMESTAMPTZ,
  revocation_started_at  TIMESTAMPTZ,
  retired_at             TIMESTAMPTZ,
  UNIQUE (service_name, version)
);
CREATE UNIQUE INDEX IF NOT EXISTS service_data_keys_one_active_idx
  ON service_data_keys(service_name) WHERE state = 'active';
CREATE INDEX IF NOT EXISTS service_data_keys_retirement_idx
  ON service_data_keys(retiring_at) WHERE state = 'retiring';

-- Existing installations gain a durable two-phase revocation marker. The first retirement pass
-- blocks new unwraps; the final pass erases wrapped material only after every bounded cache entry
-- created before that marker must have expired and zeroized itself.
ALTER TABLE account_data_keys
  ADD COLUMN IF NOT EXISTS revocation_started_at TIMESTAMPTZ;
ALTER TABLE service_data_keys
  ADD COLUMN IF NOT EXISTS revocation_started_at TIMESTAMPTZ;

CREATE TABLE IF NOT EXISTS crypto_migration_cursors (
  domain       TEXT PRIMARY KEY,
  cursor       JSONB NOT NULL DEFAULT '{}'::jsonb,
  state        TEXT NOT NULL DEFAULT 'pending' CHECK (state IN ('pending','running','complete')),
  rows_migrated BIGINT NOT NULL DEFAULT 0 CHECK (rows_migrated >= 0),
  updated_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- The database is the final writer fence. Once envelope mode is activated, triggers installed
-- after every ciphertext domain exists reject legacy writes even from a stale application node.
CREATE TABLE IF NOT EXISTS crypto_write_state (
  singleton  BOOLEAN PRIMARY KEY DEFAULT TRUE CHECK (singleton),
  write_mode TEXT NOT NULL CHECK (write_mode IN ('legacy','envelope-canary','envelope')),
  epoch      BIGINT NOT NULL CHECK (epoch > 0),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
INSERT INTO crypto_write_state(singleton, write_mode, epoch)
VALUES (TRUE, 'legacy', 1)
ON CONFLICT (singleton) DO NOTHING;

-- The sync cursor per account. NO `seq` (I1: redundant with pts). pruned_through_pts (B3) is the
-- floor below which events are gone -> get_difference must answer difference_too_long.
CREATE TABLE IF NOT EXISTS account_sync_states (
  account_id         UUID PRIMARY KEY REFERENCES accounts(id) ON DELETE CASCADE,
  pts                BIGINT NOT NULL DEFAULT 0,       -- last assigned event number
  pruned_through_pts BIGINT NOT NULL DEFAULT 0,       -- oldest retained pts - 1
  updated_at         TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS devices (
  id                    UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  account_id            UUID NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  platform              TEXT NOT NULL CHECK (platform IN ('ios','android','web','desktop')),
  device_name           TEXT,
  auth_token_hash       BYTEA NOT NULL UNIQUE,        -- SHA-256 of the bearer token
  push_token_hash       BYTEA,
  push_token_ciphertext BYTEA,
  push_token_nonce      BYTEA,
  push_token_key_id     TEXT,
  push_environment      TEXT CHECK (push_environment IN ('sandbox','production')),
  push_updated_at       TIMESTAMPTZ,
  supported_group_call_versions INT[] NOT NULL DEFAULT ARRAY[]::INT[],
  group_call_view_version INT NOT NULL DEFAULT 0,
  supports_group_screen_share BOOLEAN NOT NULL DEFAULT FALSE,
  last_seen_at          TIMESTAMPTZ,
  revoked_at            TIMESTAMPTZ,
  created_at            TIMESTAMPTZ NOT NULL DEFAULT now()
);
ALTER TABLE devices ADD COLUMN IF NOT EXISTS auth_scheme TEXT NOT NULL DEFAULT 'legacy';
DO $$ BEGIN
  ALTER TABLE devices ADD CONSTRAINT devices_auth_scheme_check
    CHECK (auth_scheme IN ('legacy','v2')) NOT VALID;
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;
-- Existing M3 deployments already have devices.push_token_ciphertext, so M4 adds the remaining
-- token metadata with idempotent ALTERs. The token itself is never stored as plaintext.
ALTER TABLE devices ADD COLUMN IF NOT EXISTS push_token_hash BYTEA;
ALTER TABLE devices ADD COLUMN IF NOT EXISTS auth_token_key_id TEXT NOT NULL DEFAULT 'legacy-v1';
ALTER TABLE devices ADD COLUMN IF NOT EXISTS push_token_hash_key_id TEXT DEFAULT 'legacy-v1';
ALTER TABLE devices ALTER COLUMN push_token_hash_key_id SET DEFAULT 'legacy-v1';
ALTER TABLE devices ADD COLUMN IF NOT EXISTS push_token_nonce BYTEA;
ALTER TABLE devices ADD COLUMN IF NOT EXISTS push_token_key_id TEXT;
ALTER TABLE devices ADD COLUMN IF NOT EXISTS push_environment TEXT;
ALTER TABLE devices ADD COLUMN IF NOT EXISTS push_updated_at TIMESTAMPTZ;
-- PushKit uses a different APNs token and topic from ordinary notifications. Keep the
-- registrations separate so an Unregistered response for one topic cannot erase the other.
ALTER TABLE devices ADD COLUMN IF NOT EXISTS voip_push_token_hash BYTEA;
ALTER TABLE devices ADD COLUMN IF NOT EXISTS voip_push_token_hash_key_id TEXT DEFAULT 'legacy-v1';
ALTER TABLE devices ALTER COLUMN voip_push_token_hash_key_id SET DEFAULT 'legacy-v1';
ALTER TABLE devices ADD COLUMN IF NOT EXISTS voip_push_token_ciphertext BYTEA;
ALTER TABLE devices ADD COLUMN IF NOT EXISTS voip_push_token_nonce BYTEA;
ALTER TABLE devices ADD COLUMN IF NOT EXISTS voip_push_token_key_id TEXT;
ALTER TABLE devices ADD COLUMN IF NOT EXISTS voip_push_environment TEXT;
ALTER TABLE devices ADD COLUMN IF NOT EXISTS voip_push_updated_at TIMESTAMPTZ;
-- Call capabilities are device-scoped. Legacy registrations intentionally reset these
-- values to profile 1 so a stale profile-2 advertisement cannot survive an app downgrade.
ALTER TABLE devices ADD COLUMN IF NOT EXISTS supported_call_protocol_versions INT[] NOT NULL DEFAULT ARRAY[1]::INT[];
ALTER TABLE devices ADD COLUMN IF NOT EXISTS supported_call_media_profile_versions INT[] NOT NULL DEFAULT ARRAY[1]::INT[];
ALTER TABLE devices ADD COLUMN IF NOT EXISTS call_view_version INT NOT NULL DEFAULT 1;
-- Group-media columns for existing deployments are expanded separately before this contract is
-- run. Keeping the hot-table ALTERs out of the large schema transaction bounds lock duration.
DO $$ BEGIN
  ALTER TABLE devices ADD CONSTRAINT devices_push_environment_check
    CHECK (push_environment IN ('sandbox','production'));
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;
DO $$ BEGIN
  ALTER TABLE devices ADD CONSTRAINT devices_voip_push_environment_check
    CHECK (voip_push_environment IN ('sandbox','production')) NOT VALID;
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;
DO $$ BEGIN
  ALTER TABLE devices ADD CONSTRAINT devices_push_hash_key_check
    CHECK (push_token_hash IS NULL OR push_token_hash_key_id IS NOT NULL) NOT VALID;
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;
DO $$ BEGIN
  ALTER TABLE devices ADD CONSTRAINT devices_voip_push_hash_key_check
    CHECK (voip_push_token_hash IS NULL OR voip_push_token_hash_key_id IS NOT NULL) NOT VALID;
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;
CREATE INDEX IF NOT EXISTS devices_account_active_idx ON devices(account_id) WHERE revoked_at IS NULL;
CREATE UNIQUE INDEX IF NOT EXISTS devices_push_token_active_idx
  ON devices(push_environment, push_token_hash)
  WHERE push_token_hash IS NOT NULL AND revoked_at IS NULL;
-- The VoIP token index is built concurrently by schema-concurrent.sql because devices may already
-- be large in production.

CREATE TABLE IF NOT EXISTS otp_challenges (
  id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  phone_lookup_hash BYTEA NOT NULL,
  code_hash         BYTEA NOT NULL,                   -- HMAC of the 6-digit code
  code_salt         BYTEA,
  network_hash      BYTEA,
  purpose           TEXT NOT NULL DEFAULT 'login'
                      CHECK (purpose IN ('login','account_deletion','security_change')),
  attempts          INT NOT NULL DEFAULT 0,
  expires_at        TIMESTAMPTZ NOT NULL,
  consumed_at       TIMESTAMPTZ,
  created_at        TIMESTAMPTZ NOT NULL DEFAULT now()
);
ALTER TABLE otp_challenges ADD COLUMN IF NOT EXISTS code_salt BYTEA;
ALTER TABLE otp_challenges ADD COLUMN IF NOT EXISTS phone_lookup_key_id TEXT NOT NULL DEFAULT 'legacy-v1';
ALTER TABLE otp_challenges ADD COLUMN IF NOT EXISTS code_key_id TEXT NOT NULL DEFAULT 'legacy-v1';
ALTER TABLE otp_challenges ADD COLUMN IF NOT EXISTS network_key_id TEXT DEFAULT 'legacy-v1';
ALTER TABLE otp_challenges ALTER COLUMN network_key_id SET DEFAULT 'legacy-v1';
ALTER TABLE otp_challenges ADD COLUMN IF NOT EXISTS network_hash BYTEA;
ALTER TABLE otp_challenges ADD COLUMN IF NOT EXISTS purpose TEXT NOT NULL DEFAULT 'login';
ALTER TABLE otp_challenges DROP CONSTRAINT IF EXISTS otp_challenges_purpose_check;
DO $$ BEGIN
  ALTER TABLE otp_challenges ADD CONSTRAINT otp_challenges_purpose_check
    CHECK (purpose IN ('login','account_deletion','security_change'));
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;
DO $$ BEGIN
  ALTER TABLE otp_challenges ADD CONSTRAINT otp_challenges_network_hash_key_check
    CHECK (network_hash IS NULL OR network_key_id IS NOT NULL) NOT VALID;
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;
CREATE INDEX IF NOT EXISTS otp_active_idx ON otp_challenges(phone_lookup_hash, expires_at) WHERE consumed_at IS NULL;
CREATE INDEX IF NOT EXISTS otp_phone_requests_idx ON otp_challenges(phone_lookup_hash, created_at DESC);
CREATE INDEX IF NOT EXISTS otp_network_requests_idx ON otp_challenges(network_hash, created_at DESC)
  WHERE network_hash IS NOT NULL;

-- Auth protocol v2 keeps short-lived access credentials separate from the rotating device grant.
-- Only HMACs are retained. A bounded encrypted receipt makes a committed rotation safe to retry
-- after a client crash without turning an old refresh token into a second valid grant.
CREATE TABLE IF NOT EXISTS device_sessions (
  id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  device_id           UUID NOT NULL UNIQUE REFERENCES devices(id) ON DELETE CASCADE,
  refresh_token_hash  BYTEA NOT NULL UNIQUE,
  refresh_token_hash_key_id TEXT NOT NULL DEFAULT 'legacy-v1',
  rotation_generation BIGINT NOT NULL DEFAULT 0,
  last_activity_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  absolute_expires_at TIMESTAMPTZ NOT NULL,
  revoked_at          TIMESTAMPTZ,
  revocation_reason   TEXT,
  created_at          TIMESTAMPTZ NOT NULL DEFAULT now()
);
ALTER TABLE device_sessions ADD COLUMN IF NOT EXISTS refresh_token_hash_key_id
  TEXT NOT NULL DEFAULT 'legacy-v1';
CREATE INDEX IF NOT EXISTS device_sessions_active_idx
  ON device_sessions(last_activity_at, absolute_expires_at) WHERE revoked_at IS NULL;

CREATE TABLE IF NOT EXISTS session_access_tokens (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  token_digest BYTEA NOT NULL UNIQUE,
  token_digest_key_id TEXT NOT NULL DEFAULT 'legacy-v1',
  session_id UUID NOT NULL REFERENCES device_sessions(id) ON DELETE CASCADE,
  expires_at TIMESTAMPTZ NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
ALTER TABLE session_access_tokens ADD COLUMN IF NOT EXISTS token_digest_key_id
  TEXT NOT NULL DEFAULT 'legacy-v1';
CREATE INDEX IF NOT EXISTS session_access_tokens_session_idx
  ON session_access_tokens(session_id, expires_at DESC);

CREATE TABLE IF NOT EXISTS session_refresh_token_history (
  token_digest BYTEA PRIMARY KEY,
  token_digest_key_id TEXT NOT NULL DEFAULT 'legacy-v1',
  session_id UUID NOT NULL REFERENCES device_sessions(id) ON DELETE CASCADE,
  used_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
ALTER TABLE session_refresh_token_history ADD COLUMN IF NOT EXISTS token_digest_key_id
  TEXT NOT NULL DEFAULT 'legacy-v1';

CREATE TABLE IF NOT EXISTS session_rotation_receipts (
  session_id UUID NOT NULL REFERENCES device_sessions(id) ON DELETE CASCADE,
  rotation_id UUID NOT NULL,
  request_token_digest BYTEA NOT NULL,
  request_token_digest_key_id TEXT NOT NULL DEFAULT 'legacy-v1',
  response_ciphertext BYTEA NOT NULL,
  response_nonce BYTEA NOT NULL,
  response_key_id TEXT NOT NULL,
  response_generation BIGINT NOT NULL
    CONSTRAINT session_rotation_receipts_generation_check CHECK (response_generation > 0),
  expires_at TIMESTAMPTZ NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (session_id, rotation_id)
);
ALTER TABLE session_rotation_receipts ADD COLUMN IF NOT EXISTS request_token_digest_key_id
  TEXT NOT NULL DEFAULT 'legacy-v1';
ALTER TABLE session_rotation_receipts
  ADD COLUMN IF NOT EXISTS response_generation BIGINT;
-- Rotation receipts live for only five minutes. Receipts written by the pre-generation binary
-- cannot safely be replayed after a newer refresh, so discard them instead of guessing a value.
DELETE FROM session_rotation_receipts WHERE response_generation IS NULL;
ALTER TABLE session_rotation_receipts
  ALTER COLUMN response_generation SET NOT NULL;
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conrelid = 'session_rotation_receipts'::regclass
      AND conname = 'session_rotation_receipts_generation_check'
  ) THEN
    ALTER TABLE session_rotation_receipts
      ADD CONSTRAINT session_rotation_receipts_generation_check
      CHECK (response_generation > 0) NOT VALID;
  END IF;
END $$;
ALTER TABLE session_rotation_receipts
  VALIDATE CONSTRAINT session_rotation_receipts_generation_check;
CREATE INDEX IF NOT EXISTS session_rotation_receipts_expiry_idx
  ON session_rotation_receipts(expires_at);
INSERT INTO schema_migrations(name) VALUES ('session-rotation-generation-v1')
ON CONFLICT (name) DO NOTHING;

CREATE TABLE IF NOT EXISTS account_two_factor (
  account_id UUID PRIMARY KEY REFERENCES accounts(id) ON DELETE CASCADE,
  password_hash TEXT NOT NULL,
  enabled_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS two_factor_recovery_codes (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  account_id UUID NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  code_hash BYTEA NOT NULL,
  code_key_id TEXT NOT NULL DEFAULT 'legacy-v1',
  consumed_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (account_id, code_hash)
);
ALTER TABLE two_factor_recovery_codes ADD COLUMN IF NOT EXISTS code_key_id
  TEXT NOT NULL DEFAULT 'legacy-v1';
CREATE INDEX IF NOT EXISTS two_factor_recovery_active_idx
  ON two_factor_recovery_codes(account_id) WHERE consumed_at IS NULL;

CREATE TABLE IF NOT EXISTS two_factor_login_challenges (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  account_id UUID NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  platform TEXT NOT NULL CHECK (platform IN ('ios','android','web','desktop')),
  device_name TEXT,
  display_name TEXT,
  attempts INT NOT NULL DEFAULT 0,
  expires_at TIMESTAMPTZ NOT NULL,
  consumed_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS two_factor_login_active_idx
  ON two_factor_login_challenges(account_id, expires_at) WHERE consumed_at IS NULL;

CREATE TABLE IF NOT EXISTS two_factor_attempt_budgets (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  account_id UUID NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  network_hash BYTEA,
  network_key_id TEXT DEFAULT 'legacy-v1',
  accepted_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
ALTER TABLE two_factor_attempt_budgets ADD COLUMN IF NOT EXISTS network_key_id
  TEXT DEFAULT 'legacy-v1';
DO $$ BEGIN
  ALTER TABLE two_factor_attempt_budgets ADD CONSTRAINT two_factor_attempt_network_key_check
    CHECK (network_hash IS NULL OR network_key_id IS NOT NULL) NOT VALID;
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;
CREATE INDEX IF NOT EXISTS two_factor_attempt_account_idx
  ON two_factor_attempt_budgets(account_id, accepted_at DESC);
CREATE INDEX IF NOT EXISTS two_factor_attempt_network_idx
  ON two_factor_attempt_budgets(network_hash, accepted_at DESC) WHERE network_hash IS NOT NULL;

CREATE TABLE IF NOT EXISTS security_step_up_tickets (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  account_id UUID NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  token_hash BYTEA NOT NULL UNIQUE,
  token_key_id TEXT NOT NULL DEFAULT 'legacy-v1',
  attempts INT NOT NULL DEFAULT 0,
  expires_at TIMESTAMPTZ NOT NULL,
  consumed_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
ALTER TABLE security_step_up_tickets ADD COLUMN IF NOT EXISTS attempts INT NOT NULL DEFAULT 0;
ALTER TABLE security_step_up_tickets ADD COLUMN IF NOT EXISTS token_key_id
  TEXT NOT NULL DEFAULT 'legacy-v1';

-- Persisted, per-account discovery budget. This makes phone enumeration expensive even across
-- server restarts and multiple app processes; repeated lookups of the same contact are idempotent
-- within the window so normal retries do not consume the budget.
CREATE TABLE IF NOT EXISTS contact_lookup_attempts (
  id                   UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  requester_account_id UUID NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  target_phone_hash    BYTEA NOT NULL,
  created_at           TIMESTAMPTZ NOT NULL DEFAULT now()
);
ALTER TABLE contact_lookup_attempts DROP COLUMN IF EXISTS found;
ALTER TABLE contact_lookup_attempts ADD COLUMN IF NOT EXISTS target_phone_key_id TEXT NOT NULL DEFAULT 'legacy-v1';
CREATE INDEX IF NOT EXISTS contact_lookup_attempts_requester_idx
  ON contact_lookup_attempts(requester_account_id, created_at DESC);

-- ============ conversations ============
CREATE TABLE IF NOT EXISTS dialogs (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  type        TEXT NOT NULL CHECK (type IN ('direct','group','saved')),
  title       TEXT,
  created_by  UUID REFERENCES accounts(id),
  last_msg_id BIGINT NOT NULL DEFAULT 0,              -- per-dialog message counter
  revision    BIGINT NOT NULL DEFAULT 0,
  closed_at   TIMESTAMPTZ,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);
ALTER TABLE dialogs ADD COLUMN IF NOT EXISTS revision BIGINT NOT NULL DEFAULT 0;
ALTER TABLE dialogs ADD COLUMN IF NOT EXISTS closed_at TIMESTAMPTZ;
ALTER TABLE dialogs ADD COLUMN IF NOT EXISTS members_can_send BOOLEAN NOT NULL DEFAULT TRUE;
ALTER TABLE dialogs ADD COLUMN IF NOT EXISTS members_can_add_members BOOLEAN NOT NULL DEFAULT FALSE;
ALTER TABLE dialogs ADD COLUMN IF NOT EXISTS members_can_edit_info BOOLEAN NOT NULL DEFAULT FALSE;
-- Existing deployments expand/validate/short-swap the dialog constraints after this transaction;
-- see schema-dialogs-expand.sql and schema-dialogs-swap.sql.

-- One direct dialog per unordered pair (idempotent 1:1 creation).
CREATE TABLE IF NOT EXISTS direct_dialog_pairs (
  dialog_id    UUID PRIMARY KEY REFERENCES dialogs(id) ON DELETE CASCADE,
  account_low  UUID NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  account_high UUID NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  CHECK (account_low < account_high),
  UNIQUE (account_low, account_high)
);

CREATE TABLE IF NOT EXISTS dialog_members (
  dialog_id        UUID NOT NULL REFERENCES dialogs(id) ON DELETE CASCADE,
  account_id       UUID NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  role             TEXT NOT NULL DEFAULT 'member' CHECK (role IN ('owner','admin','member')),
  last_read_msg_id BIGINT NOT NULL DEFAULT 0,
  invited_by       UUID REFERENCES accounts(id),
  notification_mode TEXT NOT NULL DEFAULT 'all'
                       CHECK (notification_mode IN ('all','muted')),
  joined_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
  left_at          TIMESTAMPTZ,
  PRIMARY KEY (dialog_id, account_id)
);
ALTER TABLE dialog_members ADD COLUMN IF NOT EXISTS invited_by UUID REFERENCES accounts(id);
ALTER TABLE dialog_members ADD COLUMN IF NOT EXISTS notification_mode TEXT NOT NULL DEFAULT 'all';
DO $$ BEGIN
  ALTER TABLE dialog_members ADD CONSTRAINT dialog_members_notification_mode_check
    CHECK (notification_mode IN ('all','muted'));
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;
CREATE INDEX IF NOT EXISTS dialog_members_account_active_idx ON dialog_members(account_id) WHERE left_at IS NULL;

-- ============ encrypted resumable media ============
-- Private-beta storage is provider-free: each independently resumable chunk is AEAD encrypted
-- before PostgreSQL persists it. The API is deliberately storage-adapter shaped so object storage
-- can replace this table later without changing clients or message history.
CREATE TABLE IF NOT EXISTS media_objects (
  id                    UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  owner_account_id      UUID NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  kind                  TEXT NOT NULL CHECK (kind IN ('photo','video','file','voice')),
  content_type          TEXT NOT NULL,
  file_name             TEXT,                           -- legacy only; new writes keep this NULL
  file_name_key_id      TEXT,
  file_name_nonce       BYTEA,
  file_name_ciphertext  BYTEA,
  byte_size             BIGINT NOT NULL CHECK (byte_size > 0),
  expected_sha256       BYTEA NOT NULL CHECK (octet_length(expected_sha256) = 32), -- HMAC(raw SHA-256)
  uploaded_bytes        BIGINT NOT NULL DEFAULT 0 CHECK (uploaded_bytes >= 0),
  upload_protocol       TEXT NOT NULL DEFAULT 'offset_v1'
                          CHECK (upload_protocol IN ('offset_v1','parts_v2')),
  part_size             INT CHECK (part_size IS NULL OR part_size > 0),
  total_parts           INT CHECK (total_parts IS NULL OR total_parts > 0),
  duration_ms           BIGINT CHECK (duration_ms IS NULL OR duration_ms >= 0),
  width                 INT CHECK (width IS NULL OR width > 0),
  height                INT CHECK (height IS NULL OR height > 0),
  status                TEXT NOT NULL DEFAULT 'uploading'
                          CHECK (status IN ('uploading','ready','rejected','deleted')),
  purpose               TEXT NOT NULL DEFAULT 'message'
                          CHECK (purpose IN ('message','group_photo','profile_photo')),
  thumbnail_key_id      TEXT,
  thumbnail_nonce       BYTEA,
  thumbnail_ciphertext  BYTEA,
  thumbnail_byte_size   INT CHECK (thumbnail_byte_size IS NULL OR thumbnail_byte_size > 0),
  thumbnail_content_type TEXT,
  created_at            TIMESTAMPTZ NOT NULL DEFAULT now(),
  completed_at          TIMESTAMPTZ,
  expires_at            TIMESTAMPTZ NOT NULL DEFAULT now() + interval '24 hours',
  last_accessed_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  CHECK (uploaded_bytes <= byte_size),
  CHECK ((thumbnail_ciphertext IS NULL) = (thumbnail_nonce IS NULL)),
  CHECK ((file_name_ciphertext IS NULL) = (file_name_nonce IS NULL))
);
ALTER TABLE media_objects ADD COLUMN IF NOT EXISTS file_name_key_id TEXT;
ALTER TABLE media_objects ADD COLUMN IF NOT EXISTS file_name_nonce BYTEA;
ALTER TABLE media_objects ADD COLUMN IF NOT EXISTS file_name_ciphertext BYTEA;
ALTER TABLE media_objects ADD COLUMN IF NOT EXISTS upload_protocol TEXT NOT NULL DEFAULT 'offset_v1';
ALTER TABLE media_objects ADD COLUMN IF NOT EXISTS part_size INT;
ALTER TABLE media_objects ADD COLUMN IF NOT EXISTS total_parts INT;
ALTER TABLE media_objects ADD COLUMN IF NOT EXISTS purpose TEXT NOT NULL DEFAULT 'message';
ALTER TABLE media_objects ADD COLUMN IF NOT EXISTS expected_digest_key_id TEXT NOT NULL DEFAULT 'legacy-v1';
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM schema_migrations WHERE name = 'media-constraints-v2')
     AND NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'media_objects_upload_protocol_check_v2') THEN
    ALTER TABLE media_objects ADD CONSTRAINT media_objects_upload_protocol_check_v2 CHECK (
      (upload_protocol = 'offset_v1' AND part_size IS NULL AND total_parts IS NULL) OR
      (upload_protocol = 'parts_v2' AND part_size > 0 AND total_parts > 0)
    ) NOT VALID;
    ALTER TABLE media_objects ADD CONSTRAINT media_objects_status_check_v2
      CHECK (status IN ('uploading','ready','rejected','deleted')) NOT VALID;
    ALTER TABLE media_objects ADD CONSTRAINT media_objects_purpose_check_v2
      CHECK (purpose IN ('message','group_photo')) NOT VALID;
  END IF;
END $$;
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM schema_migrations WHERE name = 'media-purpose-profile-photo-v1')
     AND NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'media_objects_purpose_check_profile_photo') THEN
    ALTER TABLE media_objects ADD CONSTRAINT media_objects_purpose_check_profile_photo
      CHECK (purpose IN ('message','group_photo','profile_photo')) NOT VALID;
  END IF;
END $$;
CREATE INDEX IF NOT EXISTS media_objects_owner_quota_idx
  ON media_objects(owner_account_id, status, created_at);

-- Added after media_objects exists so old installations can acquire the FK without reordering the
-- original table declarations. SET NULL is a safety net for the orphan reaper.
ALTER TABLE dialogs ADD COLUMN IF NOT EXISTS photo_media_id UUID;
DO $$ BEGIN
  ALTER TABLE dialogs ADD CONSTRAINT dialogs_photo_media_id_fkey
    FOREIGN KEY (photo_media_id) REFERENCES media_objects(id) ON DELETE SET NULL;
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;
DO $$ BEGIN
  ALTER TABLE accounts ADD CONSTRAINT accounts_profile_photo_media_id_fkey
    FOREIGN KEY (profile_photo_media_id) REFERENCES media_objects(id) ON DELETE SET NULL NOT VALID;
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;
DO $$ BEGIN
  ALTER TABLE accounts ADD CONSTRAINT accounts_profile_photo_revision_check
    CHECK (profile_photo_revision >= 0) NOT VALID;
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

-- Profile-photo mutation receipts are retained until account deletion. A device can retry after
-- an arbitrarily long offline period or a lost HTTP response without replaying an old avatar.
CREATE TABLE IF NOT EXISTS profile_photo_mutations (
  account_id          UUID NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  client_mutation_id  UUID NOT NULL,
  payload_fingerprint BYTEA NOT NULL CHECK (octet_length(payload_fingerprint) = 32),
  media_id            UUID REFERENCES media_objects(id) ON DELETE SET NULL,
  base_revision       BIGINT NOT NULL CHECK (base_revision >= 0),
  status              TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','completed')),
  result_revision     BIGINT,
  created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
  completed_at        TIMESTAMPTZ,
  PRIMARY KEY (account_id, client_mutation_id),
  CHECK (
    (status = 'pending' AND result_revision IS NULL AND completed_at IS NULL)
    OR (status = 'completed' AND result_revision IS NOT NULL AND completed_at IS NOT NULL)
  )
);
CREATE INDEX IF NOT EXISTS profile_photo_mutations_account_created_idx
  ON profile_photo_mutations(account_id, created_at DESC);

-- Exact replays do not consume this budget. New mutation IDs are bounded per UTC day so a
-- compromised authenticated client cannot turn durable idempotency receipts into unbounded
-- high-rate storage growth.
CREATE TABLE IF NOT EXISTS profile_photo_action_budgets (
  account_id      UUID NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  bucket_started  TIMESTAMPTZ NOT NULL,
  mutation_count  INT NOT NULL DEFAULT 0 CHECK (mutation_count >= 0),
  updated_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (account_id, bucket_started)
);
CREATE INDEX IF NOT EXISTS profile_photo_action_budgets_retention_idx
  ON profile_photo_action_budgets(bucket_started, account_id);

-- Kept separately from media_objects so create/cancel loops cannot evade per-account rate limits.
CREATE TABLE IF NOT EXISTS media_upload_attempts (
  id         BIGSERIAL PRIMARY KEY,
  account_id UUID NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS media_upload_attempts_account_created_idx
  ON media_upload_attempts(account_id, created_at DESC);

CREATE TABLE IF NOT EXISTS media_chunks (
  media_id       UUID NOT NULL REFERENCES media_objects(id) ON DELETE CASCADE,
  chunk_offset   BIGINT NOT NULL CHECK (chunk_offset >= 0),
  plain_size     INT NOT NULL CHECK (plain_size > 0),
  plain_sha256   BYTEA NOT NULL CHECK (octet_length(plain_sha256) = 32),
  key_id         TEXT NOT NULL,
  nonce          BYTEA NOT NULL,
  ciphertext     BYTEA NOT NULL,
  created_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (media_id, chunk_offset)
);
ALTER TABLE media_chunks ADD COLUMN IF NOT EXISTS plain_digest_key_id TEXT NOT NULL DEFAULT 'legacy-v1';

-- ============ messages (encrypted-at-rest) ============
CREATE TABLE IF NOT EXISTS messages (
  dialog_id         UUID NOT NULL REFERENCES dialogs(id) ON DELETE CASCADE,
  msg_id            BIGINT NOT NULL,                  -- per-dialog monotonic (ordering key)
  sender_account_id UUID NOT NULL REFERENCES accounts(id),
  sender_device_id  UUID REFERENCES devices(id),
  client_msg_id     UUID NOT NULL,
  kind              TEXT NOT NULL DEFAULT 'text' CHECK (kind IN ('text','photo','video','file','voice','service')),
  body_key_id       TEXT  NOT NULL,
  body_nonce        BYTEA NOT NULL,
  body_ciphertext   BYTEA NOT NULL,                   -- AEAD; AAD binds dialog_id‖msg_id‖sender (S1)
  reply_to_msg_id   BIGINT,
  forwarded_from_account_id UUID REFERENCES accounts(id),
  forwarded_from_dialog_id UUID,
  forwarded_from_msg_id BIGINT,
  is_forwarded       BOOLEAN NOT NULL DEFAULT FALSE,
  media_id          UUID REFERENCES media_objects(id),
  media_group_id    UUID,
  media_group_index SMALLINT,
  media_group_count SMALLINT,
  send_fingerprint  BYTEA,
  send_fingerprint_key_id TEXT NOT NULL DEFAULT 'legacy-v1',
  service_type      TEXT,
  service_data      JSONB,
  edit_version      INT NOT NULL DEFAULT 0,
  state             TEXT NOT NULL DEFAULT 'visible' CHECK (state IN ('visible','deleted_for_all')),
  server_ts         TIMESTAMPTZ NOT NULL DEFAULT now(),
  edited_at         TIMESTAMPTZ,
  deleted_at        TIMESTAMPTZ,
  PRIMARY KEY (dialog_id, msg_id),
  UNIQUE (sender_account_id, client_msg_id)           -- belt-and-suspenders vs send_requests
);
ALTER TABLE messages ADD COLUMN IF NOT EXISTS forwarded_from_account_id UUID REFERENCES accounts(id);
ALTER TABLE messages ADD COLUMN IF NOT EXISTS forwarded_from_dialog_id UUID;
ALTER TABLE messages ADD COLUMN IF NOT EXISTS forwarded_from_msg_id BIGINT;
-- Existing deployments add/backfill/validate is_forwarded in the dedicated
-- schema-message-forward-{expand,contract}.sql migration. Keeping that work out of this normally
-- rerun schema file prevents an unbounded messages scan on every deploy.
ALTER TABLE messages ADD COLUMN IF NOT EXISTS media_id UUID REFERENCES media_objects(id);
ALTER TABLE messages ADD COLUMN IF NOT EXISTS media_group_id UUID;
ALTER TABLE messages ADD COLUMN IF NOT EXISTS media_group_index SMALLINT;
ALTER TABLE messages ADD COLUMN IF NOT EXISTS media_group_count SMALLINT;
ALTER TABLE messages ADD COLUMN IF NOT EXISTS send_fingerprint BYTEA;
ALTER TABLE messages ADD COLUMN IF NOT EXISTS send_fingerprint_key_id TEXT NOT NULL DEFAULT 'legacy-v1';
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'messages_send_fingerprint_size_check'
  ) THEN
    ALTER TABLE messages ADD CONSTRAINT messages_send_fingerprint_size_check
      CHECK (send_fingerprint IS NULL OR octet_length(send_fingerprint) = 32) NOT VALID;
  END IF;
END $$;
ALTER TABLE messages ADD COLUMN IF NOT EXISTS draft_consume_operation_id UUID;
ALTER TABLE messages ADD COLUMN IF NOT EXISTS draft_cleared_revision BIGINT;
ALTER TABLE messages ADD COLUMN IF NOT EXISTS service_type TEXT;
ALTER TABLE messages ADD COLUMN IF NOT EXISTS service_data JSONB;
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM schema_migrations WHERE name = 'messages-domain-constraints-v2')
     AND NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'messages_kind_check_v2') THEN
    ALTER TABLE messages ADD CONSTRAINT messages_kind_check_v2
      CHECK (kind IN ('text','photo','video','file','voice','service')) NOT VALID;
    ALTER TABLE messages ADD CONSTRAINT messages_service_type_check_v2 CHECK (
      service_type IS NULL OR service_type IN (
        'group.created','member.added','member.removed','member.role_changed','member.left',
        'dialog.title_changed','dialog.photo_changed','dialog.owner_transferred','dialog.closed',
        'call.completed','call.declined','call.missed','call.busy','call.cancelled','call.failed'
      )
    ) NOT VALID;
  END IF;
END $$;
CREATE INDEX IF NOT EXISTS messages_media_idx ON messages(media_id) WHERE media_id IS NOT NULL;
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM schema_migrations WHERE name = 'messages-media-group-shape-v2')
     AND NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'messages_media_group_shape_check_v2') THEN
    ALTER TABLE messages ADD CONSTRAINT messages_media_group_shape_check_v2 CHECK (
      (media_group_id IS NULL AND media_group_index IS NULL AND media_group_count IS NULL)
      OR (
        media_group_id IS NOT NULL
        AND media_group_index IS NOT NULL
        AND media_group_count BETWEEN 2 AND 10
        AND media_group_index >= 0
        AND media_group_index < media_group_count
        AND media_id IS NOT NULL
      )
    ) NOT VALID;
  END IF;
END $$;
-- The call-eligibility index is built concurrently by schema-concurrent.sql because messages is an
-- existing, high-write table.
DO $$ BEGIN
  ALTER TABLE messages ADD CONSTRAINT messages_reply_target_fk
    FOREIGN KEY (dialog_id, reply_to_msg_id) REFERENCES messages(dialog_id, msg_id);
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;
DO $$ BEGIN
  ALTER TABLE messages ADD CONSTRAINT messages_forward_source_fk
    FOREIGN KEY (forwarded_from_dialog_id, forwarded_from_msg_id) REFERENCES messages(dialog_id, msg_id);
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

CREATE TABLE IF NOT EXISTS message_reactions (
  dialog_id  UUID NOT NULL,
  msg_id     BIGINT NOT NULL,
  account_id UUID NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  emoji      TEXT NOT NULL CHECK (char_length(emoji) BETWEEN 1 AND 16),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (dialog_id, msg_id, account_id),
  FOREIGN KEY (dialog_id, msg_id) REFERENCES messages(dialog_id, msg_id) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS message_mentions (
  dialog_id UUID NOT NULL,
  msg_id BIGINT NOT NULL,
  account_id UUID NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  entity_offset INT NOT NULL CHECK (entity_offset >= 0),
  length INT NOT NULL CHECK (length > 0),
  PRIMARY KEY (dialog_id, msg_id, account_id),
  FOREIGN KEY (dialog_id, msg_id) REFERENCES messages(dialog_id, msg_id) ON DELETE CASCADE
);
-- No separate DESC index (C1): the PK (dialog_id, msg_id) serves ORDER BY msg_id DESC via reverse scan.

-- ============ the sync log (crown jewel) ============
CREATE TABLE IF NOT EXISTS account_events (
  account_id        UUID   NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  pts               BIGINT NOT NULL,
  type              TEXT   NOT NULL CHECK (type IN
                       ('message.new','message.edited','message.deleted','message.expired','message.preview_updated',
                        'reaction.updated','read.updated','dialog.created','member.added','member.removed',
                        'member.role_changed','member.left','dialog.profile_updated','dialog.closed',
                        'dialog.access_revoked','dialog.preferences_updated','profile.updated','draft.updated',
                        'security.changed','chat_folders.updated','scheduled.created','scheduled.updated',
                        'scheduled.canceled','scheduled.failed','pin.updated','dialog.auto_delete_updated',
                        'poll.updated','sticker_preferences.updated')),
  dialog_id         UUID,
  msg_id            BIGINT,
  actor_account_id  UUID REFERENCES accounts(id),
  data              JSONB NOT NULL DEFAULT '{}'::jsonb,   -- variable extras only (no dup of typed cols, C4)
  created_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (account_id, pts)                            -- serves get_difference: WHERE account_id=? AND pts>? ORDER BY pts
);
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM schema_migrations WHERE name = 'account-events-type-v2')
     AND NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'account_events_type_check_v2') THEN
    ALTER TABLE account_events ADD CONSTRAINT account_events_type_check_v2 CHECK (type IN
      ('message.new','message.edited','message.deleted','message.expired','message.preview_updated',
       'reaction.updated','read.updated','dialog.created','member.added','member.removed',
       'member.role_changed','member.left','dialog.profile_updated','dialog.closed',
       'dialog.access_revoked','dialog.preferences_updated','profile.updated','draft.updated',
       'security.changed','chat_folders.updated','scheduled.created','scheduled.updated',
       'scheduled.canceled','scheduled.failed','pin.updated','dialog.auto_delete_updated',
       'poll.updated','sticker_preferences.updated')) NOT VALID;
  END IF;
END $$;
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM schema_migrations WHERE name = 'account-events-type-v3')
     AND NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'account_events_type_check_v3') THEN
    ALTER TABLE account_events ADD CONSTRAINT account_events_type_check_v3 CHECK (type IN
      ('message.new','message.edited','message.deleted','message.expired','message.preview_updated',
       'reaction.updated','read.updated','dialog.created','member.added','member.removed',
       'member.role_changed','member.left','dialog.profile_updated','dialog.closed',
       'dialog.access_revoked','dialog.preferences_updated','profile.updated','draft.updated',
       'security.changed','chat_folders.updated','scheduled.created','scheduled.updated',
       'scheduled.canceled','scheduled.failed','pin.updated','dialog.auto_delete_updated',
       'poll.updated','sticker_preferences.updated')) NOT VALID;
  END IF;
END $$;
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM schema_migrations WHERE name = 'account-events-type-v4')
     AND NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'account_events_type_check_v4') THEN
    ALTER TABLE account_events ADD CONSTRAINT account_events_type_check_v4 CHECK (type IN
      ('message.new','message.edited','message.deleted','message.expired','message.preview_updated',
       'reaction.updated','read.updated','dialog.created','member.added','member.removed',
       'member.role_changed','member.left','dialog.profile_updated','dialog.closed',
       'dialog.access_revoked','dialog.preferences_updated','profile.updated','draft.updated',
       'security.changed','chat_folders.updated','scheduled.created','scheduled.updated',
       'scheduled.canceled','scheduled.failed','pin.updated','dialog.auto_delete_updated',
       'poll.updated','sticker_preferences.updated')) NOT VALID;
  END IF;
END $$;

-- ============ idempotency (B2): claimed BEFORE any msg_id is allocated ============
CREATE TABLE IF NOT EXISTS send_requests (
  sender_account_id UUID NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  client_msg_id     UUID NOT NULL,
  dialog_id         UUID NOT NULL,
  status            TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','completed')),
  msg_id            BIGINT,                            -- filled on completion
  sender_pts        BIGINT,                            -- filled on completion (retry must echo this)
  draft_consume_operation_id UUID,
  cleared_draft_revision BIGINT,
  fingerprint       BYTEA,
  fingerprint_key_id TEXT NOT NULL DEFAULT 'legacy-v1',
  created_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (sender_account_id, client_msg_id)
);
ALTER TABLE send_requests ADD COLUMN IF NOT EXISTS draft_consume_operation_id UUID;
ALTER TABLE send_requests ADD COLUMN IF NOT EXISTS cleared_draft_revision BIGINT;
ALTER TABLE send_requests ADD COLUMN IF NOT EXISTS fingerprint BYTEA;
ALTER TABLE send_requests ADD COLUMN IF NOT EXISTS fingerprint_key_id TEXT NOT NULL DEFAULT 'legacy-v1';
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'send_requests_fingerprint_size_check'
  ) THEN
    ALTER TABLE send_requests ADD CONSTRAINT send_requests_fingerprint_size_check
      CHECK (fingerprint IS NULL OR octet_length(fingerprint) = 32) NOT VALID;
  END IF;
END $$;
DO $$ BEGIN
  ALTER TABLE send_requests ADD CONSTRAINT send_requests_fingerprint_key_check
    CHECK (fingerprint IS NULL OR fingerprint_key_id IS NOT NULL) NOT VALID;
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

-- ============ account-private cloud drafts ============
-- Draft bodies use the same server-side AEAD model as cloud message bodies. A cleared row remains
-- as a tombstone, preventing delayed device responses from resurrecting an older generation.
CREATE TABLE IF NOT EXISTS account_dialog_drafts (
  account_id        UUID NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  dialog_id         UUID NOT NULL REFERENCES dialogs(id) ON DELETE CASCADE,
  state             TEXT NOT NULL CHECK (state IN ('active','cleared')),
  body_key_id       TEXT NOT NULL,
  body_nonce        BYTEA NOT NULL,
  body_ciphertext   BYTEA NOT NULL,
  reply_to_msg_id   BIGINT,
  mentions          JSONB NOT NULL DEFAULT '[]'::jsonb,
  revision          BIGINT NOT NULL CHECK (revision > 0),
  operation_id      UUID NOT NULL,
  source_device_id  UUID REFERENCES devices(id) ON DELETE SET NULL,
  created_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (account_id, dialog_id),
  FOREIGN KEY (dialog_id, reply_to_msg_id) REFERENCES messages(dialog_id, msg_id)
);
CREATE INDEX IF NOT EXISTS account_dialog_drafts_dialog_idx
  ON account_dialog_drafts(dialog_id, account_id);

CREATE TABLE IF NOT EXISTS draft_attachments (
  account_id     UUID NOT NULL,
  dialog_id      UUID NOT NULL,
  attachment_id UUID NOT NULL,
  media_id       UUID NOT NULL REFERENCES media_objects(id) ON DELETE CASCADE,
  position       SMALLINT NOT NULL CHECK (position BETWEEN 0 AND 9),
  created_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (account_id, dialog_id, attachment_id),
  UNIQUE (account_id, dialog_id, position),
  UNIQUE (account_id, dialog_id, media_id),
  FOREIGN KEY (account_id, dialog_id)
    REFERENCES account_dialog_drafts(account_id, dialog_id) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS draft_attachments_media_idx ON draft_attachments(media_id);

CREATE TABLE IF NOT EXISTS draft_mutation_requests (
  account_id          UUID NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  operation_id        UUID NOT NULL,
  dialog_id           UUID NOT NULL,
  payload_fingerprint BYTEA NOT NULL CHECK (octet_length(payload_fingerprint) = 32),
  status              TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','completed')),
  resulting_revision  BIGINT,
  response_key_id     TEXT,
  response_nonce      BYTEA,
  response_ciphertext BYTEA,
  created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (account_id, operation_id),
  CHECK (
    (status = 'pending' AND resulting_revision IS NULL
      AND response_key_id IS NULL AND response_nonce IS NULL AND response_ciphertext IS NULL)
    OR
    (status = 'completed' AND resulting_revision IS NOT NULL
      AND response_key_id IS NOT NULL AND response_nonce IS NOT NULL AND response_ciphertext IS NOT NULL)
  )
);

-- Compact receipts outlive encrypted response cleanup. They intentionally carry no draft body:
-- an exact delayed retry returns the current dialog draft and can never allocate a new pts.
CREATE TABLE IF NOT EXISTS draft_mutation_tombstones (
  account_id          UUID NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  operation_id        UUID NOT NULL,
  dialog_id           UUID NOT NULL,
  payload_fingerprint BYTEA NOT NULL CHECK (octet_length(payload_fingerprint) = 32),
  resulting_revision  BIGINT NOT NULL CHECK (resulting_revision > 0),
  created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (account_id, operation_id)
);
ALTER TABLE draft_mutation_requests ADD COLUMN IF NOT EXISTS fingerprint_key_id TEXT NOT NULL DEFAULT 'legacy-v1';
ALTER TABLE draft_mutation_tombstones ADD COLUMN IF NOT EXISTS fingerprint_key_id TEXT NOT NULL DEFAULT 'legacy-v1';

-- One immutable row per accepted mutation makes the 120/minute device budget a true rolling window.
CREATE TABLE IF NOT EXISTS draft_mutation_budgets (
  id           BIGSERIAL PRIMARY KEY,
  account_id   UUID NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  device_id    UUID NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
  operation_id UUID NOT NULL,
  accepted_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (account_id, operation_id)
);
CREATE INDEX IF NOT EXISTS draft_mutation_budgets_device_window_idx
  ON draft_mutation_budgets(device_id, accepted_at DESC);

CREATE TABLE IF NOT EXISTS media_group_send_requests (
  sender_account_id UUID NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  client_group_id   UUID NOT NULL,
  dialog_id         UUID NOT NULL,
  payload_fingerprint BYTEA NOT NULL CHECK (octet_length(payload_fingerprint) = 32),
  status            TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','completed')),
  first_msg_id      BIGINT,
  last_msg_id       BIGINT,
  sender_pts        BIGINT,
  draft_consume_operation_id UUID,
  cleared_draft_revision BIGINT,
  created_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (sender_account_id, client_group_id),
  CHECK (
    (status = 'pending' AND first_msg_id IS NULL AND last_msg_id IS NULL AND sender_pts IS NULL)
    OR
    (status = 'completed' AND first_msg_id IS NOT NULL AND last_msg_id IS NOT NULL AND sender_pts IS NOT NULL)
  )
);

-- A group operation remains consumed after the full response receipt expires or its messages are
-- later removed. The fingerprint prevents a reused operation id from changing shape.
CREATE TABLE IF NOT EXISTS media_group_send_tombstones (
  sender_account_id   UUID NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  client_group_id     UUID NOT NULL,
  dialog_id           UUID NOT NULL,
  payload_fingerprint BYTEA NOT NULL CHECK (octet_length(payload_fingerprint) = 32),
  first_msg_id        BIGINT NOT NULL,
  last_msg_id         BIGINT NOT NULL,
  sender_pts          BIGINT NOT NULL,
  cleared_draft_revision BIGINT,
  created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (sender_account_id, client_group_id)
);
ALTER TABLE media_group_send_requests ADD COLUMN IF NOT EXISTS fingerprint_key_id TEXT NOT NULL DEFAULT 'legacy-v1';
ALTER TABLE media_group_send_tombstones ADD COLUMN IF NOT EXISTS fingerprint_key_id TEXT NOT NULL DEFAULT 'legacy-v1';

-- Counts album items rather than requests so ten-item groups cannot multiply mutation ingress.
CREATE TABLE IF NOT EXISTS media_group_send_budgets (
  id BIGSERIAL PRIMARY KEY,
  account_id UUID NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  device_id UUID NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
  item_count SMALLINT NOT NULL CHECK (item_count BETWEEN 2 AND 10),
  accepted_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS media_group_send_budgets_account_window_idx
  ON media_group_send_budgets(account_id, accepted_at DESC);

CREATE TABLE IF NOT EXISTS saved_messages_backfill_claims (
  account_id   UUID PRIMARY KEY REFERENCES accounts(id) ON DELETE CASCADE,
  worker_id    UUID NOT NULL,
  claimed_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
  completed_at TIMESTAMPTZ,
  attempts     INT NOT NULL DEFAULT 1 CHECK (attempts > 0),
  last_error   TEXT
);
CREATE INDEX IF NOT EXISTS saved_messages_backfill_pending_idx
  ON saved_messages_backfill_claims(claimed_at, account_id)
  WHERE completed_at IS NULL;

-- Edit/delete retries use a client-generated mutation id just like sends use client_msg_id.
-- The claim is taken before locking the message so a timed-out request can safely be repeated.
CREATE TABLE IF NOT EXISTS message_mutation_requests (
  actor_account_id  UUID NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  client_mutation_id UUID NOT NULL,
  operation         TEXT NOT NULL CHECK (operation IN ('edit','delete','reaction')),
  dialog_id         UUID NOT NULL,
  msg_id            BIGINT NOT NULL,
  status            TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','completed')),
  actor_pts         BIGINT,
  created_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (actor_account_id, client_mutation_id)
);
-- Early development versions briefly added this FK. The idempotency row must be claimable before
-- the message row is locked (global lock order), so validation happens transactionally in sync.ts.
DO $$ BEGIN
  IF EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'message_mutation_requests_dialog_id_msg_id_fkey'
  ) THEN
    ALTER TABLE message_mutation_requests
      DROP CONSTRAINT message_mutation_requests_dialog_id_msg_id_fkey;
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM schema_migrations WHERE name = 'message-mutation-operation-v2'
  ) AND NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'message_mutation_requests_operation_check_v2'
  ) THEN
    ALTER TABLE message_mutation_requests
      ADD CONSTRAINT message_mutation_requests_operation_check_v2
      CHECK (operation IN ('edit','delete','reaction')) NOT VALID;
  END IF;
END $$;

-- Group creation uses the final client UUID as both the dialog id and the idempotency key.
CREATE TABLE IF NOT EXISTS group_create_requests (
  creator_account_id UUID NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  client_group_id UUID NOT NULL,
  fingerprint BYTEA NOT NULL,
  status TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','completed')),
  result_revision BIGINT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (creator_account_id, client_group_id)
);

CREATE TABLE IF NOT EXISTS group_mutation_requests (
  actor_account_id UUID NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  client_mutation_id UUID NOT NULL,
  dialog_id UUID NOT NULL,
  operation TEXT NOT NULL CHECK (operation IN (
    'add_members','remove_member','change_role','update_profile','update_permissions',
    'transfer_owner','leave','notifications'
  )),
  fingerprint BYTEA NOT NULL,
  status TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','completed')),
  result_revision BIGINT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (actor_account_id, client_mutation_id)
);
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM schema_migrations WHERE name = 'group-mutation-operation-v2')
     AND NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'group_mutation_requests_operation_check_v2') THEN
    ALTER TABLE group_mutation_requests ADD CONSTRAINT group_mutation_requests_operation_check_v2
      CHECK (operation IN (
        'add_members','remove_member','change_role','update_profile','update_permissions',
        'transfer_owner','leave','notifications'
      )) NOT VALID;
  END IF;
END $$;

CREATE TABLE IF NOT EXISTS group_action_budgets (
  id BIGSERIAL PRIMARY KEY,
  account_id UUID NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  target_account_id UUID REFERENCES accounts(id) ON DELETE CASCADE,
  action TEXT NOT NULL CHECK (action IN ('create','add','stranger_add')),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- ============ APNs durable outbox (M4.1) ============
-- APNs is only a wake-up hint. The authoritative update remains account_events + get_difference.
-- Rows are created in the same transaction as message.new, so a process crash cannot lose the hint.
CREATE TABLE IF NOT EXISTS push_deliveries (
  id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  account_id   UUID NOT NULL,
  pts          BIGINT NOT NULL,
  device_id    UUID NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
  alert        BOOLEAN NOT NULL,
  status       TEXT NOT NULL DEFAULT 'pending'
                 CHECK (status IN ('pending','sending','sent','dead')),
  attempts     INT NOT NULL DEFAULT 0,
  available_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  claimed_at   TIMESTAMPTZ,
  expires_at   TIMESTAMPTZ NOT NULL DEFAULT (now() + interval '24 hours'),
  apns_id      TEXT,
  last_error   TEXT,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
  sent_at      TIMESTAMPTZ,
  FOREIGN KEY (account_id, pts) REFERENCES account_events(account_id, pts) ON DELETE CASCADE,
  UNIQUE (account_id, pts, device_id)
);
CREATE INDEX IF NOT EXISTS push_deliveries_ready_idx
  ON push_deliveries(available_at, created_at)
  WHERE status IN ('pending','sending');

-- ============ one-to-one E2EE voice-call control plane ============
-- The server stores lifecycle metadata, public key-agreement material, and opaque encrypted
-- signaling only. It never receives the derived call key, plaintext SDP/ICE, or media.
CREATE TABLE IF NOT EXISTS account_blocks (
  blocker_account_id UUID NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  blocked_account_id UUID NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  created_at         TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (blocker_account_id, blocked_account_id),
  CHECK (blocker_account_id <> blocked_account_id)
);
CREATE INDEX IF NOT EXISTS account_blocks_blocked_idx ON account_blocks(blocked_account_id, blocker_account_id);

CREATE TABLE IF NOT EXISTS calls (
  id                        UUID PRIMARY KEY,
  dialog_id                 UUID NOT NULL REFERENCES dialogs(id),
  caller_account_id         UUID NOT NULL REFERENCES accounts(id),
  caller_device_id          UUID NOT NULL REFERENCES devices(id),
  callee_account_id         UUID NOT NULL REFERENCES accounts(id),
  state                     TEXT NOT NULL DEFAULT 'requested'
                              CHECK (state IN ('requested','accepted','key_exchange','active','ended')),
  supported_protocols       INT[] NOT NULL,
  offered_media_profiles    INT[] NOT NULL,
  initial_kind              TEXT NOT NULL DEFAULT 'voice'
                              CHECK (initial_kind IN ('voice','video')),
  selectable_media_profiles INT[] NOT NULL DEFAULT ARRAY[1]::INT[],
  protocol_version          INT,
  media_profile_version     INT,
  caller_commitment         BYTEA NOT NULL CHECK (octet_length(caller_commitment) = 32),
  callee_commitment         BYTEA CHECK (callee_commitment IS NULL OR octet_length(callee_commitment) = 32),
  caller_fingerprint        BYTEA CHECK (caller_fingerprint IS NULL OR octet_length(caller_fingerprint) = 32),
  accepted_device_id        UUID REFERENCES devices(id),
  callee_public_key         BYTEA CHECK (callee_public_key IS NULL OR octet_length(callee_public_key) = 32),
  callee_nonce              BYTEA CHECK (callee_nonce IS NULL OR octet_length(callee_nonce) = 32),
  callee_fingerprint        BYTEA CHECK (callee_fingerprint IS NULL OR octet_length(callee_fingerprint) = 32),
  caller_public_key         BYTEA CHECK (caller_public_key IS NULL OR octet_length(caller_public_key) = 32),
  caller_nonce              BYTEA CHECK (caller_nonce IS NULL OR octet_length(caller_nonce) = 32),
  caller_confirmation       BYTEA CHECK (caller_confirmation IS NULL OR octet_length(caller_confirmation) = 32),
  callee_confirmation       BYTEA CHECK (callee_confirmation IS NULL OR octet_length(callee_confirmation) = 32),
  latest_event_seq          BIGINT NOT NULL DEFAULT 0,
  created_at                TIMESTAMPTZ NOT NULL DEFAULT now(),
  expires_at                TIMESTAMPTZ NOT NULL DEFAULT now() + interval '30 seconds',
  accepted_at               TIMESTAMPTZ,
  confirmed_at              TIMESTAMPTZ,
  ended_at                  TIMESTAMPTZ,
  end_reason                TEXT,
  CHECK (caller_account_id <> callee_account_id)
);
ALTER TABLE calls ADD COLUMN IF NOT EXISTS initial_kind TEXT NOT NULL DEFAULT 'voice';
ALTER TABLE calls ADD COLUMN IF NOT EXISTS selectable_media_profiles INT[];
ALTER TABLE calls ALTER COLUMN selectable_media_profiles SET DEFAULT ARRAY[1]::INT[];
DO $$ BEGIN
  ALTER TABLE calls ADD CONSTRAINT calls_initial_kind_check CHECK (initial_kind IN ('voice','video'));
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;
DO $$ BEGIN
  ALTER TABLE calls ADD CONSTRAINT calls_selectable_media_profiles_not_null
    CHECK (selectable_media_profiles IS NOT NULL) NOT VALID;
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;
CREATE INDEX IF NOT EXISTS calls_caller_active_idx ON calls(caller_account_id, created_at DESC)
  WHERE state <> 'ended';
CREATE INDEX IF NOT EXISTS calls_callee_active_idx ON calls(callee_account_id, created_at DESC)
  WHERE state <> 'ended';
CREATE INDEX IF NOT EXISTS calls_expiry_idx ON calls(expires_at) WHERE state <> 'ended';
CREATE INDEX IF NOT EXISTS calls_ended_retention_idx ON calls(ended_at) WHERE state = 'ended';

-- At most one active call can hold an account lease. Acquiring both leases in account UUID order
-- makes simultaneous cross-calls deterministic and prevents double CallKit sessions.
CREATE TABLE IF NOT EXISTS call_participant_leases (
  account_id UUID PRIMARY KEY REFERENCES accounts(id) ON DELETE CASCADE,
  call_id    UUID NOT NULL REFERENCES calls(id) ON DELETE CASCADE,
  expires_at TIMESTAMPTZ NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (call_id, account_id)
);
CREATE INDEX IF NOT EXISTS call_participant_leases_expiry_idx ON call_participant_leases(expires_at);

CREATE TABLE IF NOT EXISTS call_ring_targets (
  call_id     UUID NOT NULL REFERENCES calls(id) ON DELETE CASCADE,
  device_id   UUID NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
  status      TEXT NOT NULL DEFAULT 'ringing'
                CHECK (status IN ('ringing','accepted','declined','answered_elsewhere','expired','ended')),
  selectable_protocols INT[] NOT NULL DEFAULT ARRAY[1]::INT[],
  selectable_media_profiles INT[] NOT NULL DEFAULT ARRAY[1]::INT[],
  call_view_version INT NOT NULL DEFAULT 1,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  responded_at TIMESTAMPTZ,
  PRIMARY KEY (call_id, device_id)
);
ALTER TABLE call_ring_targets ADD COLUMN IF NOT EXISTS selectable_protocols INT[] NOT NULL DEFAULT ARRAY[1]::INT[];
ALTER TABLE call_ring_targets ADD COLUMN IF NOT EXISTS selectable_media_profiles INT[] NOT NULL DEFAULT ARRAY[1]::INT[];
ALTER TABLE call_ring_targets ADD COLUMN IF NOT EXISTS call_view_version INT NOT NULL DEFAULT 1;
CREATE INDEX IF NOT EXISTS call_ring_targets_device_idx ON call_ring_targets(device_id, created_at DESC);

CREATE TABLE IF NOT EXISTS call_events (
  call_id          UUID NOT NULL REFERENCES calls(id) ON DELETE CASCADE,
  event_seq        BIGINT NOT NULL CHECK (event_seq > 0),
  event_type       TEXT NOT NULL CHECK (event_type IN ('requested','accepted','revealed','confirmed','encrypted','ended')),
  sender_account_id UUID REFERENCES accounts(id),
  sender_device_id UUID REFERENCES devices(id),
  sender_sequence  BIGINT CHECK (sender_sequence IS NULL OR sender_sequence > 0),
  signal_version   INT,
  signal_kind      TEXT CHECK (signal_kind IS NULL OR signal_kind IN
                       ('offer','answer','ice_candidate','ice_restart','hangup','control')),
  envelope_expires_at TIMESTAMPTZ,
  ciphertext       BYTEA CHECK (ciphertext IS NULL OR octet_length(ciphertext) BETWEEN 1 AND 65564),
  data             JSONB,
  created_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
  expires_at       TIMESTAMPTZ NOT NULL DEFAULT now() + interval '24 hours',
  PRIMARY KEY (call_id, event_seq),
  CHECK ((event_type = 'encrypted' AND ciphertext IS NOT NULL AND data IS NULL AND sender_sequence IS NOT NULL
          AND signal_version IS NOT NULL AND signal_kind IS NOT NULL AND envelope_expires_at IS NOT NULL)
      OR (event_type <> 'encrypted' AND ciphertext IS NULL AND data IS NOT NULL AND sender_sequence IS NULL
          AND signal_version IS NULL AND signal_kind IS NULL AND envelope_expires_at IS NULL))
);
CREATE INDEX IF NOT EXISTS call_events_expiry_idx ON call_events(expires_at);
CREATE UNIQUE INDEX IF NOT EXISTS call_events_sender_sequence_idx
  ON call_events(call_id, sender_device_id, sender_sequence) WHERE sender_sequence IS NOT NULL;

-- One active call is allowed per account, and each owning device gets a small rolling signaling
-- budget. This bounds database/WAL/NOTIFY amplification without inspecting encrypted SDP or ICE.
CREATE TABLE IF NOT EXISTS call_signal_budgets (
  call_id                 UUID NOT NULL REFERENCES calls(id) ON DELETE CASCADE,
  sender_device_id        UUID NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
  window_started_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
  event_count             INT NOT NULL DEFAULT 0 CHECK (event_count >= 0),
  ciphertext_bytes        BIGINT NOT NULL DEFAULT 0 CHECK (ciphertext_bytes >= 0),
  negotiation_event_count INT NOT NULL DEFAULT 0 CHECK (negotiation_event_count >= 0),
  PRIMARY KEY (call_id, sender_device_id)
);

CREATE TABLE IF NOT EXISTS call_telemetry_reports (
  call_id    UUID NOT NULL REFERENCES calls(id) ON DELETE CASCADE,
  device_id  UUID NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (call_id, device_id)
);

-- The call row and its user-visible history row must survive independent process/database failures.
-- A terminal transition inserts this record in the same transaction; a retrying worker delivers the
-- service message with the original caller identity as its stable idempotency owner.
CREATE TABLE IF NOT EXISTS call_history_outbox (
  call_id            UUID PRIMARY KEY REFERENCES calls(id) ON DELETE CASCADE,
  history_client_msg_id UUID NOT NULL DEFAULT gen_random_uuid(),
  dialog_id          UUID NOT NULL REFERENCES dialogs(id),
  caller_account_id  UUID NOT NULL REFERENCES accounts(id),
  initial_kind       TEXT NOT NULL DEFAULT 'voice'
                       CHECK (initial_kind IN ('voice','video')),
  outcome            TEXT NOT NULL CHECK (outcome IN ('completed','declined','missed','busy','cancelled','failed')),
  duration_seconds   INT NOT NULL DEFAULT 0 CHECK (duration_seconds >= 0),
  status             TEXT NOT NULL DEFAULT 'pending'
                       CHECK (status IN ('pending','sending','delivered')),
  attempts           INT NOT NULL DEFAULT 0,
  available_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
  claimed_at         TIMESTAMPTZ,
  last_error         TEXT,
  created_at         TIMESTAMPTZ NOT NULL DEFAULT now(),
  delivered_at       TIMESTAMPTZ
);
ALTER TABLE call_history_outbox ADD COLUMN IF NOT EXISTS initial_kind TEXT NOT NULL DEFAULT 'voice';
DO $$ BEGIN
  ALTER TABLE call_history_outbox ADD CONSTRAINT call_history_outbox_initial_kind_check
    CHECK (initial_kind IN ('voice','video'));
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;
ALTER TABLE call_history_outbox ADD COLUMN IF NOT EXISTS history_client_msg_id UUID DEFAULT gen_random_uuid();
UPDATE call_history_outbox SET history_client_msg_id = gen_random_uuid()
WHERE history_client_msg_id IS NULL;
ALTER TABLE call_history_outbox ALTER COLUMN history_client_msg_id SET NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS call_history_outbox_client_msg_idx
  ON call_history_outbox(caller_account_id, history_client_msg_id);
CREATE INDEX IF NOT EXISTS call_history_outbox_ready_idx
  ON call_history_outbox(available_at, created_at) WHERE status IN ('pending','sending');

-- ============ E2EE group-call control plane ============
-- Group media is routed by an SFU, but every audio/video/screen frame is encrypted above
-- DTLS-SRTP on the participating devices. The server stores only public join keys, commitments,
-- and opaque per-device epoch envelopes. It never stores a media key or an SFU API secret.
CREATE TABLE IF NOT EXISTS group_calls (
  id                    UUID PRIMARY KEY,
  dialog_id             UUID NOT NULL REFERENCES dialogs(id) ON DELETE CASCADE,
  creator_account_id    UUID NOT NULL REFERENCES accounts(id),
  creator_device_id     UUID NOT NULL REFERENCES devices(id),
  initial_kind          TEXT NOT NULL CHECK (initial_kind IN ('voice','video')),
  state                 TEXT NOT NULL DEFAULT 'active' CHECK (state IN ('active','ended')),
  sfu_room_name         TEXT NOT NULL UNIQUE
                          CHECK (char_length(sfu_room_name) BETWEEN 16 AND 96),
  participant_limit     SMALLINT NOT NULL DEFAULT 32
                          CHECK (participant_limit BETWEEN 2 AND 32),
  publisher_limit       SMALLINT NOT NULL DEFAULT 16
                          CHECK (publisher_limit BETWEEN 1 AND 16
                            AND publisher_limit <= participant_limit),
  membership_revision   BIGINT NOT NULL DEFAULT 1 CHECK (membership_revision > 0),
  state_revision        BIGINT NOT NULL DEFAULT 1 CHECK (state_revision > 0),
  media_epoch           BIGINT NOT NULL DEFAULT 1 CHECK (media_epoch > 0),
  key_leader_device_id  UUID NOT NULL REFERENCES devices(id),
  epoch_key_commitment  BYTEA NOT NULL CHECK (octet_length(epoch_key_commitment) = 32),
  created_at            TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at            TIMESTAMPTZ NOT NULL DEFAULT now(),
  ended_at              TIMESTAMPTZ,
  end_reason            TEXT,
  CHECK (
    (state = 'active' AND ended_at IS NULL AND end_reason IS NULL)
    OR (state = 'ended' AND ended_at IS NOT NULL AND end_reason IS NOT NULL)
  )
);
ALTER TABLE group_calls ADD COLUMN IF NOT EXISTS state_revision BIGINT NOT NULL DEFAULT 1;
CREATE UNIQUE INDEX IF NOT EXISTS group_calls_one_active_per_dialog_idx
  ON group_calls(dialog_id) WHERE state = 'active';
CREATE INDEX IF NOT EXISTS group_calls_retention_idx
  ON group_calls(ended_at) WHERE state = 'ended';

CREATE TABLE IF NOT EXISTS group_call_participants (
  call_id                    UUID NOT NULL REFERENCES group_calls(id) ON DELETE CASCADE,
  device_id                  UUID NOT NULL REFERENCES devices(id),
  account_id                 UUID NOT NULL REFERENCES accounts(id),
  call_local_identity        UUID NOT NULL,
  status                     TEXT NOT NULL
                               CHECK (status IN ('pending_key','active','left','removed')),
  join_public_key            BYTEA NOT NULL CHECK (octet_length(join_public_key) = 32),
  join_nonce                 BYTEA NOT NULL CHECK (octet_length(join_nonce) = 32),
  joined_membership_revision BIGINT NOT NULL CHECK (joined_membership_revision > 0),
  ready_media_epoch          BIGINT CHECK (ready_media_epoch IS NULL OR ready_media_epoch > 0),
  joined_at                  TIMESTAMPTZ NOT NULL DEFAULT now(),
  last_seen_at               TIMESTAMPTZ NOT NULL DEFAULT now(),
  last_heartbeat_at          TIMESTAMPTZ NOT NULL DEFAULT now() - interval '20 seconds',
  left_at                    TIMESTAMPTZ,
  PRIMARY KEY (call_id, device_id),
  UNIQUE (call_id, call_local_identity),
  CHECK (
    (status IN ('pending_key','active') AND left_at IS NULL)
    OR (status IN ('left','removed') AND left_at IS NOT NULL)
  ),
  CHECK (
    (status = 'active' AND ready_media_epoch IS NOT NULL)
    OR status <> 'active'
  )
);
ALTER TABLE group_call_participants ADD COLUMN IF NOT EXISTS last_heartbeat_at
  TIMESTAMPTZ NOT NULL DEFAULT now() - interval '20 seconds';
CREATE UNIQUE INDEX IF NOT EXISTS group_call_participants_one_device_per_account_idx
  ON group_call_participants(call_id, account_id)
  WHERE status IN ('pending_key','active');
CREATE INDEX IF NOT EXISTS group_call_participants_device_active_idx
  ON group_call_participants(device_id, joined_at DESC)
  WHERE status IN ('pending_key','active');
CREATE INDEX IF NOT EXISTS group_call_participants_account_active_idx
  ON group_call_participants(account_id, call_id, device_id)
  WHERE status IN ('pending_key','active');
CREATE INDEX IF NOT EXISTS group_call_participants_stale_idx
  ON group_call_participants(last_seen_at, call_id, device_id)
  WHERE status IN ('pending_key','active');

CREATE TABLE IF NOT EXISTS group_call_epochs (
  call_id              UUID NOT NULL REFERENCES group_calls(id) ON DELETE CASCADE,
  epoch                 BIGINT NOT NULL CHECK (epoch > 0),
  membership_revision  BIGINT NOT NULL CHECK (membership_revision > 0),
  leader_device_id     UUID NOT NULL REFERENCES devices(id),
  key_commitment       BYTEA NOT NULL CHECK (octet_length(key_commitment) = 32),
  participant_set_hash BYTEA NOT NULL CHECK (octet_length(participant_set_hash) = 32),
  created_at           TIMESTAMPTZ NOT NULL DEFAULT now(),
  activated_at         TIMESTAMPTZ NOT NULL DEFAULT now(),
  -- NULL marks the current epoch. It receives a ten-second grace deadline atomically when the
  -- next epoch activates.
  grace_expires_at     TIMESTAMPTZ,
  PRIMARY KEY (call_id, epoch),
  UNIQUE (call_id, membership_revision)
);

CREATE TABLE IF NOT EXISTS group_call_epoch_envelopes (
  call_id                  UUID NOT NULL,
  epoch                    BIGINT NOT NULL,
  recipient_device_id      UUID NOT NULL REFERENCES devices(id),
  sender_public_key        BYTEA NOT NULL CHECK (octet_length(sender_public_key) = 32),
  recipient_public_key     BYTEA NOT NULL CHECK (octet_length(recipient_public_key) = 32),
  ciphertext               BYTEA NOT NULL
                             CHECK (octet_length(ciphertext) BETWEEN 48 AND 4096),
  created_at               TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (call_id, epoch, recipient_device_id),
  FOREIGN KEY (call_id, epoch)
    REFERENCES group_call_epochs(call_id, epoch) ON DELETE CASCADE
);

-- A single screen source keeps subscription priority and UX deterministic in v1. A short lease
-- prevents a crashed broadcaster from blocking the room indefinitely.
CREATE TABLE IF NOT EXISTS group_call_screen_share_leases (
  call_id       UUID PRIMARY KEY REFERENCES group_calls(id) ON DELETE CASCADE,
  device_id     UUID NOT NULL REFERENCES devices(id),
  generation    UUID NOT NULL,
  expires_at    TIMESTAMPTZ NOT NULL,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS group_call_screen_share_expiry_idx
  ON group_call_screen_share_leases(expires_at);

-- Cameras are opt-in after join. A bounded renewable lease makes the advertised 16-camera room
-- limit enforceable across every API node instead of trusting a cooperative client.
CREATE TABLE IF NOT EXISTS group_call_camera_leases (
  call_id       UUID NOT NULL REFERENCES group_calls(id) ON DELETE CASCADE,
  device_id     UUID NOT NULL REFERENCES devices(id),
  generation    UUID NOT NULL,
  expires_at    TIMESTAMPTZ NOT NULL,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (call_id, device_id)
);
CREATE INDEX IF NOT EXISTS group_call_camera_lease_expiry_idx
  ON group_call_camera_leases(expires_at);

-- Desired SFU permissions are durable and monotonic. Only one worker may apply a participant's
-- state at a time, preventing a delayed camera/screen grant from racing a later revoke. Media keys
-- never enter this table; room and participant identifiers are random call-local values.
CREATE TABLE IF NOT EXISTS group_call_sfu_participant_states (
  call_id              UUID NOT NULL REFERENCES group_calls(id) ON DELETE CASCADE,
  device_id            UUID NOT NULL REFERENCES devices(id),
  participant_identity UUID NOT NULL,
  desired_status       TEXT NOT NULL DEFAULT 'active'
                         CHECK (desired_status IN ('active','removed')),
  media_allowed        BOOLEAN NOT NULL DEFAULT FALSE,
  camera_allowed       BOOLEAN NOT NULL DEFAULT FALSE,
  screen_share_allowed BOOLEAN NOT NULL DEFAULT FALSE,
  revision             BIGINT NOT NULL DEFAULT 1 CHECK (revision > 0),
  applied_revision     BIGINT NOT NULL DEFAULT 1 CHECK (applied_revision >= 0),
  applied_status       TEXT NOT NULL DEFAULT 'active',
  applied_media_allowed        BOOLEAN NOT NULL DEFAULT FALSE,
  applied_camera_allowed       BOOLEAN NOT NULL DEFAULT FALSE,
  applied_screen_share_allowed BOOLEAN NOT NULL DEFAULT FALSE,
  claim_token          UUID,
  claim_revision       BIGINT,
  claim_expires_at     TIMESTAMPTZ,
  token_not_before     BIGINT NOT NULL DEFAULT 0,
  attempt_count        INT NOT NULL DEFAULT 0 CHECK (attempt_count >= 0),
  next_attempt_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  last_error_code      TEXT,
  created_at           TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at           TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (call_id, participant_identity),
  CHECK (applied_revision <= revision),
  CHECK (
    (claim_token IS NULL AND claim_revision IS NULL AND claim_expires_at IS NULL)
    OR (claim_token IS NOT NULL AND claim_revision IS NOT NULL AND claim_expires_at IS NOT NULL)
  ),
  CONSTRAINT group_call_sfu_applied_status_check
    CHECK (applied_status IN ('active','removed')),
  CONSTRAINT group_call_sfu_applied_media_check
    CHECK (applied_status = 'active'
      OR (NOT applied_media_allowed
        AND NOT applied_camera_allowed AND NOT applied_screen_share_allowed)),
  CONSTRAINT group_call_sfu_removed_media_check
    CHECK (desired_status = 'active'
      OR (NOT media_allowed AND NOT camera_allowed AND NOT screen_share_allowed)),
  CONSTRAINT group_call_sfu_media_gate_check
    CHECK (media_allowed OR (NOT camera_allowed AND NOT screen_share_allowed)),
  CONSTRAINT group_call_sfu_token_not_before_check CHECK (token_not_before >= 0)
);
-- Existing pending rows may represent an in-flight revoke. Backfill them conservatively as the
-- opposite applied permission so the worker must execute that revoke before any successor grant.
DO $group_calls_media_fence$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM schema_migrations WHERE name = 'group-calls-media-fence-v2'
  ) THEN
    UPDATE group_call_sfu_participant_states SET
      applied_status = CASE
        WHEN applied_revision = revision THEN desired_status
        ELSE 'active'
      END,
      applied_camera_allowed = CASE
        WHEN applied_revision = revision THEN camera_allowed
        ELSE NOT camera_allowed
      END,
      applied_screen_share_allowed = CASE
        WHEN applied_revision = revision THEN screen_share_allowed
        ELSE NOT screen_share_allowed
      END
    WHERE applied_status IS NULL
       OR applied_camera_allowed IS NULL
       OR applied_screen_share_allowed IS NULL;

    -- Before this column existed, an applied active state meant that a room token could publish a
    -- microphone. Derive the desired state from the exact authenticated epoch and enqueue a revoke
    -- whenever membership has moved ahead of that epoch.
    UPDATE group_call_sfu_participant_states AS state SET
      media_allowed = state.desired_status = 'active'
        AND call.state = 'active'
        AND participant.status = 'active'
        AND participant.ready_media_epoch = call.media_epoch
        AND epoch.membership_revision = call.membership_revision,
      applied_media_allowed = state.applied_status = 'active'
    FROM group_calls AS call
    JOIN group_call_participants AS participant
      ON participant.call_id = call.id
    JOIN group_call_epochs AS epoch
      ON epoch.call_id = call.id AND epoch.epoch = call.media_epoch
    WHERE state.call_id = call.id
      AND state.device_id = participant.device_id
      AND (state.media_allowed IS NULL OR state.applied_media_allowed IS NULL);
    UPDATE group_call_sfu_participant_states SET
      media_allowed = COALESCE(media_allowed, FALSE),
      applied_media_allowed = COALESCE(applied_media_allowed, FALSE);
    UPDATE group_call_sfu_participant_states SET
      camera_allowed = FALSE,
      screen_share_allowed = FALSE
    WHERE NOT media_allowed OR desired_status = 'removed';
    UPDATE group_call_sfu_participant_states SET
      applied_media_allowed = FALSE,
      applied_camera_allowed = FALSE,
      applied_screen_share_allowed = FALSE
    WHERE applied_status = 'removed';
    UPDATE group_call_sfu_participant_states SET
      revision = revision + 1,
      next_attempt_at = now(),
      attempt_count = 0,
      claim_token = NULL,
      claim_revision = NULL,
      claim_expires_at = NULL
    WHERE applied_revision = revision
      AND (
        desired_status IS DISTINCT FROM applied_status
        OR media_allowed IS DISTINCT FROM applied_media_allowed
        OR camera_allowed IS DISTINCT FROM applied_camera_allowed
        OR screen_share_allowed IS DISTINCT FROM applied_screen_share_allowed
      );

    ALTER TABLE group_call_sfu_participant_states
      ALTER COLUMN applied_status SET DEFAULT 'active',
      ALTER COLUMN applied_status SET NOT NULL,
      ALTER COLUMN media_allowed SET DEFAULT FALSE,
      ALTER COLUMN media_allowed SET NOT NULL,
      ALTER COLUMN applied_media_allowed SET DEFAULT FALSE,
      ALTER COLUMN applied_media_allowed SET NOT NULL,
      ALTER COLUMN applied_camera_allowed SET DEFAULT FALSE,
      ALTER COLUMN applied_camera_allowed SET NOT NULL,
      ALTER COLUMN applied_screen_share_allowed SET DEFAULT FALSE,
      ALTER COLUMN applied_screen_share_allowed SET NOT NULL;

    ALTER TABLE group_call_sfu_participant_states
      DROP CONSTRAINT IF EXISTS group_call_sfu_applied_status_check,
      DROP CONSTRAINT IF EXISTS group_call_sfu_applied_media_check,
      DROP CONSTRAINT IF EXISTS group_call_sfu_media_gate_check,
      DROP CONSTRAINT IF EXISTS group_call_sfu_removed_media_check,
      DROP CONSTRAINT IF EXISTS group_call_sfu_token_not_before_check;
    ALTER TABLE group_call_sfu_participant_states
      ADD CONSTRAINT group_call_sfu_applied_status_check
        CHECK (applied_status IN ('active','removed')),
      ADD CONSTRAINT group_call_sfu_applied_media_check
        CHECK (applied_status = 'active'
          OR (NOT applied_media_allowed
            AND NOT applied_camera_allowed AND NOT applied_screen_share_allowed)),
      ADD CONSTRAINT group_call_sfu_media_gate_check
        CHECK (media_allowed OR (NOT camera_allowed AND NOT screen_share_allowed)),
      ADD CONSTRAINT group_call_sfu_removed_media_check
        CHECK (desired_status = 'active'
          OR (NOT media_allowed AND NOT camera_allowed AND NOT screen_share_allowed)),
      ADD CONSTRAINT group_call_sfu_token_not_before_check CHECK (token_not_before >= 0);

    INSERT INTO schema_migrations(name) VALUES ('group-calls-media-fence-v2')
    ON CONFLICT (name) DO NOTHING;
  END IF;
END;
$group_calls_media_fence$;
CREATE INDEX IF NOT EXISTS group_call_sfu_state_device_idx
  ON group_call_sfu_participant_states(call_id, device_id, updated_at);
CREATE INDEX IF NOT EXISTS group_call_sfu_state_pending_idx
  ON group_call_sfu_participant_states(next_attempt_at, updated_at)
  WHERE applied_revision < revision;
CREATE INDEX IF NOT EXISTS group_call_sfu_state_retention_idx
  ON group_call_sfu_participant_states(updated_at, call_id, participant_identity)
  WHERE desired_status = 'removed' AND applied_revision = revision;
INSERT INTO group_call_sfu_participant_states (
  call_id, device_id, participant_identity, desired_status,
  media_allowed, camera_allowed, screen_share_allowed, revision, applied_revision, next_attempt_at
)
SELECT participant.call_id, participant.device_id, participant.call_local_identity, 'active',
       participant.status = 'active'
         AND participant.ready_media_epoch = call.media_epoch
         AND epoch.membership_revision = call.membership_revision,
       FALSE, FALSE, 1, 0, now()
FROM group_call_participants participant
JOIN group_calls call ON call.id = participant.call_id
JOIN group_call_epochs epoch ON epoch.call_id = call.id AND epoch.epoch = call.media_epoch
WHERE call.state = 'active' AND participant.status IN ('pending_key','active')
ON CONFLICT (call_id, participant_identity) DO NOTHING;

-- Immutable rows make start/join abuse budgets survive process restarts and cancelled rooms.
CREATE TABLE IF NOT EXISTS group_call_action_budgets (
  id          BIGSERIAL PRIMARY KEY,
  account_id  UUID NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  device_id   UUID NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
  action      TEXT NOT NULL CHECK (action IN ('start','join','camera_publish','screen_share')),
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS group_call_action_budgets_window_idx
  ON group_call_action_budgets(account_id, action, created_at DESC);
CREATE INDEX IF NOT EXISTS group_call_action_budgets_retention_idx
  ON group_call_action_budgets(created_at, id);

-- Attempts survive cancelled/expired call cleanup so repeated invite/cancel loops remain limited.
CREATE TABLE IF NOT EXISTS call_invite_attempts (
  id                BIGSERIAL PRIMARY KEY,
  caller_account_id UUID NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  callee_account_id UUID NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  caller_device_id  UUID NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
  network_hash      BYTEA,
  created_at        TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS call_invite_attempts_caller_idx
  ON call_invite_attempts(caller_account_id, created_at DESC);
CREATE INDEX IF NOT EXISTS call_invite_attempts_callee_idx
  ON call_invite_attempts(callee_account_id, created_at DESC);
CREATE INDEX IF NOT EXISTS call_invite_attempts_network_idx
  ON call_invite_attempts(network_hash, created_at DESC) WHERE network_hash IS NOT NULL;
ALTER TABLE call_invite_attempts ADD COLUMN IF NOT EXISTS network_key_id TEXT DEFAULT 'legacy-v1';
ALTER TABLE call_invite_attempts ALTER COLUMN network_key_id SET DEFAULT 'legacy-v1';
DO $$ BEGIN
  ALTER TABLE call_invite_attempts ADD CONSTRAINT call_invite_attempts_network_hash_key_check
    CHECK (network_hash IS NULL OR network_key_id IS NOT NULL) NOT VALID;
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;
CREATE INDEX IF NOT EXISTS call_invite_attempts_retention_idx ON call_invite_attempts(created_at);

CREATE TABLE IF NOT EXISTS voip_push_deliveries (
  id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  call_id           UUID NOT NULL REFERENCES calls(id) ON DELETE CASCADE,
  caller_account_id UUID NOT NULL REFERENCES accounts(id),
  initial_kind      TEXT NOT NULL DEFAULT 'voice'
                      CHECK (initial_kind IN ('voice','video')),
  device_id         UUID NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
  status            TEXT NOT NULL DEFAULT 'pending'
                      CHECK (status IN ('pending','sending','sent','dead')),
  attempts          INT NOT NULL DEFAULT 0,
  available_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  claimed_at        TIMESTAMPTZ,
  expires_at        TIMESTAMPTZ NOT NULL,
  apns_id           TEXT,
  last_error        TEXT,
  created_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
  sent_at           TIMESTAMPTZ,
  UNIQUE (call_id, device_id)
);
ALTER TABLE voip_push_deliveries ADD COLUMN IF NOT EXISTS initial_kind TEXT NOT NULL DEFAULT 'voice';
DO $$ BEGIN
  ALTER TABLE voip_push_deliveries ADD CONSTRAINT voip_push_deliveries_initial_kind_check
    CHECK (initial_kind IN ('voice','video'));
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;
CREATE INDEX IF NOT EXISTS voip_push_deliveries_ready_idx
  ON voip_push_deliveries(available_at, created_at) WHERE status IN ('pending','sending');
CREATE INDEX IF NOT EXISTS voip_push_deliveries_retention_idx
  ON voip_push_deliveries(created_at) WHERE status IN ('sent','dead');

-- Credential secrets are never stored. This table is a short-lived allocation/abuse audit only.
CREATE TABLE IF NOT EXISTS turn_allocations (
  id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  call_id    UUID NOT NULL REFERENCES calls(id) ON DELETE CASCADE,
  account_id UUID NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  username   TEXT NOT NULL,
  expires_at TIMESTAMPTZ NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (call_id, account_id, username)
);
CREATE INDEX IF NOT EXISTS turn_allocations_expiry_idx ON turn_allocations(expires_at);
CREATE INDEX IF NOT EXISTS turn_allocations_account_expiry_idx
  ON turn_allocations(account_id, expires_at);

-- ============ resumable bootstrap (B1/I2): snapshot token + per-dialog ceilings ============
CREATE TABLE IF NOT EXISTS bootstrap_snapshots (
  id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  account_id   UUID NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  snapshot_pts BIGINT NOT NULL,
  expires_at   TIMESTAMPTZ NOT NULL DEFAULT (now() + interval '30 minutes'),
  created_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS bootstrap_snapshots_account_active_idx
  ON bootstrap_snapshots(account_id, expires_at);

CREATE TABLE IF NOT EXISTS bootstrap_snapshot_dialogs (
  snapshot_id     UUID NOT NULL REFERENCES bootstrap_snapshots(id) ON DELETE CASCADE,
  dialog_id       UUID NOT NULL REFERENCES dialogs(id) ON DELETE CASCADE,
  ceiling_msg_id  BIGINT NOT NULL,
  sort_updated_at TIMESTAMPTZ NOT NULL,
  PRIMARY KEY (snapshot_id, dialog_id)
);
CREATE INDEX IF NOT EXISTS bootstrap_snapshot_dialogs_page_idx
  ON bootstrap_snapshot_dialogs(snapshot_id, sort_updated_at DESC, dialog_id DESC);

-- ============ compliance (append-only audit) ============
CREATE TABLE IF NOT EXISTS content_access_audit (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  actor_kind  TEXT NOT NULL,                          -- 'system'|'support'|'legal'|'moderation'
  actor_id    TEXT,
  account_id  UUID,
  dialog_id   UUID,
  msg_id      BIGINT,
  reason      TEXT NOT NULL,
  request_id  TEXT,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE OR REPLACE FUNCTION public.toj_content_access_audit_append_only_v1()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE
  retention_owner NAME;
BEGIN
  SELECT pg_get_userbyid(proowner) INTO retention_owner
  FROM pg_proc WHERE oid = 'public.toj_cleanup_abuse_reports_v1(integer)'::regprocedure;
  IF TG_OP = 'DELETE'
     AND current_user = retention_owner
     AND current_setting('toj.allow_content_access_retention_delete', TRUE) = '1' THEN
    RETURN OLD;
  END IF;
  RAISE EXCEPTION 'content_access_audit is append-only';
END;
$$;
DROP TRIGGER IF EXISTS content_access_audit_append_only ON content_access_audit;
CREATE TRIGGER content_access_audit_append_only
  BEFORE UPDATE OR DELETE ON content_access_audit
  FOR EACH ROW EXECUTE FUNCTION public.toj_content_access_audit_append_only_v1();

-- The private-beta scaffold remains untouched. It was never exposed by a route and its loose
-- contract cannot safely be upgraded into the strict, idempotent moderation workflow in place.
CREATE TABLE IF NOT EXISTS user_reports (
  id                          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  reporter_account_id         UUID NOT NULL REFERENCES accounts(id),
  reported_account_id         UUID REFERENCES accounts(id),
  dialog_id                   UUID,
  msg_id                      BIGINT,
  reason                      TEXT NOT NULL,
  message_snapshot_key_id     TEXT,
  message_snapshot_nonce      BYTEA,
  message_snapshot_ciphertext BYTEA,
  created_at                  TIMESTAMPTZ NOT NULL DEFAULT now(),
  resolved_at                 TIMESTAMPTZ
);

CREATE TABLE IF NOT EXISTS abuse_reports (
  id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  reporter_account_id UUID NOT NULL REFERENCES accounts(id),
  client_report_id    UUID NOT NULL,
  request_fingerprint BYTEA NOT NULL CHECK (octet_length(request_fingerprint) = 32),
  fingerprint_key_id TEXT NOT NULL DEFAULT 'legacy-v1',
  dialog_id           UUID NOT NULL,
  subject_type        TEXT NOT NULL CHECK (subject_type IN ('account','message')),
  reported_account_id UUID NOT NULL REFERENCES accounts(id),
  msg_id              BIGINT,
  reason              TEXT NOT NULL CHECK (reason IN (
                        'spam','scam','harassment','violence','sexual_content',
                        'child_safety','other'
                      )),
  priority            TEXT NOT NULL CHECK (priority IN ('urgent','standard')),
  status              TEXT NOT NULL DEFAULT 'open' CHECK (status IN ('open','in_review','resolved')),
  evidence_key_id     TEXT,
  evidence_nonce      BYTEA,
  evidence_ciphertext BYTEA,
  evidence_plain_size INT CHECK (evidence_plain_size IS NULL OR evidence_plain_size BETWEEN 1 AND 262144),
  claimed_by          TEXT,
  claimed_at          TIMESTAMPTZ,
  resolution          TEXT CHECK (resolution IS NULL OR resolution IN (
                        'resolved','dismissed','content_removed','account_banned'
                      )),
  created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
  resolved_at         TIMESTAMPTZ,
  evidence_expires_at TIMESTAMPTZ,
  audit_expires_at    TIMESTAMPTZ,
  UNIQUE (reporter_account_id, client_report_id),
  CHECK (
    (subject_type = 'account' AND reported_account_id IS NOT NULL AND msg_id IS NULL)
    OR (subject_type = 'message' AND reported_account_id IS NOT NULL AND msg_id IS NOT NULL)
  ),
  CHECK (
    (status = 'resolved' AND resolved_at IS NOT NULL AND resolution IS NOT NULL
      AND evidence_expires_at IS NOT NULL AND audit_expires_at IS NOT NULL)
    OR (status <> 'resolved' AND resolved_at IS NULL AND resolution IS NULL)
  )
);
ALTER TABLE abuse_reports ALTER COLUMN reported_account_id SET NOT NULL;
ALTER TABLE abuse_reports ALTER COLUMN client_report_id SET NOT NULL;
ALTER TABLE abuse_reports ALTER COLUMN request_fingerprint SET NOT NULL;
ALTER TABLE abuse_reports ALTER COLUMN dialog_id SET NOT NULL;
ALTER TABLE abuse_reports ALTER COLUMN subject_type SET NOT NULL;
ALTER TABLE abuse_reports ALTER COLUMN priority SET NOT NULL;

CREATE UNIQUE INDEX IF NOT EXISTS abuse_reports_idempotency_idx
  ON abuse_reports(reporter_account_id, client_report_id);
CREATE INDEX IF NOT EXISTS abuse_reports_open_priority_idx
  ON abuse_reports(priority, created_at) WHERE status <> 'resolved';
CREATE INDEX IF NOT EXISTS abuse_reports_target_history_idx
  ON abuse_reports(reported_account_id, created_at DESC);
CREATE INDEX IF NOT EXISTS abuse_reports_evidence_retention_idx
  ON abuse_reports(evidence_expires_at) WHERE evidence_ciphertext IS NOT NULL;
CREATE INDEX IF NOT EXISTS abuse_reports_audit_retention_idx
  ON abuse_reports(audit_expires_at) WHERE status = 'resolved';

CREATE TABLE IF NOT EXISTS abuse_report_submission_budgets (
  id                  BIGSERIAL PRIMARY KEY,
  reporter_account_id UUID NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  accepted_at         TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS abuse_report_submission_budgets_account_idx
  ON abuse_report_submission_budgets(reporter_account_id, accepted_at DESC);

CREATE TABLE IF NOT EXISTS abuse_report_actions (
  id              BIGSERIAL PRIMARY KEY,
  report_id       UUID NOT NULL REFERENCES abuse_reports(id) ON DELETE CASCADE,
  actor_kind      TEXT NOT NULL CHECK (actor_kind IN ('system','moderation')),
  actor_id        TEXT,
  action          TEXT NOT NULL CHECK (action IN (
                    'created','claimed','resolved','dismissed','content_removed',
                    'account_banned','escalated'
                  )),
  note_key_id     TEXT,
  note_nonce      BYTEA,
  note_ciphertext BYTEA,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  CHECK (
    (note_key_id IS NULL AND note_nonce IS NULL AND note_ciphertext IS NULL)
    OR (note_key_id IS NOT NULL AND note_nonce IS NOT NULL AND note_ciphertext IS NOT NULL)
  )
);
CREATE INDEX IF NOT EXISTS abuse_report_actions_report_idx
  ON abuse_report_actions(report_id, created_at, id);

CREATE OR REPLACE FUNCTION public.toj_abuse_report_actions_append_only_v1()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE
  table_owner NAME;
  retention_owner NAME;
BEGIN
  SELECT pg_get_userbyid(relowner) INTO table_owner FROM pg_class WHERE oid = TG_RELID;
  SELECT pg_get_userbyid(proowner) INTO retention_owner
  FROM pg_proc WHERE oid = 'public.toj_cleanup_abuse_reports_v1(integer)'::regprocedure;
  IF TG_OP = 'UPDATE'
     AND current_user = table_owner
     AND current_setting('toj.allow_abuse_report_crypto_migration', TRUE) = '1'
     AND ROW(NEW.id, NEW.report_id, NEW.actor_kind, NEW.actor_id, NEW.action, NEW.created_at)
         IS NOT DISTINCT FROM
         ROW(OLD.id, OLD.report_id, OLD.actor_kind, OLD.actor_id, OLD.action, OLD.created_at) THEN
    -- Key rotation may replace only the encrypted-note tuple. The audit identity,
    -- actor, action, ordering, and timestamp remain immutable.
    RETURN NEW;
  END IF;
  IF TG_OP = 'DELETE'
     AND current_user = retention_owner
     AND current_setting('toj.allow_abuse_report_retention_delete', TRUE) = '1' THEN
    RETURN OLD;
  END IF;
  RAISE EXCEPTION 'abuse_report_actions is append-only';
END;
$$;
DROP TRIGGER IF EXISTS abuse_report_actions_append_only ON abuse_report_actions;
CREATE TRIGGER abuse_report_actions_append_only
  BEFORE UPDATE OR DELETE ON abuse_report_actions
  FOR EACH ROW EXECUTE FUNCTION public.toj_abuse_report_actions_append_only_v1();

-- Runtime roles receive EXECUTE on this bounded SECURITY DEFINER function, never direct mutation
-- rights on either audit table. The effective-owner checks above make caller-set GUCs insufficient.
CREATE OR REPLACE FUNCTION public.toj_cleanup_abuse_reports_v1(requested_batch_size INTEGER)
RETURNS TABLE(evidence INTEGER, reports INTEGER, budgets INTEGER, access_audits INTEGER)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  bounded_batch INTEGER := GREATEST(1, LEAST(10000, requested_batch_size));
  evidence_count INTEGER := 0;
  report_count INTEGER := 0;
  budget_count INTEGER := 0;
  access_count INTEGER := 0;
BEGIN
  WITH doomed AS (
    SELECT id FROM public.abuse_reports
    WHERE evidence_ciphertext IS NOT NULL AND evidence_expires_at <= now()
    ORDER BY evidence_expires_at LIMIT bounded_batch FOR UPDATE SKIP LOCKED
  )
  UPDATE public.abuse_reports report
  SET evidence_key_id = NULL, evidence_nonce = NULL,
      evidence_ciphertext = NULL, evidence_plain_size = NULL
  FROM doomed WHERE report.id = doomed.id;
  GET DIAGNOSTICS evidence_count = ROW_COUNT;

  PERFORM set_config('toj.allow_content_access_retention_delete', '1', TRUE);
  WITH doomed AS (
    SELECT audit.id FROM public.content_access_audit audit
    WHERE audit.reason LIKE 'abuse_report.%'
      AND audit.created_at < now() - interval '365 days'
      AND NOT EXISTS (
        SELECT 1 FROM public.abuse_reports report
        WHERE report.id::text = audit.request_id
          AND (report.status <> 'resolved' OR report.audit_expires_at > now())
      )
    ORDER BY audit.created_at, audit.id LIMIT bounded_batch FOR UPDATE SKIP LOCKED
  )
  DELETE FROM public.content_access_audit audit USING doomed WHERE audit.id = doomed.id;
  GET DIAGNOSTICS access_count = ROW_COUNT;

  PERFORM set_config('toj.allow_abuse_report_retention_delete', '1', TRUE);
  WITH doomed AS (
    SELECT id FROM public.abuse_reports
    WHERE status = 'resolved' AND audit_expires_at <= now()
    ORDER BY audit_expires_at, id LIMIT bounded_batch FOR UPDATE SKIP LOCKED
  )
  DELETE FROM public.abuse_reports report USING doomed WHERE report.id = doomed.id;
  GET DIAGNOSTICS report_count = ROW_COUNT;

  WITH doomed AS (
    SELECT id FROM public.abuse_report_submission_budgets
    WHERE accepted_at < now() - interval '24 hours'
    ORDER BY accepted_at, id LIMIT bounded_batch FOR UPDATE SKIP LOCKED
  )
  DELETE FROM public.abuse_report_submission_budgets budget
  USING doomed WHERE budget.id = doomed.id;
  GET DIAGNOSTICS budget_count = ROW_COUNT;

  RETURN QUERY SELECT evidence_count, report_count, budget_count, access_count;
END;
$$;
REVOKE ALL ON FUNCTION public.toj_cleanup_abuse_reports_v1(INTEGER) FROM PUBLIC;
