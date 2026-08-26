\set ON_ERROR_STOP on

-- Dark schema for cloud chat folders, durable scheduled delivery, and asynchronous
-- link previews. This phase is safe with old application binaries: no existing table
-- changes behavior until the event constraint is validated and the capability gates open.
BEGIN;
SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '30s';

CREATE TABLE IF NOT EXISTS account_chat_folder_states (
  account_id UUID PRIMARY KEY REFERENCES accounts(id) ON DELETE CASCADE,
  revision BIGINT NOT NULL DEFAULT 0 CHECK (revision >= 0),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS chat_folders (
  account_id UUID NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  folder_id UUID NOT NULL,
  title_key_id TEXT NOT NULL,
  title_nonce BYTEA NOT NULL CHECK (octet_length(title_nonce) = 12),
  title_ciphertext BYTEA NOT NULL,
  icon TEXT NOT NULL CHECK (icon IN (
    'folder','unread','personal','groups','muted','work','family','favorite'
  )),
  position SMALLINT NOT NULL CHECK (position BETWEEN 0 AND 9),
  include_direct BOOLEAN NOT NULL DEFAULT TRUE,
  include_groups BOOLEAN NOT NULL DEFAULT TRUE,
  include_saved BOOLEAN NOT NULL DEFAULT TRUE,
  exclude_read BOOLEAN NOT NULL DEFAULT FALSE,
  exclude_muted BOOLEAN NOT NULL DEFAULT FALSE,
  exclude_archived BOOLEAN NOT NULL DEFAULT FALSE,
  revision BIGINT NOT NULL CHECK (revision > 0),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (account_id, folder_id),
  CONSTRAINT chat_folders_position_unique
    UNIQUE (account_id, position) DEFERRABLE INITIALLY DEFERRED
);

CREATE TABLE IF NOT EXISTS chat_folder_dialog_rules (
  account_id UUID NOT NULL,
  folder_id UUID NOT NULL,
  dialog_id UUID NOT NULL REFERENCES dialogs(id) ON DELETE CASCADE,
  rule TEXT NOT NULL CHECK (rule IN ('include','exclude')),
  PRIMARY KEY (account_id, folder_id, dialog_id),
  FOREIGN KEY (account_id, folder_id)
    REFERENCES chat_folders(account_id, folder_id) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS chat_folder_mutation_requests (
  account_id UUID NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  client_mutation_id UUID NOT NULL,
  folder_id UUID NOT NULL,
  operation TEXT NOT NULL CHECK (operation IN ('create','update','move','delete')),
  fingerprint BYTEA NOT NULL CHECK (octet_length(fingerprint) = 32),
  request_fingerprint BYTEA,
  fingerprint_key_id TEXT NOT NULL DEFAULT 'legacy-v1',
  status TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','completed')),
  result_revision BIGINT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (account_id, client_mutation_id),
  CHECK (
    (status = 'pending' AND result_revision IS NULL)
    OR (status = 'completed' AND result_revision IS NOT NULL)
  )
);

CREATE TABLE IF NOT EXISTS chat_folder_action_budgets (
  account_id UUID NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  bucket_started TIMESTAMPTZ NOT NULL,
  mutation_count INT NOT NULL DEFAULT 0 CHECK (mutation_count BETWEEN 0 AND 240),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (account_id, bucket_started)
);

CREATE TABLE IF NOT EXISTS account_scheduled_delivery_states (
  account_id UUID PRIMARY KEY REFERENCES accounts(id) ON DELETE CASCADE,
  revision BIGINT NOT NULL DEFAULT 0 CHECK (revision >= 0),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS scheduled_deliveries (
  id UUID PRIMARY KEY,
  account_id UUID NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  origin_device_id UUID REFERENCES devices(id) ON DELETE SET NULL,
  dialog_id UUID NOT NULL REFERENCES dialogs(id) ON DELETE CASCADE,
  deliver_at TIMESTAMPTZ NOT NULL,
  available_at TIMESTAMPTZ NOT NULL,
  state TEXT NOT NULL DEFAULT 'scheduled' CHECK (
    state IN ('scheduled','processing','delivered','failed','canceled')
  ),
  silent BOOLEAN NOT NULL DEFAULT FALSE,
  reminder BOOLEAN NOT NULL DEFAULT FALSE,
  revision BIGINT NOT NULL CHECK (revision > 0),
  attempts INT NOT NULL DEFAULT 0 CHECK (attempts >= 0),
  claimed_at TIMESTAMPTZ,
  lease_expires_at TIMESTAMPTZ,
  lease_token UUID,
  last_error_code TEXT,
  delivered_first_msg_id BIGINT,
  delivered_last_msg_id BIGINT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  completed_at TIMESTAMPTZ,
  CHECK (
    (state = 'processing' AND claimed_at IS NOT NULL
      AND lease_expires_at IS NOT NULL AND lease_token IS NOT NULL)
    OR state <> 'processing'
  )
);

CREATE TABLE IF NOT EXISTS scheduled_delivery_items (
  delivery_id UUID NOT NULL REFERENCES scheduled_deliveries(id) ON DELETE CASCADE,
  item_index SMALLINT NOT NULL CHECK (item_index BETWEEN 0 AND 9),
  client_msg_id UUID NOT NULL,
  kind TEXT NOT NULL CHECK (kind IN ('text','photo','video','file','voice')),
  payload_key_id TEXT,
  payload_nonce BYTEA,
  payload_ciphertext BYTEA,
  media_id UUID REFERENCES media_objects(id),
  PRIMARY KEY (delivery_id, item_index),
  UNIQUE (client_msg_id),
  CHECK (
    (payload_key_id IS NULL AND payload_nonce IS NULL AND payload_ciphertext IS NULL)
    OR (payload_key_id IS NOT NULL AND payload_nonce IS NOT NULL
      AND octet_length(payload_nonce) = 12 AND payload_ciphertext IS NOT NULL)
  )
);

CREATE TABLE IF NOT EXISTS scheduled_delivery_mutation_requests (
  account_id UUID NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  client_mutation_id UUID NOT NULL,
  delivery_id UUID NOT NULL,
  operation TEXT NOT NULL CHECK (operation IN ('create','update','reschedule','cancel')),
  expected_revision BIGINT,
  fingerprint BYTEA NOT NULL CHECK (octet_length(fingerprint) = 32),
  request_fingerprint BYTEA,
  fingerprint_key_id TEXT NOT NULL DEFAULT 'legacy-v1',
  status TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','completed')),
  result_revision BIGINT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (account_id, client_mutation_id),
  CHECK (
    (status = 'pending' AND result_revision IS NULL)
    OR (status = 'completed' AND result_revision IS NOT NULL)
  )
);
ALTER TABLE scheduled_delivery_mutation_requests
  ADD COLUMN IF NOT EXISTS request_fingerprint BYTEA;
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'scheduled_delivery_request_fingerprint_size_check'
  ) THEN
    ALTER TABLE scheduled_delivery_mutation_requests
      ADD CONSTRAINT scheduled_delivery_request_fingerprint_size_check
      CHECK (request_fingerprint IS NULL OR octet_length(request_fingerprint) = 32) NOT VALID;
  END IF;
END $$;

CREATE TABLE IF NOT EXISTS scheduled_delivery_action_budgets (
  account_id UUID NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  action TEXT NOT NULL CHECK (action IN ('write','cancel')),
  bucket_started TIMESTAMPTZ NOT NULL,
  mutation_count INT NOT NULL DEFAULT 0 CHECK (mutation_count >= 0),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (account_id, action, bucket_started)
);

CREATE TABLE IF NOT EXISTS worker_heartbeats (
  worker_kind TEXT NOT NULL CHECK (worker_kind IN ('scheduled_delivery','link_preview')),
  worker_id UUID NOT NULL,
  last_seen_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  metadata JSONB NOT NULL DEFAULT '{}'::jsonb,
  PRIMARY KEY (worker_kind, worker_id)
);

CREATE TABLE IF NOT EXISTS link_preview_assets (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  key_id TEXT NOT NULL,
  nonce BYTEA NOT NULL CHECK (octet_length(nonce) = 12),
  ciphertext BYTEA NOT NULL,
  content_type TEXT NOT NULL CHECK (content_type = 'image/jpeg'),
  byte_size INT NOT NULL CHECK (byte_size BETWEEN 1 AND 524288),
  width INT NOT NULL CHECK (width BETWEEN 1 AND 1200),
  height INT NOT NULL CHECK (height BETWEEN 1 AND 630),
  digest_hmac BYTEA NOT NULL CHECK (octet_length(digest_hmac) = 32),
  digest_key_id TEXT NOT NULL DEFAULT 'legacy-v1',
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS link_preview_snapshots (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  url_key_id TEXT NOT NULL,
  url_nonce BYTEA NOT NULL CHECK (octet_length(url_nonce) = 12),
  url_ciphertext BYTEA NOT NULL,
  metadata_key_id TEXT NOT NULL,
  metadata_nonce BYTEA NOT NULL CHECK (octet_length(metadata_nonce) = 12),
  metadata_ciphertext BYTEA NOT NULL,
  asset_id UUID REFERENCES link_preview_assets(id) ON DELETE SET NULL,
  fetched_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  expires_at TIMESTAMPTZ NOT NULL
);

CREATE TABLE IF NOT EXISTS link_preview_cache_entries (
  url_lookup_hmac BYTEA PRIMARY KEY CHECK (octet_length(url_lookup_hmac) = 32),
  url_lookup_key_id TEXT NOT NULL DEFAULT 'legacy-v1',
  url_key_id TEXT NOT NULL,
  url_nonce BYTEA NOT NULL CHECK (octet_length(url_nonce) = 12),
  url_ciphertext BYTEA NOT NULL,
  state TEXT NOT NULL DEFAULT 'pending' CHECK (
    state IN ('pending','fetching','ready','negative')
  ),
  current_snapshot_id UUID REFERENCES link_preview_snapshots(id) ON DELETE SET NULL,
  attempts INT NOT NULL DEFAULT 0 CHECK (attempts >= 0),
  available_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  claimed_at TIMESTAMPTZ,
  lease_expires_at TIMESTAMPTZ,
  lease_token UUID,
  fetched_at TIMESTAMPTZ,
  expires_at TIMESTAMPTZ,
  last_error_code TEXT,
  fanout_pending BOOLEAN NOT NULL DEFAULT FALSE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
ALTER TABLE link_preview_cache_entries
  ADD COLUMN IF NOT EXISTS fanout_pending BOOLEAN NOT NULL DEFAULT FALSE;

CREATE TABLE IF NOT EXISTS message_link_previews (
  dialog_id UUID NOT NULL,
  msg_id BIGINT NOT NULL,
  generation BIGINT NOT NULL DEFAULT 1 CHECK (generation > 0),
  expected_edit_version INT NOT NULL CHECK (expected_edit_version >= 0),
  url_lookup_hmac BYTEA CHECK (
    url_lookup_hmac IS NULL OR octet_length(url_lookup_hmac) = 32
  ),
  url_lookup_key_id TEXT DEFAULT 'legacy-v1',
  original_url_key_id TEXT,
  original_url_nonce BYTEA,
  original_url_ciphertext BYTEA,
  state TEXT NOT NULL CHECK (state IN ('pending','ready','unavailable','disabled')),
  snapshot_id UUID REFERENCES link_preview_snapshots(id) ON DELETE SET NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (dialog_id, msg_id),
  FOREIGN KEY (dialog_id, msg_id)
    REFERENCES messages(dialog_id, msg_id) ON DELETE CASCADE,
  CHECK (
    state = 'disabled'
    OR (url_lookup_hmac IS NOT NULL AND original_url_key_id IS NOT NULL
      AND original_url_nonce IS NOT NULL AND octet_length(original_url_nonce) = 12
      AND original_url_ciphertext IS NOT NULL)
  )
);

CREATE TABLE IF NOT EXISTS link_preview_waiters (
  url_lookup_hmac BYTEA NOT NULL REFERENCES link_preview_cache_entries(url_lookup_hmac)
    ON DELETE CASCADE,
  url_lookup_key_id TEXT NOT NULL DEFAULT 'legacy-v1',
  dialog_id UUID NOT NULL,
  msg_id BIGINT NOT NULL,
  expected_edit_version INT NOT NULL,
  generation BIGINT NOT NULL,
  PRIMARY KEY (url_lookup_hmac, dialog_id, msg_id),
  FOREIGN KEY (dialog_id, msg_id)
    REFERENCES message_link_previews(dialog_id, msg_id) ON DELETE CASCADE
);

-- Expand deployed v1 tables without rewriting existing rows. Legacy digests retain an
-- explicit key label so retries and cache lookups survive blind-index activation.
ALTER TABLE chat_folder_mutation_requests
  ADD COLUMN IF NOT EXISTS request_fingerprint BYTEA;
ALTER TABLE chat_folder_mutation_requests
  ADD COLUMN IF NOT EXISTS fingerprint_key_id TEXT NOT NULL DEFAULT 'legacy-v1';
ALTER TABLE scheduled_delivery_mutation_requests
  ADD COLUMN IF NOT EXISTS fingerprint_key_id TEXT NOT NULL DEFAULT 'legacy-v1';
ALTER TABLE link_preview_assets
  ADD COLUMN IF NOT EXISTS digest_key_id TEXT NOT NULL DEFAULT 'legacy-v1';
ALTER TABLE link_preview_cache_entries
  ADD COLUMN IF NOT EXISTS url_lookup_key_id TEXT NOT NULL DEFAULT 'legacy-v1';
ALTER TABLE message_link_previews
  ADD COLUMN IF NOT EXISTS url_lookup_key_id TEXT DEFAULT 'legacy-v1';
ALTER TABLE message_link_previews
  ALTER COLUMN url_lookup_key_id SET DEFAULT 'legacy-v1';
DO $$ BEGIN
  ALTER TABLE message_link_previews ADD CONSTRAINT message_link_previews_url_hash_key_check
    CHECK (url_lookup_hmac IS NULL OR url_lookup_key_id IS NOT NULL) NOT VALID;
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;
ALTER TABLE link_preview_waiters
  ADD COLUMN IF NOT EXISTS url_lookup_key_id TEXT NOT NULL DEFAULT 'legacy-v1';

CREATE TABLE IF NOT EXISTS link_preview_action_budgets (
  account_id UUID NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  bucket_started TIMESTAMPTZ NOT NULL,
  accepted_count INT NOT NULL DEFAULT 0 CHECK (accepted_count BETWEEN 0 AND 60),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (account_id, bucket_started)
);

-- Add a replacement event constraint without scanning the live table in this phase.
DO $$
DECLARE
  current_definition TEXT;
BEGIN
  SELECT pg_get_constraintdef(oid, TRUE)
  INTO current_definition
  FROM pg_constraint
  WHERE conrelid = 'account_events'::regclass
    AND conname = 'account_events_type_check'
    AND contype = 'c'
    AND convalidated;

  -- A newer deployment can have appended event types after this migration first shipped. Preserve
  -- that forward-compatible constraint instead of recreating v6 and later replacing it with an
  -- older set. Remove an abandoned v6 candidate so the contract phase cannot swap it in.
  IF current_definition IS NOT NULL
     AND strpos(current_definition, quote_literal('message.expired')) > 0
     AND strpos(current_definition, quote_literal('message.preview_updated')) > 0
     AND strpos(current_definition, quote_literal('security.changed')) > 0
     AND strpos(current_definition, quote_literal('chat_folders.updated')) > 0
     AND strpos(current_definition, quote_literal('scheduled.created')) > 0
     AND strpos(current_definition, quote_literal('scheduled.updated')) > 0
     AND strpos(current_definition, quote_literal('scheduled.canceled')) > 0
     AND strpos(current_definition, quote_literal('scheduled.failed')) > 0
     AND strpos(current_definition, quote_literal('pin.updated')) > 0
     AND strpos(current_definition, quote_literal('dialog.auto_delete_updated')) > 0
     AND strpos(current_definition, quote_literal('poll.updated')) > 0
     AND strpos(current_definition, quote_literal('sticker_preferences.updated')) > 0 THEN
    IF EXISTS (
      SELECT 1 FROM pg_constraint
      WHERE conrelid = 'account_events'::regclass
        AND conname = 'account_events_type_check_v6'
    ) THEN
      ALTER TABLE account_events DROP CONSTRAINT account_events_type_check_v6;
    END IF;
    RETURN;
  END IF;

  -- A failed or out-of-order older deployment may have left the original productivity-only v6
  -- candidate behind. Never trust its name as proof of its contents.
  IF EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conrelid = 'account_events'::regclass
      AND conname = 'account_events_type_check_v6'
  ) THEN
    ALTER TABLE account_events DROP CONSTRAINT account_events_type_check_v6;
  END IF;
  ALTER TABLE account_events
    ADD CONSTRAINT account_events_type_check_v6 CHECK (type IN (
      'message.new','message.edited','message.deleted','message.expired','message.preview_updated',
      'reaction.updated','read.updated','dialog.created','member.added','member.removed',
      'member.role_changed','member.left','dialog.profile_updated','dialog.closed',
      'dialog.access_revoked','dialog.preferences_updated','profile.updated','draft.updated',
      'security.changed','chat_folders.updated','scheduled.created','scheduled.updated',
      'scheduled.canceled','scheduled.failed','pin.updated','dialog.auto_delete_updated',
      'poll.updated','sticker_preferences.updated'
    )) NOT VALID;
END;
$$;

INSERT INTO schema_migrations(name) VALUES ('cloud-productivity-expand-v1')
ON CONFLICT DO NOTHING;
INSERT INTO schema_migrations(name) VALUES ('cloud-productivity-encryption-expand-v2')
ON CONFLICT DO NOTHING;

COMMIT;
