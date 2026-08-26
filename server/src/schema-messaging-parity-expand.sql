-- Expand phase for independently gated messaging-parity features.
-- This file is intentionally additive: old API-v6 processes can keep serving while it is applied.
SET lock_timeout = '5s';
SET statement_timeout = '30s';

ALTER TABLE dialogs ADD COLUMN IF NOT EXISTS auto_delete_seconds INT;
DO $$ BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'dialogs_auto_delete_seconds_check'
  ) THEN
    ALTER TABLE dialogs ADD CONSTRAINT dialogs_auto_delete_seconds_check
      CHECK (auto_delete_seconds IS NULL OR auto_delete_seconds BETWEEN 3600 AND 31536000)
      NOT VALID;
  END IF;
END $$;

-- expires_at is stamped when a send is accepted. It is never recomputed when the dialog timer
-- changes, and the read fence must remain active even if creation/configuration is disabled.
ALTER TABLE messages ADD COLUMN IF NOT EXISTS expires_at TIMESTAMPTZ;

DO $$ BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM schema_migrations WHERE name = 'messages-domain-constraints-v3'
  ) AND NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'messages_kind_check_v3'
  ) THEN
    ALTER TABLE messages ADD CONSTRAINT messages_kind_check_v3
      CHECK (kind IN (
        'text','photo','video','file','voice','service','poll','sticker','external_media'
      )) NOT VALID;
    ALTER TABLE messages ADD CONSTRAINT messages_service_type_check_v3 CHECK (
      service_type IS NULL OR service_type IN (
        'group.created','member.added','member.removed','member.role_changed','member.left',
        'dialog.title_changed','dialog.photo_changed','dialog.owner_transferred','dialog.closed',
        'call.completed','call.declined','call.missed','call.busy','call.cancelled','call.failed',
        'message.pinned','message.unpinned','dialog.auto_delete_changed','poll.closed'
      )
    ) NOT VALID;
  END IF;
END $$;

DO $$ BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM schema_migrations WHERE name = 'account-events-type-v7'
  ) AND NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'account_events_type_check_v7'
  ) THEN
    ALTER TABLE account_events ADD CONSTRAINT account_events_type_check_v7 CHECK (type IN (
      'message.new','message.edited','message.deleted','message.expired','message.preview_updated',
      'reaction.updated','read.updated',
      'dialog.created','member.added','member.removed','member.role_changed','member.left',
      'dialog.profile_updated','dialog.closed','dialog.access_revoked','dialog.preferences_updated',
      'profile.updated','draft.updated','security.changed','chat_folders.updated',
      'scheduled.created','scheduled.updated','scheduled.canceled','scheduled.failed',
      'pin.updated','dialog.auto_delete_updated','poll.updated','sticker_preferences.updated'
    )) NOT VALID;
  END IF;
END $$;

-- One row per shared pin. Message deletion is soft, so application mutations remove the row in the
-- same transaction; the FK is a final safety net for hard dialog/message deletion.
CREATE TABLE IF NOT EXISTS message_pins (
  dialog_id            UUID NOT NULL,
  msg_id               BIGINT NOT NULL,
  pinned_by_account_id UUID NOT NULL REFERENCES accounts(id),
  notify_members       BOOLEAN NOT NULL DEFAULT FALSE,
  created_at           TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (dialog_id, msg_id),
  FOREIGN KEY (dialog_id, msg_id)
    REFERENCES messages(dialog_id, msg_id) ON DELETE CASCADE
);

