import Foundation
import GRDB
import os
import Security

extension CloudLocalStore {
    static func migrate(_ dbPool: DatabasePool) throws {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1-cloud-replica") { db in
            try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS sync_state (
              account_id TEXT PRIMARY KEY,
              pts INTEGER NOT NULL DEFAULT 0,
              updated_at TEXT NOT NULL DEFAULT (datetime('now'))
            );

            CREATE TABLE IF NOT EXISTS dialogs (
              dialog_id TEXT PRIMARY KEY,
              type TEXT NOT NULL,
              title TEXT,
              last_msg_id INTEGER NOT NULL DEFAULT 0,
              updated_at TEXT NOT NULL DEFAULT (datetime('now'))
            );

            CREATE TABLE IF NOT EXISTS dialog_members (
              dialog_id TEXT NOT NULL,
              account_id TEXT NOT NULL,
              role TEXT NOT NULL,
              last_read_msg_id INTEGER NOT NULL DEFAULT 0,
              PRIMARY KEY (dialog_id, account_id)
            );

            CREATE TABLE IF NOT EXISTS profiles (
              account_id TEXT PRIMARY KEY,
              first_name TEXT NOT NULL,
              last_name TEXT NOT NULL,
              display_name TEXT NOT NULL,
              bio TEXT NOT NULL,
              birthday TEXT,
              color_index INTEGER NOT NULL DEFAULT 0,
              updated_at TEXT NOT NULL
            );

            CREATE TABLE IF NOT EXISTS messages (
              local_id TEXT PRIMARY KEY,
              dialog_id TEXT NOT NULL,
              msg_id INTEGER,
              client_msg_id TEXT NOT NULL UNIQUE,
              sender_account_id TEXT NOT NULL,
              kind TEXT NOT NULL,
              text TEXT NOT NULL,
              reply_to_msg_id INTEGER,
              forwarded_from_account_id TEXT,
              forwarded_from_dialog_id TEXT,
              forwarded_from_msg_id INTEGER,
              is_forwarded INTEGER NOT NULL DEFAULT 0,
              media_json TEXT,
              edit_version INTEGER NOT NULL DEFAULT 0,
              state TEXT NOT NULL,
              server_ts TEXT,
              local_state TEXT NOT NULL
            );

            CREATE UNIQUE INDEX IF NOT EXISTS messages_dialog_msg_idx
              ON messages(dialog_id, msg_id)
              WHERE msg_id IS NOT NULL;

            CREATE INDEX IF NOT EXISTS messages_dialog_order_idx
              ON messages(dialog_id, msg_id);

            CREATE TABLE IF NOT EXISTS pending_outbox (
              client_msg_id TEXT PRIMARY KEY,
              dialog_id TEXT NOT NULL,
              body TEXT NOT NULL,
              reply_to_msg_id INTEGER,
              forwarded_from_dialog_id TEXT,
              forwarded_from_msg_id INTEGER,
              retry_count INTEGER NOT NULL DEFAULT 0,
              next_retry_at TEXT,
              terminal INTEGER NOT NULL DEFAULT 0,
              created_at TEXT NOT NULL DEFAULT (datetime('now'))
            );

            CREATE TABLE IF NOT EXISTS message_reactions (
              dialog_id TEXT NOT NULL,
              msg_id INTEGER NOT NULL,
              account_id TEXT NOT NULL,
              emoji TEXT NOT NULL,
              PRIMARY KEY (dialog_id, msg_id, account_id)
            );

            CREATE TABLE IF NOT EXISTS media_transfers (
              transfer_id TEXT PRIMARY KEY,
              dialog_id TEXT NOT NULL,
              client_msg_id TEXT NOT NULL UNIQUE,
              caption TEXT NOT NULL DEFAULT '',
              reply_to_msg_id INTEGER,
              kind TEXT NOT NULL,
              content_type TEXT NOT NULL,
              file_name TEXT,
              byte_size INTEGER NOT NULL,
              sha256 TEXT NOT NULL,
              duration_ms INTEGER,
              width INTEGER,
              height INTEGER,
              encrypted_source_path TEXT NOT NULL,
              encrypted_thumbnail_path TEXT,
              media_id TEXT,
              upload_offset INTEGER NOT NULL DEFAULT 0,
              state TEXT NOT NULL CHECK (state IN ('pending','uploading','ready_to_send')),
              retry_count INTEGER NOT NULL DEFAULT 0,
              next_retry_at TEXT,
              last_error TEXT,
              terminal INTEGER NOT NULL DEFAULT 0,
              created_at TEXT NOT NULL
            );
            CREATE INDEX IF NOT EXISTS media_transfers_retry_idx
              ON media_transfers(state, next_retry_at, created_at);

            CREATE TABLE IF NOT EXISTS pending_message_mutations (
              client_mutation_id TEXT PRIMARY KEY,
              operation TEXT NOT NULL CHECK (operation IN ('edit','delete','reaction')),
              dialog_id TEXT NOT NULL,
              msg_id INTEGER NOT NULL,
              body TEXT,
              expected_edit_version INTEGER,
              emoji TEXT,
              retry_count INTEGER NOT NULL DEFAULT 0,
              next_retry_at TEXT,
              last_error TEXT,
              terminal INTEGER NOT NULL DEFAULT 0,
              created_at TEXT NOT NULL
            );
            CREATE INDEX IF NOT EXISTS pending_message_mutations_retry_idx
              ON pending_message_mutations(terminal, next_retry_at, created_at);
            """)

            let messageColumns = try db.columns(in: "messages").map(\.name)
            if !messageColumns.contains("reply_to_msg_id") {
                try db.execute(sql: "ALTER TABLE messages ADD COLUMN reply_to_msg_id INTEGER")
            }
            if !messageColumns.contains("edit_version") {
                try db.execute(sql: "ALTER TABLE messages ADD COLUMN edit_version INTEGER NOT NULL DEFAULT 0")
            }
            if !messageColumns.contains("forwarded_from_account_id") {
                try db.execute(sql: "ALTER TABLE messages ADD COLUMN forwarded_from_account_id TEXT")
            }
            if !messageColumns.contains("forwarded_from_dialog_id") {
                try db.execute(sql: "ALTER TABLE messages ADD COLUMN forwarded_from_dialog_id TEXT")
            }
            if !messageColumns.contains("forwarded_from_msg_id") {
                try db.execute(sql: "ALTER TABLE messages ADD COLUMN forwarded_from_msg_id INTEGER")
            }
            if !messageColumns.contains("is_forwarded") {
                try db.execute(sql: "ALTER TABLE messages ADD COLUMN is_forwarded INTEGER NOT NULL DEFAULT 0")
            }
            if !messageColumns.contains("media_json") {
                try db.execute(sql: "ALTER TABLE messages ADD COLUMN media_json TEXT")
            }
            let outboxColumns = try db.columns(in: "pending_outbox").map(\.name)
            if !outboxColumns.contains("reply_to_msg_id") {
                try db.execute(sql: "ALTER TABLE pending_outbox ADD COLUMN reply_to_msg_id INTEGER")
            }
            if !outboxColumns.contains("forwarded_from_dialog_id") {
                try db.execute(sql: "ALTER TABLE pending_outbox ADD COLUMN forwarded_from_dialog_id TEXT")
            }
            if !outboxColumns.contains("forwarded_from_msg_id") {
                try db.execute(sql: "ALTER TABLE pending_outbox ADD COLUMN forwarded_from_msg_id INTEGER")
            }
            if !outboxColumns.contains("terminal") {
                try db.execute(sql: "ALTER TABLE pending_outbox ADD COLUMN terminal INTEGER NOT NULL DEFAULT 0")
            }
            let mediaColumns = try db.columns(in: "media_transfers").map(\.name)
            if !mediaColumns.contains("terminal") {
                try db.execute(sql: "ALTER TABLE media_transfers ADD COLUMN terminal INTEGER NOT NULL DEFAULT 0")
            }
        }

        migrator.registerMigration("v2-local-first-windows-and-ledgers") { db in
            try db.execute(sql: """
            CREATE INDEX IF NOT EXISTS dialogs_updated_idx
              ON dialogs(updated_at DESC, dialog_id DESC);
            CREATE INDEX IF NOT EXISTS dialog_members_account_idx
              ON dialog_members(account_id, dialog_id, last_read_msg_id);
            CREATE INDEX IF NOT EXISTS messages_dialog_visible_order_idx
              ON messages(dialog_id, state, msg_id DESC)
              WHERE msg_id IS NOT NULL;
            CREATE INDEX IF NOT EXISTS messages_dialog_sender_state_msg_idx
              ON messages(dialog_id, sender_account_id, state, msg_id)
              WHERE msg_id IS NOT NULL;
            CREATE INDEX IF NOT EXISTS message_reactions_dialog_msg_idx
              ON message_reactions(dialog_id, msg_id, account_id);
            CREATE INDEX IF NOT EXISTS pending_message_mutations_dialog_msg_idx
              ON pending_message_mutations(dialog_id, msg_id, operation);

            CREATE TABLE IF NOT EXISTS chat_viewport_state (
              dialog_id TEXT NOT NULL,
              account_id TEXT NOT NULL,
              top_visible_msg_id INTEGER,
              was_at_bottom INTEGER NOT NULL DEFAULT 1,
              updated_at TEXT NOT NULL,
              PRIMARY KEY (dialog_id, account_id)
            );

            CREATE TABLE IF NOT EXISTS dialog_history_state (
              dialog_id TEXT PRIMARY KEY,
              ceiling_msg_id INTEGER NOT NULL DEFAULT 0,
              next_before_msg_id INTEGER,
              history_complete INTEGER NOT NULL DEFAULT 0,
              retry_count INTEGER NOT NULL DEFAULT 0,
              next_retry_at TEXT,
              updated_at TEXT NOT NULL
            );
            CREATE INDEX IF NOT EXISTS dialog_history_ready_idx
              ON dialog_history_state(history_complete, next_retry_at, updated_at);

            CREATE TABLE IF NOT EXISTS bootstrap_state (
              account_id TEXT PRIMARY KEY,
              token TEXT,
              next_cursor TEXT,
              snapshot_pts INTEGER NOT NULL DEFAULT 0,
              status TEXT NOT NULL CHECK (status IN ('in_progress','needs_rebuild')),
              updated_at TEXT NOT NULL
            );

            CREATE TABLE IF NOT EXISTS message_media (
              local_id TEXT PRIMARY KEY,
              dialog_id TEXT NOT NULL,
              msg_id INTEGER,
              media_id TEXT NOT NULL,
              kind TEXT NOT NULL,
              content_type TEXT NOT NULL,
              file_name TEXT,
              byte_size INTEGER NOT NULL,
              duration_ms INTEGER,
              width INTEGER,
              height INTEGER,
              has_thumbnail INTEGER NOT NULL DEFAULT 0
            );
            CREATE INDEX IF NOT EXISTS message_media_dialog_msg_idx
              ON message_media(dialog_id, msg_id);
            CREATE INDEX IF NOT EXISTS message_media_media_idx
              ON message_media(media_id);

            CREATE TABLE IF NOT EXISTS media_cache_entries (
              media_id TEXT NOT NULL,
              variant TEXT NOT NULL CHECK (variant IN ('thumbnail','full')),
              encrypted_path TEXT NOT NULL,
              byte_size INTEGER NOT NULL DEFAULT 0,
              cached_bytes INTEGER NOT NULL DEFAULT 0,
              contiguous_offset INTEGER NOT NULL DEFAULT 0,
              state TEXT NOT NULL,
              last_accessed_at TEXT NOT NULL,
              protected_until TEXT,
              PRIMARY KEY (media_id, variant)
            );
            CREATE INDEX IF NOT EXISTS media_cache_lru_idx
              ON media_cache_entries(protected_until, last_accessed_at);

            CREATE TABLE IF NOT EXISTS media_download_jobs (
              media_id TEXT NOT NULL,
              variant TEXT NOT NULL CHECK (variant IN ('thumbnail','full')),
              dialog_id TEXT,
              priority INTEGER NOT NULL DEFAULT 0,
              state TEXT NOT NULL CHECK (state IN ('queued','downloading','paused','completed','failed')),
              user_initiated INTEGER NOT NULL DEFAULT 0,
              retry_count INTEGER NOT NULL DEFAULT 0,
              next_retry_at TEXT,
              last_error TEXT,
              updated_at TEXT NOT NULL,
              PRIMARY KEY (media_id, variant)
            );
            CREATE INDEX IF NOT EXISTS media_download_ready_idx
              ON media_download_jobs(state, next_retry_at, priority DESC, updated_at);
            """)

            let mediaRows = try Row.fetchAll(
                db,
                sql: """
                SELECT local_id, dialog_id, msg_id, media_json
                FROM messages
                WHERE media_json IS NOT NULL
                """
            )
            for row in mediaRows {
                guard
                    let json: String = row["media_json"],
                    let data = json.data(using: .utf8),
                    let media = try? JSONDecoder().decode(CloudMedia.self, from: data)
                else { continue }
                try Self.upsertMessageMedia(
                    db,
                    localId: row["local_id"],
                    dialogId: row["dialog_id"],
                    msgId: row["msg_id"],
                    media: media
                )
            }

            try db.execute(
                sql: """
                INSERT INTO dialog_history_state (
                  dialog_id, ceiling_msg_id, next_before_msg_id, history_complete, updated_at
                )
                SELECT
                  d.dialog_id,
                  d.last_msg_id,
                  MIN(m.msg_id),
                  CASE WHEN MIN(m.msg_id) = 1 OR d.last_msg_id = 0 THEN 1 ELSE 0 END,
                  datetime('now')
                FROM dialogs d
                LEFT JOIN messages m ON m.dialog_id = d.dialog_id AND m.msg_id IS NOT NULL
                GROUP BY d.dialog_id
                ON CONFLICT(dialog_id) DO NOTHING
                """
            )
        }

        migrator.registerMigration("v3-denormalized-dialog-summaries") { db in
            try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS dialog_summaries (
              dialog_id TEXT PRIMARY KEY,
              last_local_id TEXT,
              last_msg_id INTEGER,
              last_text TEXT,
              last_kind TEXT,
              last_state TEXT,
              last_sender_account_id TEXT,
              last_local_state TEXT,
              last_server_ts TEXT
            );

            CREATE TABLE IF NOT EXISTS dialog_unread_summaries (
              dialog_id TEXT NOT NULL,
              account_id TEXT NOT NULL,
              unread_count INTEGER NOT NULL DEFAULT 0,
              PRIMARY KEY (dialog_id, account_id)
            );
            CREATE INDEX IF NOT EXISTS dialog_unread_account_idx
              ON dialog_unread_summaries(account_id, dialog_id, unread_count);

            INSERT INTO dialog_summaries (
              dialog_id, last_local_id, last_msg_id, last_text, last_kind, last_state,
              last_sender_account_id, last_local_state, last_server_ts
            )
            SELECT
              d.dialog_id, m.local_id, m.msg_id, m.text, m.kind, m.state,
              m.sender_account_id, m.local_state, m.server_ts
            FROM dialogs d
            LEFT JOIN messages m ON m.rowid = (
              SELECT candidate.rowid
              FROM messages candidate
              WHERE candidate.dialog_id = d.dialog_id
                AND candidate.state = 'visible'
                AND NOT EXISTS (
                  SELECT 1 FROM pending_message_mutations pending_delete
                  WHERE pending_delete.dialog_id = candidate.dialog_id
                    AND pending_delete.msg_id = candidate.msg_id
                    AND pending_delete.operation = 'delete'
                )
              ORDER BY COALESCE(candidate.msg_id, 9223372036854775807) DESC, candidate.rowid DESC
              LIMIT 1
            );

            INSERT INTO dialog_unread_summaries (dialog_id, account_id, unread_count)
            SELECT
              member.dialog_id,
              member.account_id,
              COUNT(message.msg_id)
            FROM dialog_members member
            LEFT JOIN messages message
              ON message.dialog_id = member.dialog_id
             AND message.msg_id IS NOT NULL
             AND message.sender_account_id != member.account_id
             AND message.state = 'visible'
             AND message.msg_id > member.last_read_msg_id
            GROUP BY member.dialog_id, member.account_id;
            """)
        }

        migrator.registerMigration("v4-atomic-bootstrap-staging") { db in
            let bootstrapColumns = try db.columns(in: "bootstrap_state").map(\.name)
            if !bootstrapColumns.contains("mode") {
                try db.execute(
                    sql: """
                    ALTER TABLE bootstrap_state
                    ADD COLUMN mode TEXT NOT NULL DEFAULT 'initial'
                      CHECK (mode IN ('initial','replacement'))
                    """
                )
                try db.execute(
                    sql: """
                    UPDATE bootstrap_state
                    SET mode = CASE WHEN EXISTS(SELECT 1 FROM dialogs LIMIT 1)
                      THEN 'replacement' ELSE 'initial' END
                    """
                )
            }

            try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS bootstrap_staged_dialogs (
              account_id TEXT NOT NULL,
              dialog_id TEXT NOT NULL,
              type TEXT NOT NULL,
              title TEXT,
              last_msg_id INTEGER NOT NULL,
              updated_at TEXT NOT NULL,
              PRIMARY KEY (account_id, dialog_id)
            );

            CREATE TABLE IF NOT EXISTS bootstrap_staged_members (
              account_id TEXT NOT NULL,
              dialog_id TEXT NOT NULL,
              member_account_id TEXT NOT NULL,
              role TEXT NOT NULL,
              last_read_msg_id INTEGER NOT NULL,
              PRIMARY KEY (account_id, dialog_id, member_account_id)
            );
            CREATE INDEX IF NOT EXISTS bootstrap_staged_members_dialog_idx
              ON bootstrap_staged_members(account_id, dialog_id);

            CREATE TABLE IF NOT EXISTS bootstrap_staged_profiles (
              account_id TEXT NOT NULL,
              profile_account_id TEXT NOT NULL,
              profile_json TEXT NOT NULL,
              PRIMARY KEY (account_id, profile_account_id)
            );

            CREATE TABLE IF NOT EXISTS bootstrap_staged_messages (
              account_id TEXT NOT NULL,
              dialog_id TEXT NOT NULL,
              msg_id INTEGER NOT NULL,
              client_msg_id TEXT NOT NULL,
              message_json TEXT NOT NULL,
              PRIMARY KEY (account_id, dialog_id, msg_id),
              UNIQUE (account_id, client_msg_id)
            );
            CREATE INDEX IF NOT EXISTS bootstrap_staged_messages_dialog_idx
              ON bootstrap_staged_messages(account_id, dialog_id, msg_id);
            """)
        }

        migrator.registerMigration("v5-durable-read-receipts") { db in
            try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS pending_read_receipts (
              dialog_id TEXT NOT NULL,
              account_id TEXT NOT NULL,
              max_read_msg_id INTEGER NOT NULL,
              retry_count INTEGER NOT NULL DEFAULT 0,
              next_retry_at TEXT,
              last_error TEXT,
              updated_at TEXT NOT NULL,
              PRIMARY KEY (dialog_id, account_id)
            );
            CREATE INDEX IF NOT EXISTS pending_read_receipts_ready_idx
              ON pending_read_receipts(next_retry_at, updated_at);
            """)
        }

        migrator.registerMigration("v6-bootstrap-baseline-dialogs") { db in
            try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS bootstrap_baseline_dialogs (
              account_id TEXT NOT NULL,
              dialog_id TEXT NOT NULL,
              PRIMARY KEY (account_id, dialog_id)
            );
            """)
        }

        migrator.registerMigration("v7-replica-initialization-and-exact-unreads") { db in
            try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS replica_state (
              account_id TEXT PRIMARY KEY,
              initialized INTEGER NOT NULL DEFAULT 0,
              updated_at TEXT NOT NULL DEFAULT (datetime('now'))
            );

            INSERT OR IGNORE INTO replica_state (account_id, initialized, updated_at)
            SELECT account_id, 1, updated_at FROM sync_state;
            """)

            let stagedColumns = try db.columns(in: "bootstrap_staged_dialogs").map(\.name)
            if !stagedColumns.contains("unread_count") {
                try db.execute(sql: "ALTER TABLE bootstrap_staged_dialogs ADD COLUMN unread_count INTEGER")
            }

            let unreadColumns = try db.columns(in: "dialog_unread_summaries").map(\.name)
            if !unreadColumns.contains("is_exact") {
                try db.execute(
                    sql: "ALTER TABLE dialog_unread_summaries ADD COLUMN is_exact INTEGER NOT NULL DEFAULT 0"
                )
            }

            let stagedDialogColumns = try db.columns(in: "bootstrap_staged_dialogs").map(\.name)
            if !stagedDialogColumns.contains("revision") {
                try db.execute(sql: "ALTER TABLE bootstrap_staged_dialogs ADD COLUMN revision INTEGER")
            }
            if !stagedDialogColumns.contains("member_count") {
                try db.execute(sql: "ALTER TABLE bootstrap_staged_dialogs ADD COLUMN member_count INTEGER")
            }
            if !stagedDialogColumns.contains("self_role") {
                try db.execute(sql: "ALTER TABLE bootstrap_staged_dialogs ADD COLUMN self_role TEXT")
            }
            if !stagedDialogColumns.contains("notification_mode") {
                try db.execute(sql: "ALTER TABLE bootstrap_staged_dialogs ADD COLUMN notification_mode TEXT")
            }
            if !stagedDialogColumns.contains("photo_media_json") {
                try db.execute(sql: "ALTER TABLE bootstrap_staged_dialogs ADD COLUMN photo_media_json TEXT")
            }

            let stagedMemberColumns = try db.columns(in: "bootstrap_staged_members").map(\.name)
            if !stagedMemberColumns.contains("joined_at") {
                try db.execute(sql: "ALTER TABLE bootstrap_staged_members ADD COLUMN joined_at TEXT")
            }
            if !stagedMemberColumns.contains("is_active") {
                try db.execute(sql: "ALTER TABLE bootstrap_staged_members ADD COLUMN is_active INTEGER")
            }
        }

        migrator.registerMigration("v8-media-presentation-representations") { db in
            // SQLite cannot widen a CHECK constraint in place. Preserve the encrypted-cache ledger
            // while admitting the durable presentation variants introduced above the raw cache.
            try db.execute(sql: "DROP INDEX IF EXISTS media_cache_lru_idx")
            try db.execute(sql: "ALTER TABLE media_cache_entries RENAME TO media_cache_entries_v7")
            try db.execute(sql: """
            CREATE TABLE media_cache_entries (
              media_id TEXT NOT NULL,
              variant TEXT NOT NULL CHECK (
                variant IN ('thumbnail','full','bubble-720','screen-2048','video-poster')
              ),
              encrypted_path TEXT NOT NULL,
              byte_size INTEGER NOT NULL DEFAULT 0,
              cached_bytes INTEGER NOT NULL DEFAULT 0,
              contiguous_offset INTEGER NOT NULL DEFAULT 0,
              state TEXT NOT NULL,
              last_accessed_at TEXT NOT NULL,
              protected_until TEXT,
              PRIMARY KEY (media_id, variant)
            );
            INSERT INTO media_cache_entries (
              media_id, variant, encrypted_path, byte_size, cached_bytes,
              contiguous_offset, state, last_accessed_at, protected_until
            )
            SELECT media_id, variant, encrypted_path, byte_size, cached_bytes,
                   contiguous_offset, state, last_accessed_at, protected_until
            FROM media_cache_entries_v7;
            DROP TABLE media_cache_entries_v7;
            CREATE INDEX media_cache_lru_idx
              ON media_cache_entries(protected_until, last_accessed_at);
            """)
        }

        migrator.registerMigration("v9-groups") { db in
            let dialogColumns = try db.columns(in: "dialogs").map(\.name)
            if !dialogColumns.contains("revision") {
                try db.execute(sql: "ALTER TABLE dialogs ADD COLUMN revision INTEGER NOT NULL DEFAULT 0")
            }
            if !dialogColumns.contains("photo_media_json") {
                try db.execute(sql: "ALTER TABLE dialogs ADD COLUMN photo_media_json TEXT")
            }
            if !dialogColumns.contains("member_count") {
                try db.execute(sql: "ALTER TABLE dialogs ADD COLUMN member_count INTEGER NOT NULL DEFAULT 0")
            }
            if !dialogColumns.contains("self_role") {
                try db.execute(sql: "ALTER TABLE dialogs ADD COLUMN self_role TEXT")
            }
            if !dialogColumns.contains("notification_mode") {
                try db.execute(sql: "ALTER TABLE dialogs ADD COLUMN notification_mode TEXT NOT NULL DEFAULT 'all'")
            }
            if !dialogColumns.contains("access_state") {
                try db.execute(
                    sql: """
                    ALTER TABLE dialogs ADD COLUMN access_state TEXT NOT NULL DEFAULT 'active'
                      CHECK (access_state IN ('pending','active','removed','left','closed'))
                    """
                )
            }

            let memberColumns = try db.columns(in: "dialog_members").map(\.name)
            if !memberColumns.contains("joined_at") {
                try db.execute(sql: "ALTER TABLE dialog_members ADD COLUMN joined_at TEXT")
            }
            if !memberColumns.contains("left_at") {
                try db.execute(sql: "ALTER TABLE dialog_members ADD COLUMN left_at TEXT")
            }
            if !memberColumns.contains("is_active") {
                try db.execute(sql: "ALTER TABLE dialog_members ADD COLUMN is_active INTEGER NOT NULL DEFAULT 1")
            }
            if !memberColumns.contains("revision") {
                try db.execute(sql: "ALTER TABLE dialog_members ADD COLUMN revision INTEGER NOT NULL DEFAULT 0")
            }
            if !memberColumns.contains("seen_generation") {
                try db.execute(sql: "ALTER TABLE dialog_members ADD COLUMN seen_generation TEXT")
            }

            let messageColumns = try db.columns(in: "messages").map(\.name)
            if !messageColumns.contains("service_type") {
                try db.execute(sql: "ALTER TABLE messages ADD COLUMN service_type TEXT")
            }
            if !messageColumns.contains("service_data_json") {
                try db.execute(sql: "ALTER TABLE messages ADD COLUMN service_data_json TEXT")
            }
            if !messageColumns.contains("mentions_json") {
                try db.execute(sql: "ALTER TABLE messages ADD COLUMN mentions_json TEXT NOT NULL DEFAULT '[]'")
            }

            let groupOutboxColumns = try db.columns(in: "pending_outbox").map(\.name)
            if !groupOutboxColumns.contains("mentions_json") {
                try db.execute(
                    sql: "ALTER TABLE pending_outbox ADD COLUMN mentions_json TEXT NOT NULL DEFAULT '[]'"
                )
            }

            let mediaTransferColumns = try db.columns(in: "media_transfers").map(\.name)
            if !mediaTransferColumns.contains("purpose") {
                try db.execute(
                    sql: "ALTER TABLE media_transfers ADD COLUMN purpose TEXT NOT NULL DEFAULT 'message'"
                )
            }

            let unreadColumns = try db.columns(in: "dialog_unread_summaries").map(\.name)
            if !unreadColumns.contains("mention_count") {
                try db.execute(
                    sql: "ALTER TABLE dialog_unread_summaries ADD COLUMN mention_count INTEGER NOT NULL DEFAULT 0"
                )
            }

            try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS pending_group_creations (
              group_id TEXT PRIMARY KEY,
              title TEXT NOT NULL,
              member_ids_json TEXT NOT NULL,
              local_photo_reference TEXT,
              state TEXT NOT NULL CHECK (state IN ('queued','creating','failed','active')),
              retry_count INTEGER NOT NULL DEFAULT 0,
              next_retry_at TEXT,
              last_error TEXT,
              terminal INTEGER NOT NULL DEFAULT 0,
              created_at TEXT NOT NULL,
              updated_at TEXT NOT NULL
            );
            CREATE INDEX IF NOT EXISTS pending_group_creations_ready_idx
              ON pending_group_creations(terminal, next_retry_at, created_at);

            CREATE TABLE IF NOT EXISTS pending_group_mutations (
              client_mutation_id TEXT PRIMARY KEY,
              dialog_id TEXT NOT NULL,
              operation TEXT NOT NULL,
              payload_json TEXT NOT NULL,
              retry_count INTEGER NOT NULL DEFAULT 0,
              next_retry_at TEXT,
              last_error TEXT,
              terminal INTEGER NOT NULL DEFAULT 0,
              created_at TEXT NOT NULL
            );
            CREATE INDEX IF NOT EXISTS pending_group_mutations_ready_idx
              ON pending_group_mutations(terminal, next_retry_at, created_at);

            CREATE TABLE IF NOT EXISTS message_mentions (
              dialog_id TEXT NOT NULL,
              msg_id INTEGER NOT NULL,
              account_id TEXT NOT NULL,
              entity_offset INTEGER NOT NULL,
              length INTEGER NOT NULL,
              PRIMARY KEY (dialog_id, msg_id, account_id)
            );
            CREATE INDEX IF NOT EXISTS message_mentions_account_idx
              ON message_mentions(account_id, dialog_id, msg_id);

            CREATE TABLE IF NOT EXISTS group_member_hydration (
              dialog_id TEXT PRIMARY KEY,
              scan_generation TEXT NOT NULL,
              scan_revision INTEGER NOT NULL,
              cursor TEXT,
              completed INTEGER NOT NULL DEFAULT 0,
              attempts INTEGER NOT NULL DEFAULT 0,
              updated_at TEXT NOT NULL
            );

            CREATE TABLE IF NOT EXISTS pending_purges (
              id TEXT PRIMARY KEY,
              dialog_id TEXT NOT NULL,
              kind TEXT NOT NULL CHECK (kind IN ('messages','media')),
              payload TEXT,
              created_at TEXT NOT NULL,
              attempts INTEGER NOT NULL DEFAULT 0
            );
            CREATE INDEX IF NOT EXISTS pending_purges_dialog_idx
              ON pending_purges(dialog_id, created_at);
            """)
        }

        migrator.registerMigration("v10-access-purge-state-machine") { db in
            try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS pending_access_purges (
              id TEXT PRIMARY KEY,
              dialog_id TEXT NOT NULL UNIQUE,
              all_media_ids_json TEXT NOT NULL,
              purge_media_ids_json TEXT NOT NULL,
              encrypted_paths_json TEXT NOT NULL,
              phase TEXT NOT NULL CHECK (phase IN ('staged','files_deleted')),
              attempts INTEGER NOT NULL DEFAULT 0,
              created_at TEXT NOT NULL,
              updated_at TEXT NOT NULL
            );
            CREATE INDEX IF NOT EXISTS pending_access_purges_ready_idx
              ON pending_access_purges(phase, created_at, id);
            """)

            // Upgrade interrupted v9 purges without dropping their durable intent. Media shared by
            // another dialog is excluded from physical deletion.
            let legacyDialogs = try String.fetchAll(
                db,
                sql: "SELECT DISTINCT dialog_id FROM pending_purges ORDER BY dialog_id"
            )
            for dialogId in legacyDialogs {
                let payload = try String.fetchOne(
                    db,
                    sql: """
                    SELECT payload FROM pending_purges
                    WHERE dialog_id = ? AND kind = 'media'
                    ORDER BY created_at LIMIT 1
                    """,
                    arguments: [dialogId]
                )
                let allMediaIds = decodeStringSet(payload)
                let purgeMediaIds = try Set(allMediaIds.filter { mediaId in
                    try !Bool.fetchOne(
                        db,
                        sql: """
                        SELECT EXISTS (
                          SELECT 1 FROM message_media
                          WHERE media_id = ? AND dialog_id <> ?
                        )
                        """,
                        arguments: [mediaId, dialogId]
                    )!
                })
                let encryptedPaths = try String.fetchAll(
                    db,
                    sql: """
                    SELECT encrypted_path FROM media_cache_entries
                    WHERE media_id IN (
                      SELECT value FROM json_each(?)
                    )
                    UNION
                    SELECT encrypted_source_path FROM media_transfers WHERE dialog_id = ?
                    UNION
                    SELECT encrypted_thumbnail_path FROM media_transfers
                    WHERE dialog_id = ? AND encrypted_thumbnail_path IS NOT NULL
                    """,
                    arguments: [
                        encodeStringSet(purgeMediaIds), dialogId, dialogId,
                    ]
                )
                try db.execute(
                    sql: """
                    INSERT OR IGNORE INTO pending_access_purges (
                      id, dialog_id, all_media_ids_json, purge_media_ids_json,
                      encrypted_paths_json, phase, attempts, created_at, updated_at
                    ) VALUES (?, ?, ?, ?, ?, 'staged', 0, datetime('now'), datetime('now'))
                    """,
                    arguments: [
                        UUID().uuidString.lowercased(), dialogId,
                        encodeStringSet(allMediaIds), encodeStringSet(purgeMediaIds),
                        encodeStringSet(Set(encryptedPaths)),
                    ]
                )
            }
        }

        migrator.registerMigration("v11-access-revocation-fences") { db in
            let purgeColumns = try db.columns(in: "pending_access_purges").map(\.name)
            if !purgeColumns.contains("last_error") {
                try db.execute(
                    sql: "ALTER TABLE pending_access_purges ADD COLUMN last_error TEXT"
                )
            }
            try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS revoked_dialogs (
              dialog_id TEXT PRIMARY KEY,
              dialog_type TEXT,
              revoked_pts INTEGER NOT NULL,
              created_at TEXT NOT NULL
            );
            """)
        }

        migrator.registerMigration("v12-dialog-access-generations") { db in
            try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS dialog_access_generations (
              dialog_id TEXT PRIMARY KEY,
              generation INTEGER NOT NULL,
              authorized INTEGER NOT NULL CHECK (authorized IN (0, 1)),
              dialog_type TEXT,
              last_pts INTEGER NOT NULL
            );

            INSERT OR IGNORE INTO dialog_access_generations (
              dialog_id, generation, authorized, dialog_type, last_pts
            )
            SELECT dialog_id, 1, 0, dialog_type, revoked_pts
            FROM revoked_dialogs;
            """)
        }

        migrator.registerMigration("v10-cloud-drafts-and-media-groups") { db in
            let messageColumns = try db.columns(in: "messages").map(\.name)
            if !messageColumns.contains("media_group_id") {
                try db.execute(sql: "ALTER TABLE messages ADD COLUMN media_group_id TEXT")
            }
            if !messageColumns.contains("media_group_index") {
                try db.execute(sql: "ALTER TABLE messages ADD COLUMN media_group_index INTEGER")
            }
            if !messageColumns.contains("media_group_count") {
                try db.execute(sql: "ALTER TABLE messages ADD COLUMN media_group_count INTEGER")
            }
            let outboxColumns = try db.columns(in: "pending_outbox").map(\.name)
            if !outboxColumns.contains("draft_consume_operation_id") {
                try db.execute(sql: "ALTER TABLE pending_outbox ADD COLUMN draft_consume_operation_id TEXT")
            }
            let transferColumns = try db.columns(in: "media_transfers").map(\.name)
            if !transferColumns.contains("draft_attachment_id") {
                try db.execute(sql: "ALTER TABLE media_transfers ADD COLUMN draft_attachment_id TEXT")
            }
            if !transferColumns.contains("draft_operation_id") {
                try db.execute(sql: "ALTER TABLE media_transfers ADD COLUMN draft_operation_id TEXT")
            }
            if !transferColumns.contains("mentions_json") {
                try db.execute(
                    sql: "ALTER TABLE media_transfers ADD COLUMN mentions_json TEXT NOT NULL DEFAULT '[]'"
                )
            }
            let stagedDialogColumns = try db.columns(in: "bootstrap_staged_dialogs").map(\.name)
            if !stagedDialogColumns.contains("draft_json") {
                try db.execute(sql: "ALTER TABLE bootstrap_staged_dialogs ADD COLUMN draft_json TEXT")
            }

            try db.execute(sql: """
            CREATE INDEX IF NOT EXISTS messages_media_group_idx
              ON messages(dialog_id, media_group_id, media_group_index)
              WHERE media_group_id IS NOT NULL;

            CREATE TABLE IF NOT EXISTS drafts (
              account_id TEXT NOT NULL,
              dialog_id TEXT NOT NULL,
              state TEXT NOT NULL CHECK (state IN ('active','cleared')),
              text TEXT NOT NULL,
              reply_to_msg_id INTEGER,
              reply_preview_json TEXT,
              mentions_json TEXT NOT NULL DEFAULT '[]',
              local_generation INTEGER NOT NULL DEFAULT 0,
              operation_id TEXT NOT NULL,
              server_revision INTEGER NOT NULL DEFAULT 0,
              server_shadow_json TEXT,
              consumed_operation_id TEXT,
              terminal INTEGER NOT NULL DEFAULT 0,
              last_error TEXT,
              updated_at TEXT NOT NULL,
              PRIMARY KEY (account_id, dialog_id)
            );
            CREATE INDEX IF NOT EXISTS drafts_dialog_idx
              ON drafts(dialog_id, account_id);
            CREATE INDEX IF NOT EXISTS drafts_updated_idx
              ON drafts(updated_at DESC, dialog_id);

            CREATE TABLE IF NOT EXISTS draft_attachments (
              account_id TEXT NOT NULL,
              dialog_id TEXT NOT NULL,
              attachment_id TEXT NOT NULL,
              media_id TEXT,
              position INTEGER NOT NULL CHECK (position BETWEEN 0 AND 9),
              media_json TEXT,
              transfer_id TEXT,
              state TEXT NOT NULL CHECK (
                state IN ('staging','uploading','ready','failed','terminal')
              ),
              progress REAL NOT NULL DEFAULT 0,
              last_error TEXT,
              PRIMARY KEY (account_id, dialog_id, attachment_id)
            );
            CREATE INDEX IF NOT EXISTS draft_attachments_transfer_idx
              ON draft_attachments(transfer_id);
            CREATE INDEX IF NOT EXISTS draft_attachments_media_idx
              ON draft_attachments(media_id);

            CREATE TABLE IF NOT EXISTS pending_draft_mutations (
              account_id TEXT NOT NULL,
              dialog_id TEXT NOT NULL,
              operation_id TEXT NOT NULL UNIQUE,
              local_generation INTEGER NOT NULL,
              payload_json TEXT NOT NULL,
              retry_count INTEGER NOT NULL DEFAULT 0,
              next_retry_at TEXT,
              last_error TEXT,
              terminal INTEGER NOT NULL DEFAULT 0,
              updated_at TEXT NOT NULL,
              PRIMARY KEY (account_id, dialog_id)
            );
            CREATE INDEX IF NOT EXISTS pending_draft_mutations_ready_idx
              ON pending_draft_mutations(terminal, next_retry_at, updated_at);

            CREATE TABLE IF NOT EXISTS pending_media_group_sends (
              client_group_id TEXT PRIMARY KEY,
              account_id TEXT NOT NULL,
              dialog_id TEXT NOT NULL,
              payload_json TEXT NOT NULL,
              draft_consume_operation_id TEXT,
              retry_count INTEGER NOT NULL DEFAULT 0,
              next_retry_at TEXT,
              last_error TEXT,
              terminal INTEGER NOT NULL DEFAULT 0,
              created_at TEXT NOT NULL
            );
            CREATE INDEX IF NOT EXISTS pending_media_group_sends_ready_idx
              ON pending_media_group_sends(terminal, next_retry_at, created_at);
            """)
        }

        migrator.registerMigration("v11-cloud-draft-launch-hardening") { db in
            try db.execute(sql: """
            UPDATE draft_attachments AS attachment
            SET position = (
              SELECT COUNT(*)
              FROM draft_attachments AS earlier
              WHERE earlier.account_id = attachment.account_id
                AND earlier.dialog_id = attachment.dialog_id
                AND (
                  earlier.position < attachment.position
                  OR (
                    earlier.position = attachment.position
                    AND earlier.attachment_id < attachment.attachment_id
                  )
                )
            );
            """)
            try db.execute(sql: """
            CREATE UNIQUE INDEX IF NOT EXISTS draft_attachments_position_unique_idx
              ON draft_attachments(account_id, dialog_id, position);

            CREATE TABLE IF NOT EXISTS pending_draft_dependencies (
              account_id TEXT NOT NULL,
              dialog_id TEXT NOT NULL,
              operation_id TEXT PRIMARY KEY,
              local_generation INTEGER NOT NULL,
              payload_json TEXT NOT NULL,
              retry_count INTEGER NOT NULL DEFAULT 0,
              next_retry_at TEXT,
              last_error TEXT,
              terminal INTEGER NOT NULL DEFAULT 0,
              updated_at TEXT NOT NULL
            );
            CREATE INDEX IF NOT EXISTS pending_draft_dependencies_ready_idx
              ON pending_draft_dependencies(terminal, next_retry_at, updated_at);

            CREATE TABLE IF NOT EXISTS pending_media_group_cleanup (
              client_group_id TEXT PRIMARY KEY,
              transfer_ids_json TEXT NOT NULL,
              created_at TEXT NOT NULL,
              last_error TEXT
            );
            """)
        }

        migrator.registerMigration("v10-dialog-preferences") { db in
            try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS dialog_preferences (
              account_id TEXT NOT NULL,
              dialog_id TEXT NOT NULL REFERENCES dialogs(dialog_id) ON DELETE CASCADE,
              is_pinned INTEGER NOT NULL DEFAULT 0 CHECK (is_pinned IN (0, 1)),
              pinned_at TEXT,
              is_muted INTEGER NOT NULL DEFAULT 0 CHECK (is_muted IN (0, 1)),
              is_archived INTEGER NOT NULL DEFAULT 0 CHECK (is_archived IN (0, 1)),
              server_updated_at TEXT NOT NULL,
              PRIMARY KEY (account_id, dialog_id)
            );
            CREATE INDEX IF NOT EXISTS dialog_preferences_account_idx
              ON dialog_preferences(account_id, dialog_id);

            CREATE TABLE IF NOT EXISTS pending_dialog_preference_mutations (
              account_id TEXT NOT NULL,
              dialog_id TEXT NOT NULL REFERENCES dialogs(dialog_id) ON DELETE CASCADE,
              field TEXT NOT NULL CHECK (field IN ('pinned','muted','archived')),
              desired_value INTEGER NOT NULL CHECK (desired_value IN (0, 1)),
              desired_at TEXT NOT NULL,
              client_mutation_id TEXT NOT NULL,
              acknowledged_pts INTEGER,
              retry_count INTEGER NOT NULL DEFAULT 0,
              next_retry_at TEXT,
              last_error TEXT,
              terminal INTEGER NOT NULL DEFAULT 0,
              PRIMARY KEY (account_id, dialog_id, field),
              UNIQUE (account_id, client_mutation_id)
            );
            CREATE INDEX IF NOT EXISTS pending_dialog_preferences_ready_idx
              ON pending_dialog_preference_mutations(
                terminal, acknowledged_pts, next_retry_at, desired_at
              );

            INSERT INTO dialog_preferences (
              account_id, dialog_id, is_pinned, pinned_at,
              is_muted, is_archived, server_updated_at
            )
            SELECT
              sync.account_id, dialog.dialog_id, 0, NULL,
              dialog.notification_mode = 'muted', 0, dialog.updated_at
            FROM dialogs dialog
            CROSS JOIN sync_state sync
            WHERE 1
            ON CONFLICT(account_id, dialog_id) DO NOTHING;

            INSERT INTO pending_dialog_preference_mutations (
              account_id, dialog_id, field, desired_value, desired_at,
              client_mutation_id, retry_count, next_retry_at, last_error, terminal
            )
            SELECT
              sync.account_id,
              pending.dialog_id,
              'muted',
              CASE json_extract(pending.payload_json, '$.mode')
                WHEN 'muted' THEN 1 ELSE 0
              END,
              pending.created_at,
              pending.client_mutation_id,
              pending.retry_count,
              pending.next_retry_at,
              pending.last_error,
              pending.terminal
            FROM pending_group_mutations pending
            CROSS JOIN sync_state sync
            WHERE pending.operation = 'notifications'
            ON CONFLICT(account_id, dialog_id, field) DO UPDATE SET
              desired_value = excluded.desired_value,
              desired_at = excluded.desired_at,
              client_mutation_id = excluded.client_mutation_id,
              acknowledged_pts = NULL,
              retry_count = excluded.retry_count,
              next_retry_at = excluded.next_retry_at,
              last_error = excluded.last_error,
              terminal = excluded.terminal;

            DELETE FROM pending_group_mutations
            WHERE operation = 'notifications'
              AND EXISTS(SELECT 1 FROM sync_state);
            """)

            let stagedColumns = try db.columns(in: "bootstrap_staged_dialogs").map(\.name)
            if !stagedColumns.contains("preference_is_pinned") {
                try db.execute(
                    sql: "ALTER TABLE bootstrap_staged_dialogs ADD COLUMN preference_is_pinned INTEGER"
                )
            }
            if !stagedColumns.contains("preference_pinned_at") {
                try db.execute(
                    sql: "ALTER TABLE bootstrap_staged_dialogs ADD COLUMN preference_pinned_at TEXT"
                )
            }
            if !stagedColumns.contains("preference_is_muted") {
                try db.execute(
                    sql: "ALTER TABLE bootstrap_staged_dialogs ADD COLUMN preference_is_muted INTEGER"
                )
            }
            if !stagedColumns.contains("preference_is_archived") {
                try db.execute(
                    sql: "ALTER TABLE bootstrap_staged_dialogs ADD COLUMN preference_is_archived INTEGER"
                )
            }
            if !stagedColumns.contains("preference_updated_at") {
                try db.execute(
                    sql: "ALTER TABLE bootstrap_staged_dialogs ADD COLUMN preference_updated_at TEXT"
                )
            }
        }

        migrator.registerMigration("v11-ordered-preference-outbox") { db in
            try db.execute(sql: """
            CREATE TEMP TABLE mutation_order_seed AS
            SELECT domain, mutation_id, sort_at,
                   row_number() OVER (
                     ORDER BY sort_at, domain, mutation_id
                   ) AS local_order
            FROM (
              SELECT 'preference' AS domain,
                     client_mutation_id AS mutation_id,
                     desired_at AS sort_at
              FROM pending_dialog_preference_mutations
              UNION ALL
              SELECT 'group' AS domain,
                     client_mutation_id AS mutation_id,
                     created_at AS sort_at
              FROM pending_group_mutations
            );

            CREATE TABLE pending_dialog_preference_mutations_v11 (
              account_id TEXT NOT NULL,
              dialog_id TEXT NOT NULL REFERENCES dialogs(dialog_id) ON DELETE CASCADE,
              field TEXT NOT NULL CHECK (field IN ('pinned','muted','archived')),
              desired_value INTEGER NOT NULL CHECK (desired_value IN (0, 1)),
              desired_at TEXT NOT NULL,
              client_mutation_id TEXT PRIMARY KEY,
              acknowledged_pts INTEGER,
              retry_count INTEGER NOT NULL DEFAULT 0,
              next_retry_at TEXT,
              last_error TEXT,
              terminal INTEGER NOT NULL DEFAULT 0,
              local_order INTEGER NOT NULL,
              attempted_at TEXT,
              dormant INTEGER NOT NULL DEFAULT 0 CHECK (dormant IN (0, 1))
            );
            INSERT INTO pending_dialog_preference_mutations_v11 (
              account_id, dialog_id, field, desired_value, desired_at,
              client_mutation_id, acknowledged_pts, retry_count, next_retry_at,
              last_error, terminal, local_order, attempted_at, dormant
            )
            SELECT
              pending.account_id, pending.dialog_id, pending.field,
              pending.desired_value, pending.desired_at,
              pending.client_mutation_id, pending.acknowledged_pts,
              pending.retry_count, pending.next_retry_at, pending.last_error,
              pending.terminal, seed.local_order,
              CASE WHEN pending.retry_count > 0 THEN pending.desired_at END,
              0
            FROM pending_dialog_preference_mutations pending
            JOIN mutation_order_seed seed
              ON seed.domain = 'preference'
             AND seed.mutation_id = pending.client_mutation_id;
            DROP TABLE pending_dialog_preference_mutations;
            ALTER TABLE pending_dialog_preference_mutations_v11
              RENAME TO pending_dialog_preference_mutations;
            CREATE INDEX pending_dialog_preferences_ready_idx
              ON pending_dialog_preference_mutations(
                account_id, terminal, dormant, acknowledged_pts,
                next_retry_at, local_order
              );
            CREATE INDEX pending_dialog_preferences_overlay_idx
              ON pending_dialog_preference_mutations(
                account_id, dialog_id, field, terminal, local_order DESC
              );

            ALTER TABLE pending_group_mutations
              ADD COLUMN local_order INTEGER NOT NULL DEFAULT 0;
            ALTER TABLE pending_group_mutations
              ADD COLUMN attempted_at TEXT;
            UPDATE pending_group_mutations
            SET local_order = (
                  SELECT seed.local_order
                  FROM mutation_order_seed seed
                  WHERE seed.domain = 'group'
                    AND seed.mutation_id = pending_group_mutations.client_mutation_id
                ),
                attempted_at = CASE
                  WHEN retry_count > 0 THEN created_at
                  ELSE attempted_at
                END;
            DROP INDEX IF EXISTS pending_group_mutations_ready_idx;
            CREATE INDEX pending_group_mutations_ready_idx
              ON pending_group_mutations(
                terminal, next_retry_at, local_order
              );

            CREATE TABLE local_mutation_sequence (
              singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
              next_order INTEGER NOT NULL
            );
            INSERT INTO local_mutation_sequence (singleton, next_order)
            SELECT 1, COALESCE(MAX(local_order), 0) + 1
            FROM mutation_order_seed;
            DROP TABLE mutation_order_seed;
            """)
        }

        migrator.registerMigration("v12-silent-message-outbox") { db in
            let columns = try db.columns(in: "pending_outbox").map(\.name)
            if !columns.contains("silent") {
                try db.execute(
                    sql: "ALTER TABLE pending_outbox ADD COLUMN silent INTEGER NOT NULL DEFAULT 0"
                )
            }
        }

        migrator.registerMigration("v13-cloud-productivity") { db in
            let columns = try db.columns(in: "messages").map(\.name)
            if !columns.contains("link_preview_json") {
                try db.execute(sql: "ALTER TABLE messages ADD COLUMN link_preview_json TEXT")
            }
            try db.execute(sql: """
            CREATE TABLE cloud_chat_folder_state (
              account_id TEXT PRIMARY KEY,
              collection_revision INTEGER NOT NULL,
              snapshot_json TEXT NOT NULL,
              updated_at TEXT NOT NULL DEFAULT (datetime('now'))
            );
            CREATE TABLE cloud_scheduled_deliveries (
              schedule_id TEXT PRIMARY KEY,
              account_id TEXT NOT NULL,
              dialog_id TEXT NOT NULL,
              state TEXT NOT NULL,
              deliver_at TEXT NOT NULL,
              revision INTEGER NOT NULL,
              payload_json TEXT NOT NULL,
              updated_at TEXT NOT NULL
            );
            CREATE INDEX cloud_scheduled_deliveries_account_time_idx
              ON cloud_scheduled_deliveries(account_id, deliver_at, schedule_id);
            CREATE TABLE pending_scheduled_delivery_creates (
              schedule_id TEXT PRIMARY KEY,
              account_id TEXT NOT NULL,
              dialog_id TEXT NOT NULL,
              request_json TEXT NOT NULL,
              draft_operation_id TEXT,
              retry_count INTEGER NOT NULL DEFAULT 0,
              next_retry_at TEXT,
              last_error TEXT,
              terminal INTEGER NOT NULL DEFAULT 0,
              created_at TEXT NOT NULL
            );
            CREATE INDEX pending_scheduled_delivery_creates_ready_idx
              ON pending_scheduled_delivery_creates(account_id, terminal, next_retry_at, created_at);
            """)
        }

        migrator.registerMigration("v14-cloud-productivity-durable-mutations") { db in
            let transferColumns = try db.columns(in: "media_transfers").map(\.name)
            if !transferColumns.contains("silent") {
                try db.execute(
                    sql: "ALTER TABLE media_transfers ADD COLUMN silent INTEGER NOT NULL DEFAULT 0"
                )
            }
            let createColumns = try db.columns(in: "pending_scheduled_delivery_creates").map(\.name)
            if !createColumns.contains("attempted_at") {
                try db.execute(
                    sql: "ALTER TABLE pending_scheduled_delivery_creates ADD COLUMN attempted_at TEXT"
                )
            }
            if !createColumns.contains("error_acknowledged") {
                try db.execute(
                    sql: "ALTER TABLE pending_scheduled_delivery_creates ADD COLUMN error_acknowledged INTEGER NOT NULL DEFAULT 0"
                )
            }
            // v13 queued a create immediately after staging it, but had no durable commit-point
            // marker. Treat every surviving v13 row as possibly attempted so an upgrade can never
            // delete a server-accepted schedule as a local-only draft.
            try db.execute(
                sql: """
                UPDATE pending_scheduled_delivery_creates
                SET attempted_at = COALESCE(attempted_at, created_at)
                """
            )
            try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS cloud_scheduled_delivery_state (
              account_id TEXT PRIMARY KEY,
              collection_revision INTEGER NOT NULL,
              updated_at TEXT NOT NULL DEFAULT (datetime('now'))
            );
            CREATE TABLE IF NOT EXISTS pending_chat_folder_mutations (
              local_operation_id TEXT PRIMARY KEY,
              account_id TEXT NOT NULL,
              folder_id TEXT NOT NULL,
              operation TEXT NOT NULL CHECK (operation IN ('create','update','delete','move')),
              intent_json TEXT NOT NULL,
              client_mutation_id TEXT,
              request_json TEXT,
              retry_count INTEGER NOT NULL DEFAULT 0,
              next_retry_at TEXT,
              attempted_at TEXT,
              last_error TEXT,
              terminal INTEGER NOT NULL DEFAULT 0,
              error_acknowledged INTEGER NOT NULL DEFAULT 0,
              local_order INTEGER NOT NULL,
              created_at TEXT NOT NULL
            );
            CREATE INDEX IF NOT EXISTS pending_chat_folder_mutations_ready_idx
              ON pending_chat_folder_mutations(
                account_id, terminal, next_retry_at, local_order
              );
            CREATE TABLE IF NOT EXISTS pending_scheduled_delivery_mutations (
              local_operation_id TEXT PRIMARY KEY,
              account_id TEXT NOT NULL,
              schedule_id TEXT NOT NULL,
              operation TEXT NOT NULL CHECK (operation IN ('cancel','reschedule')),
              intent_json TEXT NOT NULL,
              client_mutation_id TEXT,
              request_json TEXT,
              retry_count INTEGER NOT NULL DEFAULT 0,
              next_retry_at TEXT,
              attempted_at TEXT,
              last_error TEXT,
              terminal INTEGER NOT NULL DEFAULT 0,
              error_acknowledged INTEGER NOT NULL DEFAULT 0,
              local_order INTEGER NOT NULL,
              created_at TEXT NOT NULL
            );
            CREATE INDEX IF NOT EXISTS pending_scheduled_delivery_mutations_ready_idx
              ON pending_scheduled_delivery_mutations(
                account_id, terminal, operation, next_retry_at, local_order
              );
            CREATE INDEX IF NOT EXISTS pending_scheduled_delivery_mutations_head_idx
              ON pending_scheduled_delivery_mutations(
                account_id, schedule_id, terminal, operation, local_order, next_retry_at
              );
            """)
        }

        migrator.registerMigration("v15-presence-cache") { db in
            try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS peer_presence_cache (
              observer_account_id TEXT NOT NULL,
              subject_account_id TEXT NOT NULL,
              last_seen_at TEXT,
              revision INTEGER NOT NULL DEFAULT 0,
              updated_at TEXT NOT NULL,
              PRIMARY KEY (observer_account_id, subject_account_id)
            );
            CREATE INDEX IF NOT EXISTS peer_presence_cache_observer_idx
              ON peer_presence_cache(observer_account_id, updated_at DESC);
            """)
        }

        migrator.registerMigration("v16-profile-photos") { db in
            let profileColumns = try db.columns(in: "profiles").map(\.name)
            if !profileColumns.contains("photo_media_json") {
                try db.execute(sql: "ALTER TABLE profiles ADD COLUMN photo_media_json TEXT")
            }
            if !profileColumns.contains("photo_revision") {
                try db.execute(sql: "ALTER TABLE profiles ADD COLUMN photo_revision INTEGER NOT NULL DEFAULT 0")
            }
            try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS pending_profile_photo_mutations (
              account_id TEXT PRIMARY KEY,
              client_mutation_id TEXT NOT NULL UNIQUE,
              base_photo_revision INTEGER NOT NULL CHECK (base_photo_revision >= 0),
              operation TEXT NOT NULL CHECK (operation IN ('set','remove')),
              transfer_id TEXT UNIQUE,
              media_id TEXT,
              source TEXT NOT NULL CHECK (source IN ('user','legacy')),
              state TEXT NOT NULL CHECK (state IN ('pending','ready_to_commit','conflict')),
              retry_count INTEGER NOT NULL DEFAULT 0,
              next_retry_at TEXT,
              last_error TEXT,
              terminal INTEGER NOT NULL DEFAULT 0,
              created_at TEXT NOT NULL,
              updated_at TEXT NOT NULL
            );
            CREATE INDEX IF NOT EXISTS pending_profile_photo_ready_idx
              ON pending_profile_photo_mutations(account_id, terminal, state, next_retry_at);
            """)
        }

        migrator.registerMigration("v17-profile-photo-lookup-index") { db in
            // Avatar authorization and revocation start from an immutable media ID. Index the
            // JSON projection so each visible avatar does not scan the full profile cache.
            try db.execute(sql: """
            CREATE INDEX IF NOT EXISTS profiles_photo_media_id_idx
              ON profiles(json_extract(photo_media_json, '$.id'))
              WHERE photo_media_json IS NOT NULL;
            """)
        }

        SearchIndexSchema.registerMigration(in: &migrator)

        try migrator.migrate(dbPool)
    }
}
