\set ON_ERROR_STOP on

BEGIN;
SET LOCAL lock_timeout = '2s';
SET LOCAL statement_timeout = '30s';

ALTER TABLE messages
  VALIDATE CONSTRAINT messages_send_fingerprint_size_check;
ALTER TABLE send_requests
  VALIDATE CONSTRAINT send_requests_fingerprint_size_check;
ALTER TABLE scheduled_delivery_mutation_requests
  VALIDATE CONSTRAINT scheduled_delivery_request_fingerprint_size_check;
ALTER TABLE message_link_previews
  VALIDATE CONSTRAINT message_link_previews_url_hash_key_check;

DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conrelid = 'account_events'::regclass
      AND conname = 'account_events_type_check_v6'
      AND convalidated
  ) THEN
    ALTER TABLE account_events DROP CONSTRAINT IF EXISTS account_events_type_check;
    ALTER TABLE account_events
      RENAME CONSTRAINT account_events_type_check_v6 TO account_events_type_check;
  END IF;
END;
$$;

INSERT INTO schema_migrations(name) VALUES ('cloud-productivity-contract-v1')
ON CONFLICT DO NOTHING;
INSERT INTO schema_migrations(name) VALUES ('cloud-productivity-encryption-contract-v2')
ON CONFLICT DO NOTHING;

COMMIT;