-- The poll's question, options, correct option, and explanation live in one AEAD payload. Mode
-- columns remain relational so authorization/counting does not require decrypting every poll.
CREATE TABLE IF NOT EXISTS message_polls (
  dialog_id          UUID NOT NULL,
  msg_id             BIGINT NOT NULL,
  payload_key_id     TEXT NOT NULL,
  payload_nonce      BYTEA NOT NULL,
  payload_ciphertext BYTEA NOT NULL,
  option_count       SMALLINT NOT NULL CHECK (option_count BETWEEN 2 AND 10),
  multiple_choice    BOOLEAN NOT NULL DEFAULT FALSE,
  anonymous          BOOLEAN NOT NULL DEFAULT TRUE,
  quiz               BOOLEAN NOT NULL DEFAULT FALSE,
  closed_at          TIMESTAMPTZ,
  closed_by_account_id UUID REFERENCES accounts(id),
  created_at         TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (dialog_id, msg_id),
  FOREIGN KEY (dialog_id, msg_id)
    REFERENCES messages(dialog_id, msg_id) ON DELETE CASCADE,
  CHECK (NOT quiz OR NOT multiple_choice)
);

-- A single voter row makes replacement/retraction atomic and coalescible. option_indices remains a
-- relational array (never JSON) and is validated against option_count while the poll row is locked.
CREATE TABLE IF NOT EXISTS poll_votes (
  dialog_id       UUID NOT NULL,
  msg_id          BIGINT NOT NULL,
  voter_account_id UUID NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  option_indices  SMALLINT[] NOT NULL,
  locked          BOOLEAN NOT NULL DEFAULT FALSE,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (dialog_id, msg_id, voter_account_id),
  FOREIGN KEY (dialog_id, msg_id)
    REFERENCES message_polls(dialog_id, msg_id) ON DELETE CASCADE,
  CHECK (cardinality(option_indices) BETWEEN 1 AND 10)
);

-- Typed sticker/GIPHY references contain identifiers and bounded rendition hints only. GIF bytes
-- and search terms are never persisted by Toj.
CREATE TABLE IF NOT EXISTS message_external_content (
  dialog_id       UUID NOT NULL,
  msg_id          BIGINT NOT NULL,
  provider        TEXT NOT NULL CHECK (provider IN ('toj_sticker','giphy')),
  provider_item_id TEXT NOT NULL CHECK (char_length(provider_item_id) BETWEEN 1 AND 200),
  pack_id         TEXT,
  rendition       JSONB NOT NULL DEFAULT '{}'::jsonb,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (dialog_id, msg_id),
  FOREIGN KEY (dialog_id, msg_id)
    REFERENCES messages(dialog_id, msg_id) ON DELETE CASCADE,
  CHECK (pg_column_size(rendition) <= 2048)
);

