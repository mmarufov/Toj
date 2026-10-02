import Foundation
import GRDB
import os
import Security

extension CloudLocalStore {
    func drainPendingPurges(limit: Int = 20) throws -> Int {
        try dbQueue.write { db in
            let purges = try Row.fetchAll(
                db,
                sql: "SELECT * FROM pending_purges ORDER BY created_at LIMIT ?",
                arguments: [max(1, min(100, limit))]
            )
            for purge in purges {
                let id: String = purge["id"]
                let dialogId: String = purge["dialog_id"]
                let kind: String = purge["kind"]
                if kind == "messages" {
                    try db.execute(
                        sql: "DELETE FROM messages WHERE dialog_id = ?",
                        arguments: [dialogId]
                    )
                    try db.execute(
                        sql: "DELETE FROM message_media WHERE dialog_id = ?",
                        arguments: [dialogId]
                    )
                } else {
                    let payload: String? = purge["payload"]
                    let mediaIds = payload?
                        .data(using: .utf8)
                        .flatMap { try? JSONDecoder().decode([String].self, from: $0) } ?? []
                    for mediaId in mediaIds {
                        try db.execute(
                            sql: "DELETE FROM media_cache_entries WHERE media_id = ?",
                            arguments: [mediaId]
                        )
                        try db.execute(
                            sql: "DELETE FROM media_download_jobs WHERE media_id = ?",
                            arguments: [mediaId]
                        )
                    }
                }
                try db.execute(
                    sql: "DELETE FROM pending_purges WHERE id = ?",
                    arguments: [id]
                )
            }
            return purges.count
        }
    }

    func pendingAccessPurgeJobs(
        limit: Int = 20,
        excluding excludedIds: Set<String> = []
    ) throws -> [AccessPurgeJob] {
        try dbQueue.read { db in
            try Row.fetchAll(
                db,
                sql: """
                SELECT id, dialog_id, all_media_ids_json, purge_media_ids_json,
                       encrypted_paths_json, phase, attempts, last_error
                FROM pending_access_purges
                WHERE id NOT IN (SELECT value FROM json_each(?))
                ORDER BY created_at, id
                LIMIT ?
                """,
                arguments: [
                    Self.encodeStringSet(excludedIds),
                    max(1, min(100, limit)),
                ]
            ).compactMap(Self.accessPurgeJob(from:))
        }
    }

