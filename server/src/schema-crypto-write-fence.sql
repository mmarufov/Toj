-- Database-backed final-mode fence. This file runs only after all core and productivity
-- ciphertext tables exist, so an old node cannot write dev-v1 after final envelope activation.

\set ON_ERROR_STOP on

BEGIN;
SET LOCAL lock_timeout = '5s';

CREATE OR REPLACE FUNCTION public.toj_guard_crypto_write_state_v1()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = pg_catalog, public
AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN
    RAISE EXCEPTION 'crypto_write_state cannot be deleted';
  END IF;
  IF OLD.write_mode = 'envelope' AND NEW.write_mode <> 'envelope' THEN
    RAISE EXCEPTION 'final envelope mode cannot be downgraded';
  END IF;
  IF OLD.write_mode = 'legacy' AND NEW.write_mode = 'envelope' THEN
    RAISE EXCEPTION 'envelope-canary must precede final envelope mode';
  END IF;
  IF NEW.write_mode IS DISTINCT FROM OLD.write_mode AND NEW.epoch <= OLD.epoch THEN
    RAISE EXCEPTION 'crypto write-mode transitions must advance the epoch';
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS crypto_write_state_guard ON public.crypto_write_state;
CREATE TRIGGER crypto_write_state_guard
  BEFORE UPDATE OR DELETE ON public.crypto_write_state
  FOR EACH ROW EXECUTE FUNCTION public.toj_guard_crypto_write_state_v1();

CREATE OR REPLACE FUNCTION public.toj_reject_legacy_ciphertext_v1()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = pg_catalog, public
AS $$
DECLARE
  mode TEXT;
  position INT := 0;
  key_column TEXT;
  nonce_column TEXT;
  ciphertext_column TEXT;
  new_row JSONB := to_jsonb(NEW);
  old_row JSONB := CASE WHEN TG_OP = 'UPDATE' THEN to_jsonb(OLD) ELSE NULL END;
  tuple_changed BOOLEAN;
BEGIN
  SELECT write_mode INTO STRICT mode
  FROM public.crypto_write_state WHERE singleton;
  IF mode <> 'envelope' THEN
    RETURN NEW;
  END IF;
  IF TG_NARGS = 0 OR TG_NARGS % 3 <> 0 THEN
    RAISE EXCEPTION 'invalid crypto write-fence trigger configuration';
  END IF;
  WHILE position < TG_NARGS LOOP
    key_column := TG_ARGV[position];
    nonce_column := TG_ARGV[position + 1];
    ciphertext_column := TG_ARGV[position + 2];
    tuple_changed := TG_OP = 'INSERT'
      OR (new_row -> key_column) IS DISTINCT FROM (old_row -> key_column)
      OR (new_row -> nonce_column) IS DISTINCT FROM (old_row -> nonce_column)
      OR (new_row -> ciphertext_column) IS DISTINCT FROM (old_row -> ciphertext_column);
    IF tuple_changed AND new_row ->> key_column = 'dev-v1' THEN
      RAISE EXCEPTION 'legacy ciphertext writes are disabled for %.%', TG_TABLE_NAME, key_column
        USING ERRCODE = '55000';
    END IF;
    position := position + 3;
  END LOOP;
  RETURN NEW;
END;
$$;

DO $fence$
DECLARE
  item RECORD;
BEGIN
  FOR item IN SELECT * FROM (VALUES
    ('accounts', 'phone_key_id', 'phone_nonce', 'phone_e164_ciphertext'),
    ('devices', 'push_token_key_id', 'push_token_nonce', 'push_token_ciphertext'),
    ('devices', 'voip_push_token_key_id', 'voip_push_token_nonce', 'voip_push_token_ciphertext'),
    ('messages', 'body_key_id', 'body_nonce', 'body_ciphertext'),
    ('account_dialog_drafts', 'body_key_id', 'body_nonce', 'body_ciphertext'),
    ('draft_mutation_requests', 'response_key_id', 'response_nonce', 'response_ciphertext'),
    ('media_objects', 'file_name_key_id', 'file_name_nonce', 'file_name_ciphertext'),
    ('media_objects', 'thumbnail_key_id', 'thumbnail_nonce', 'thumbnail_ciphertext'),
    ('media_chunks', 'key_id', 'nonce', 'ciphertext'),
    ('abuse_reports', 'evidence_key_id', 'evidence_nonce', 'evidence_ciphertext'),
    ('abuse_report_actions', 'note_key_id', 'note_nonce', 'note_ciphertext'),
    ('user_reports', 'message_snapshot_key_id', 'message_snapshot_nonce', 'message_snapshot_ciphertext'),
    ('chat_folders', 'title_key_id', 'title_nonce', 'title_ciphertext'),
    ('scheduled_delivery_items', 'payload_key_id', 'payload_nonce', 'payload_ciphertext'),
    ('link_preview_cache_entries', 'url_key_id', 'url_nonce', 'url_ciphertext'),
    ('message_link_previews', 'original_url_key_id', 'original_url_nonce', 'original_url_ciphertext'),
    ('link_preview_snapshots', 'url_key_id', 'url_nonce', 'url_ciphertext'),
    ('link_preview_snapshots', 'metadata_key_id', 'metadata_nonce', 'metadata_ciphertext'),
    ('link_preview_assets', 'key_id', 'nonce', 'ciphertext'),
    ('message_polls', 'payload_key_id', 'payload_nonce', 'payload_ciphertext'),
    ('push_installations', 'normal_token_key_id', 'normal_token_nonce', 'normal_token_ciphertext'),
    ('push_installations', 'voip_token_key_id', 'voip_token_nonce', 'voip_token_ciphertext'),
    ('session_rotation_receipts', 'response_key_id', 'response_nonce', 'response_ciphertext')
  ) AS domains(table_name, key_column, nonce_column, ciphertext_column)
  LOOP
    EXECUTE format('DROP TRIGGER IF EXISTS %I ON public.%I',
      'crypto_write_fence_' || item.table_name || '_' || item.key_column,
      item.table_name);
    EXECUTE format(
      'CREATE TRIGGER %I BEFORE INSERT OR UPDATE ON public.%I '
      || 'FOR EACH ROW EXECUTE FUNCTION public.toj_reject_legacy_ciphertext_v1(%L,%L,%L)',
      'crypto_write_fence_' || item.table_name || '_' || item.key_column,
      item.table_name, item.key_column, item.nonce_column, item.ciphertext_column
    );
  END LOOP;
END;
$fence$;

INSERT INTO public.schema_migrations(name)
VALUES ('crypto-write-fence-v1')
ON CONFLICT (name) DO UPDATE SET completed_at = now();

COMMIT;