CREATE TABLE IF NOT EXISTS sticker_packs (
  id              TEXT PRIMARY KEY CHECK (char_length(id) BETWEEN 1 AND 100),
  version         INT NOT NULL CHECK (version > 0),
  title           TEXT NOT NULL CHECK (char_length(title) BETWEEN 1 AND 100),
  status          TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active','withdrawn')),
  manifest_sha256 BYTEA NOT NULL CHECK (octet_length(manifest_sha256) = 32),
  updated_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS stickers (
  id           TEXT PRIMARY KEY CHECK (char_length(id) BETWEEN 1 AND 160),
  pack_id      TEXT NOT NULL REFERENCES sticker_packs(id) ON DELETE CASCADE,
  pack_version INT NOT NULL CHECK (pack_version > 0),
  format       TEXT NOT NULL CHECK (format IN ('png','apng')),
  mime_type    TEXT NOT NULL CHECK (mime_type IN ('image/png','image/apng')),
  byte_size    INT NOT NULL CHECK (byte_size BETWEEN 1 AND 2097152),
  width        INT NOT NULL CHECK (width BETWEEN 1 AND 512),
  height       INT NOT NULL CHECK (height BETWEEN 1 AND 512),
  sha256       BYTEA NOT NULL CHECK (octet_length(sha256) = 32),
  asset_url    TEXT NOT NULL CHECK (asset_url ~ '^https://'),
  emoji        TEXT[] NOT NULL DEFAULT ARRAY[]::TEXT[],
  tags         TEXT[] NOT NULL DEFAULT ARRAY[]::TEXT[],
  status       TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active','withdrawn')),
  updated_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (pack_id, id)
);

CREATE TABLE IF NOT EXISTS account_sticker_packs (
  account_id UUID NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  pack_id    TEXT NOT NULL REFERENCES sticker_packs(id) ON DELETE CASCADE,
  installed_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (account_id, pack_id)
);

CREATE TABLE IF NOT EXISTS account_sticker_favorites (
  account_id UUID NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  sticker_id TEXT NOT NULL REFERENCES stickers(id) ON DELETE CASCADE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (account_id, sticker_id)
);

CREATE TABLE IF NOT EXISTS account_sticker_recents (
  account_id UUID NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  sticker_id TEXT NOT NULL REFERENCES stickers(id) ON DELETE CASCADE,
  use_count  INT NOT NULL DEFAULT 1 CHECK (use_count > 0),
  last_used_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (account_id, sticker_id)
);

-- Durable idempotency receipts for non-send mutations. Fingerprints prevent a reused UUID from
-- changing meaning after a network timeout.
CREATE TABLE IF NOT EXISTS messaging_feature_mutations (
  actor_account_id UUID NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  operation_id     UUID NOT NULL,
  operation        TEXT NOT NULL CHECK (operation IN (
    'pin','unpin','set_auto_delete','poll_vote','poll_close',
    'sticker_install','sticker_remove','sticker_favorite','sticker_unfavorite'
  )),
  dialog_id        UUID,
  msg_id           BIGINT,
  payload_fingerprint BYTEA NOT NULL CHECK (octet_length(payload_fingerprint) = 32),
  fingerprint_key_id TEXT NOT NULL DEFAULT 'legacy-v1',
  response         JSONB,
  completed_at     TIMESTAMPTZ,
  created_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (actor_account_id, operation_id),
  CHECK ((completed_at IS NULL AND response IS NULL) OR completed_at IS NOT NULL)
);
ALTER TABLE messaging_feature_mutations ADD COLUMN IF NOT EXISTS fingerprint_key_id
  TEXT NOT NULL DEFAULT 'legacy-v1';

-- One APNs/VoIP endpoint per installation, with up to three account/device bindings. Payloads use
-- routing_handle; neither phone numbers nor account UUIDs need to leave APNs.
CREATE TABLE IF NOT EXISTS push_installations (
  installation_id       UUID PRIMARY KEY,
  normal_token_hash     BYTEA,
  normal_token_hash_key_id TEXT DEFAULT 'legacy-v1',
  normal_token_ciphertext BYTEA,
  normal_token_nonce    BYTEA,
  normal_token_key_id   TEXT,
  normal_environment    TEXT CHECK (normal_environment IN ('sandbox','production')),
  voip_token_hash       BYTEA,
  voip_token_hash_key_id TEXT DEFAULT 'legacy-v1',
  voip_token_ciphertext BYTEA,
  voip_token_nonce      BYTEA,
  voip_token_key_id     TEXT,
  voip_environment      TEXT CHECK (voip_environment IN ('sandbox','production')),
  created_at            TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at            TIMESTAMPTZ NOT NULL DEFAULT now(),
  CHECK (
    (normal_token_hash IS NULL AND normal_token_ciphertext IS NULL AND normal_token_nonce IS NULL
      AND normal_token_key_id IS NULL AND normal_environment IS NULL)
    OR
    (normal_token_hash IS NOT NULL AND normal_token_ciphertext IS NOT NULL AND normal_token_nonce IS NOT NULL
      AND normal_token_key_id IS NOT NULL AND normal_environment IS NOT NULL)
  ),
  CHECK (
    (voip_token_hash IS NULL AND voip_token_ciphertext IS NULL AND voip_token_nonce IS NULL
      AND voip_token_key_id IS NULL AND voip_environment IS NULL)
    OR
    (voip_token_hash IS NOT NULL AND voip_token_ciphertext IS NOT NULL AND voip_token_nonce IS NOT NULL
      AND voip_token_key_id IS NOT NULL AND voip_environment IS NOT NULL)
  )
);
ALTER TABLE push_installations ADD COLUMN IF NOT EXISTS normal_token_hash_key_id
  TEXT DEFAULT 'legacy-v1';
ALTER TABLE push_installations ADD COLUMN IF NOT EXISTS voip_token_hash_key_id
  TEXT DEFAULT 'legacy-v1';
DO $$ BEGIN
  ALTER TABLE push_installations ADD CONSTRAINT push_installations_normal_hash_key_check
    CHECK (normal_token_hash IS NULL OR normal_token_hash_key_id IS NOT NULL) NOT VALID;
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;
DO $$ BEGIN
  ALTER TABLE push_installations ADD CONSTRAINT push_installations_voip_hash_key_check
    CHECK (voip_token_hash IS NULL OR voip_token_hash_key_id IS NOT NULL) NOT VALID;
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

CREATE TABLE IF NOT EXISTS push_account_bindings (
  installation_id UUID NOT NULL REFERENCES push_installations(installation_id) ON DELETE CASCADE,
  account_id       UUID NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  device_id        UUID NOT NULL UNIQUE REFERENCES devices(id) ON DELETE CASCADE,
  routing_handle   UUID NOT NULL UNIQUE DEFAULT gen_random_uuid(),
  active           BOOLEAN NOT NULL DEFAULT TRUE,
  normal_enabled   BOOLEAN NOT NULL DEFAULT FALSE,
  voip_enabled     BOOLEAN NOT NULL DEFAULT FALSE,
  created_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (installation_id, account_id)
);

ALTER TABLE push_account_bindings
  ADD COLUMN IF NOT EXISTS normal_enabled BOOLEAN NOT NULL DEFAULT FALSE;
ALTER TABLE push_account_bindings
  ADD COLUMN IF NOT EXISTS voip_enabled BOOLEAN NOT NULL DEFAULT FALSE;

-- Upgrade the first internal schema draft without repeatedly re-enabling a kind that a newer
-- client intentionally disabled.
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM schema_migrations WHERE name = 'push-binding-kind-flags-v1'
  ) THEN
    UPDATE push_account_bindings binding
    SET normal_enabled = installation.normal_token_ciphertext IS NOT NULL,
        voip_enabled = installation.voip_token_ciphertext IS NOT NULL
    FROM push_installations installation
    WHERE installation.installation_id = binding.installation_id;
    INSERT INTO schema_migrations(name) VALUES ('push-binding-kind-flags-v1');
  END IF;