    func pendingAccessPurgeCount() throws -> Int {
        try dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT count(*) FROM pending_access_purges") ?? 0
        }
    }

    /// Re-snapshots revocation state after UI/network media tasks have been cancelled and awaited.
    /// This closes the window where an in-flight upload persisted its encrypted path after the
    /// original difference transaction staged the purge.
    func refreshAccessPurgeJob(id: String) throws -> AccessPurgeJob? {
        try dbQueue.write { db in
            guard let row = try Row.fetchOne(
                db,
                sql: """
                SELECT id, dialog_id, all_media_ids_json, purge_media_ids_json,
                       encrypted_paths_json, phase, attempts, last_error
                FROM pending_access_purges WHERE id = ?
                """,
                arguments: [id]
            ) else { return nil }
            guard AccessPurgePhase(rawValue: row["phase"]) == .staged else {
                return Self.accessPurgeJob(from: row)
            }
            let dialogId: String = row["dialog_id"]
            let previousMediaIds = Self.decodeStringSet(row["all_media_ids_json"])
            let currentMediaIds = Set(try String.fetchAll(
                db,
                sql: """
                SELECT DISTINCT media_id FROM message_media WHERE dialog_id = ?
                UNION
                SELECT DISTINCT json_extract(profile.photo_media_json, '$.id')
                FROM profiles profile
                JOIN dialog_members current_member
                  ON current_member.account_id = profile.account_id
                 AND current_member.dialog_id = ?
                WHERE profile.photo_media_json IS NOT NULL
                  AND NOT EXISTS (
                    SELECT 1
                    FROM dialog_members other_member
                    JOIN dialogs other_dialog ON other_dialog.dialog_id = other_member.dialog_id
                    WHERE other_member.account_id = profile.account_id
                      AND other_member.dialog_id <> ?
                      AND other_member.is_active = 1
                      AND other_dialog.access_state = 'active'
                  )
                """,
                arguments: [dialogId, dialogId, dialogId]
            ))
            let allMediaIds = previousMediaIds.union(currentMediaIds)
            let purgeMediaIds = try Set(allMediaIds.filter { mediaId in
                try !Bool.fetchOne(
                    db,
                    sql: """
                    SELECT EXISTS (
                      SELECT 1 FROM message_media
                      WHERE media_id = ? AND dialog_id <> ?
                      UNION ALL
                      SELECT 1
                      FROM profiles profile
                      JOIN dialog_members member ON member.account_id = profile.account_id
                      JOIN dialogs dialog ON dialog.dialog_id = member.dialog_id
                      WHERE json_extract(profile.photo_media_json, '$.id') = ?
                        AND member.dialog_id <> ?
                        AND member.is_active = 1
                        AND dialog.access_state = 'active'
                    )
                    """,
                    arguments: [mediaId, dialogId, mediaId, dialogId]
                )!
            })
            let previousPaths = Self.decodeStringSet(row["encrypted_paths_json"])
            let allCachePaths = Set(try String.fetchAll(
                db,
                sql: """
                SELECT encrypted_path FROM media_cache_entries
                WHERE media_id IN (SELECT value FROM json_each(?))
                """,
                arguments: [Self.encodeStringSet(allMediaIds)]
            ))
            let currentPaths = Set(try String.fetchAll(
                db,
                sql: """
                SELECT encrypted_path FROM media_cache_entries
                WHERE media_id IN (SELECT value FROM json_each(?))
                UNION
                SELECT encrypted_source_path FROM media_transfers WHERE dialog_id = ?
                UNION
                SELECT encrypted_thumbnail_path FROM media_transfers
                WHERE dialog_id = ? AND encrypted_thumbnail_path IS NOT NULL
                """,
                arguments: [
                    Self.encodeStringSet(purgeMediaIds), dialogId, dialogId,
                ]
            ))
            // Keep prior upload paths after their rows were zeroed, but re-derive cache paths so a
            // late forwarded reference can turn an originally-exclusive media object into shared.
            let encryptedPaths = previousPaths.subtracting(allCachePaths).union(currentPaths)
            try db.execute(
                sql: """
                UPDATE pending_access_purges
                SET all_media_ids_json = ?, purge_media_ids_json = ?,
                    encrypted_paths_json = ?, updated_at = datetime('now')
                WHERE id = ? AND phase = 'staged'
                """,
                arguments: [
                    Self.encodeStringSet(allMediaIds), Self.encodeStringSet(purgeMediaIds),
                    Self.encodeStringSet(encryptedPaths), id,
                ]
            )

            let pendingLocalIds = try String.fetchAll(
                db,
                sql: "SELECT local_id FROM messages WHERE dialog_id = ? AND msg_id IS NULL",
                arguments: [dialogId]
            )
            for localId in pendingLocalIds {
                try db.execute(
                    sql: "DELETE FROM message_media WHERE local_id = ?",
                    arguments: [localId]
                )
            }
            try db.execute(
                sql: "DELETE FROM messages WHERE dialog_id = ? AND msg_id IS NULL",
                arguments: [dialogId]
            )
            for table in [
                "pending_outbox", "media_transfers", "pending_message_mutations",
                "pending_group_mutations", "media_download_jobs",
            ] {
                try db.execute(
                    sql: "DELETE FROM \(table) WHERE dialog_id = ?",
                    arguments: [dialogId]
                )
            }
            return AccessPurgeJob(
                id: id,
                dialogId: dialogId,
                allMediaIds: allMediaIds,
                purgeMediaIds: purgeMediaIds,
                encryptedPaths: encryptedPaths,
                phase: .staged,
                attempts: row["attempts"],
                lastError: row["last_error"]
            )
        }
    }

    func markAccessPurgeFailed(id: String, error: String) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                UPDATE pending_access_purges
                SET attempts = attempts + 1, last_error = ?, updated_at = datetime('now')
                WHERE id = ?
                """,
                arguments: [String(error.prefix(1_000)), id]
            )
        }
    }

    func markAccessPurgeFilesDeleted(id: String) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                UPDATE pending_access_purges
                SET phase = 'files_deleted', attempts = attempts + 1, last_error = NULL,
                    updated_at = datetime('now')
                WHERE id = ? AND phase = 'staged'
                """,
                arguments: [id]
            )
        }
    }

    func finalizeAccessPurge(id: String) throws {
        try dbQueue.write { db in
            guard let row = try Row.fetchOne(
                db,
                sql: """
                SELECT dialog_id, purge_media_ids_json
                FROM pending_access_purges
                WHERE id = ? AND phase = 'files_deleted'
                """,
                arguments: [id]
            ) else { return }
            let dialogId: String = row["dialog_id"]
            let purgeMediaIds = Self.decodeStringSet(row["purge_media_ids_json"])
            for mediaId in purgeMediaIds {
                try db.execute(
                    sql: "DELETE FROM media_cache_entries WHERE media_id = ?",
                    arguments: [mediaId]
                )
                try db.execute(
                    sql: "DELETE FROM media_download_jobs WHERE media_id = ?",
                    arguments: [mediaId]
                )
            }
            for table in [
                "message_reactions", "message_mentions", "message_media", "messages",
                "dialog_members", "dialog_unread_summaries", "dialog_summaries",
                "pending_outbox", "pending_read_receipts", "chat_viewport_state",
                "dialog_history_state", "group_member_hydration", "pending_group_mutations",
                "media_transfers", "media_download_jobs", "bootstrap_baseline_dialogs",
                "bootstrap_staged_messages", "bootstrap_staged_members",
                "bootstrap_staged_dialogs", "pending_purges",
            ] {
                try db.execute(
                    sql: "DELETE FROM \(table) WHERE dialog_id = ?",
                    arguments: [dialogId]
                )
            }
            try db.execute(
                sql: "DELETE FROM pending_group_creations WHERE group_id = ?",
                arguments: [dialogId]
            )
            try db.execute(sql: "DELETE FROM dialogs WHERE dialog_id = ?", arguments: [dialogId])
            try db.execute(sql: "DELETE FROM pending_access_purges WHERE id = ?", arguments: [id])
        }
    }
}
