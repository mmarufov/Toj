-- Additive presence storage. No historical device activity is copied into last_seen_at: only
-- foreground presence leases introduced by presence_v1 are authoritative.
CREATE TABLE IF NOT EXISTS account_presence (
  account_id   UUID PRIMARY KEY REFERENCES accounts(id) ON DELETE CASCADE,
  last_seen_at TIMESTAMPTZ,
  revision     BIGINT NOT NULL DEFAULT 0 CHECK (revision >= 0),
  updated_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE SEQUENCE IF NOT EXISTS presence_connection_epoch_seq AS BIGINT;

CREATE TABLE IF NOT EXISTS device_presence_leases (
  device_id          UUID PRIMARY KEY REFERENCES devices(id) ON DELETE CASCADE,
  account_id         UUID NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  connection_id      UUID NOT NULL,
  connection_epoch   BIGINT NOT NULL DEFAULT nextval('presence_connection_epoch_seq'),
  last_heartbeat_at  TIMESTAMPTZ NOT NULL,
  expires_at         TIMESTAMPTZ NOT NULL,
  CHECK (expires_at > last_heartbeat_at)
);

ALTER TABLE device_presence_leases
  ADD COLUMN IF NOT EXISTS connection_epoch BIGINT;
UPDATE device_presence_leases
SET connection_epoch = nextval('presence_connection_epoch_seq')
WHERE connection_epoch IS NULL;
ALTER TABLE device_presence_leases
  ALTER COLUMN connection_epoch SET DEFAULT nextval('presence_connection_epoch_seq'),
  ALTER COLUMN connection_epoch SET NOT NULL;

CREATE INDEX IF NOT EXISTS device_presence_leases_account_expiry_idx
  ON device_presence_leases(account_id, expires_at);
CREATE INDEX IF NOT EXISTS device_presence_leases_expiry_idx
  ON device_presence_leases(expires_at, account_id);

-- Account rows are tombstoned instead of deleted, so FK cascades cannot clean data left by a
-- mixed-version node that deleted an account before the presence-aware cleanup function landed.
DELETE FROM device_presence_leases AS lease
USING accounts AS account
WHERE account.id = lease.account_id AND account.status = 'deleted';
DELETE FROM account_presence AS presence
USING accounts AS account
WHERE account.id = presence.account_id AND account.status = 'deleted';

INSERT INTO schema_migrations(name)
VALUES ('presence-v1-expand')
ON CONFLICT (name) DO NOTHING;