END $$;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conrelid = 'push_account_bindings'::regclass
      AND conname = 'push_account_bindings_enabled_check'
  ) THEN
    ALTER TABLE push_account_bindings
      ADD CONSTRAINT push_account_bindings_enabled_check
      CHECK (NOT active OR normal_enabled OR voip_enabled) NOT VALID;
  END IF;
END $$;

CREATE OR REPLACE FUNCTION enforce_push_installation_account_limit()
RETURNS TRIGGER LANGUAGE plpgsql
SET search_path = pg_catalog, public, pg_temp
AS $$
BEGIN
  -- Lock the parent so concurrent raw SQL writers cannot both observe fewer than three bindings.
  PERFORM 1 FROM push_installations
  WHERE installation_id = NEW.installation_id
  FOR UPDATE;
  IF NEW.active AND (
    SELECT count(*) FROM push_account_bindings
    WHERE installation_id = NEW.installation_id AND active
      -- ON CONFLICT runs BEFORE INSERT triggers before it resolves the existing row. Excluding
      -- the incoming account makes same-account token rotation idempotent while a fourth distinct
      -- account still observes all three existing bindings and is rejected.
      AND account_id <> NEW.account_id
  ) >= 3 THEN
    RAISE EXCEPTION 'installation may bind at most three active accounts'
      USING ERRCODE = 'check_violation';
  END IF;
  RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS push_installation_account_limit ON push_account_bindings;
CREATE TRIGGER push_installation_account_limit
BEFORE INSERT OR UPDATE OF active, installation_id ON push_account_bindings
FOR EACH ROW EXECUTE FUNCTION enforce_push_installation_account_limit();

INSERT INTO schema_migrations(name) VALUES ('messaging-parity-expand-v1')
ON CONFLICT (name) DO NOTHING;
