\set ON_ERROR_STOP on

-- CREATE INDEX CONCURRENTLY can leave an invalid shell after interruption. Drop only
-- those known shells so an idempotent retry actually rebuilds them.
SELECT format('DROP INDEX CONCURRENTLY IF EXISTS %I.%I', namespace.nspname, class.relname)
FROM pg_index AS idx
JOIN pg_class AS class ON class.oid = idx.indexrelid
JOIN pg_namespace AS namespace ON namespace.oid = class.relnamespace
WHERE namespace.nspname = 'public'
  AND class.relname IN (
    'chat_folder_rules_dialog_idx',
    'scheduled_deliveries_due_idx',
    'scheduled_deliveries_account_idx',
    'scheduled_deliveries_account_delivery_idx',
    'scheduled_delivery_items_media_idx',
    'worker_heartbeats_kind_idx',
    'link_preview_cache_ready_idx',
    'message_link_previews_snapshot_idx',
    'link_preview_waiters_message_idx',
    'link_preview_cache_fanout_pending_idx',
    'chat_folders_title_key_migration_idx',
    'scheduled_items_payload_key_migration_idx',
    'link_preview_cache_key_migration_idx',
    'message_link_preview_key_migration_idx',
    'message_link_preview_url_key_backfill_idx',
    'link_preview_snapshot_url_key_migration_idx',
    'link_preview_snapshot_metadata_key_migration_idx',
    'link_preview_assets_key_migration_idx'
  )
  AND (NOT idx.indisvalid OR NOT idx.indisready)
\gexec

CREATE INDEX CONCURRENTLY IF NOT EXISTS chat_folder_rules_dialog_idx
  ON chat_folder_dialog_rules(account_id, dialog_id, folder_id);
CREATE INDEX CONCURRENTLY IF NOT EXISTS scheduled_deliveries_due_idx
  ON scheduled_deliveries(deliver_at, id)
  WHERE state IN ('scheduled','processing');
CREATE INDEX CONCURRENTLY IF NOT EXISTS scheduled_deliveries_account_idx
  ON scheduled_deliveries(account_id, state, deliver_at, id);
CREATE INDEX CONCURRENTLY IF NOT EXISTS scheduled_deliveries_account_delivery_idx
  ON scheduled_deliveries(account_id, deliver_at, id);
CREATE INDEX CONCURRENTLY IF NOT EXISTS scheduled_delivery_items_media_idx
  ON scheduled_delivery_items(media_id) WHERE media_id IS NOT NULL;
CREATE INDEX CONCURRENTLY IF NOT EXISTS worker_heartbeats_kind_idx
  ON worker_heartbeats(worker_kind, last_seen_at DESC);
CREATE INDEX CONCURRENTLY IF NOT EXISTS link_preview_cache_ready_idx
  ON link_preview_cache_entries(available_at, created_at)
  WHERE state IN ('pending','fetching');
CREATE INDEX CONCURRENTLY IF NOT EXISTS message_link_previews_snapshot_idx
  ON message_link_previews(snapshot_id) WHERE snapshot_id IS NOT NULL;
CREATE INDEX CONCURRENTLY IF NOT EXISTS link_preview_waiters_message_idx
  ON link_preview_waiters(dialog_id, msg_id);
CREATE INDEX CONCURRENTLY IF NOT EXISTS link_preview_cache_fanout_pending_idx
  ON link_preview_cache_entries(updated_at, url_lookup_hmac)
  WHERE fanout_pending;
CREATE INDEX CONCURRENTLY IF NOT EXISTS chat_folders_title_key_migration_idx
  ON chat_folders(title_key_id, account_id, folder_id);
CREATE INDEX CONCURRENTLY IF NOT EXISTS scheduled_items_payload_key_migration_idx
  ON scheduled_delivery_items(payload_key_id, delivery_id, item_index)
  WHERE payload_key_id IS NOT NULL;
CREATE INDEX CONCURRENTLY IF NOT EXISTS link_preview_cache_key_migration_idx
  ON link_preview_cache_entries(url_key_id, url_lookup_hmac);
CREATE INDEX CONCURRENTLY IF NOT EXISTS message_link_preview_key_migration_idx
  ON message_link_previews(original_url_key_id, dialog_id, msg_id)
  WHERE original_url_key_id IS NOT NULL;
CREATE INDEX CONCURRENTLY IF NOT EXISTS message_link_preview_url_key_backfill_idx
  ON message_link_previews(dialog_id, msg_id)
  WHERE url_lookup_hmac IS NOT NULL AND url_lookup_key_id IS NULL;
CREATE INDEX CONCURRENTLY IF NOT EXISTS link_preview_snapshot_url_key_migration_idx
  ON link_preview_snapshots(url_key_id, id);
CREATE INDEX CONCURRENTLY IF NOT EXISTS link_preview_snapshot_metadata_key_migration_idx
  ON link_preview_snapshots(metadata_key_id, id);
CREATE INDEX CONCURRENTLY IF NOT EXISTS link_preview_assets_key_migration_idx
  ON link_preview_assets(key_id, id);

INSERT INTO schema_migrations(name) VALUES ('cloud-productivity-indexes-v1')
ON CONFLICT DO NOTHING;
INSERT INTO schema_migrations(name) VALUES ('cloud-productivity-encryption-indexes-v2')
ON CONFLICT DO NOTHING;
