import Foundation
import GRDB
import os
import Security

extension CloudLocalStore {
    func messageMedia(localId: String) throws -> MessageMediaRecord? {
        try dbQueue.read { db in
            try Row.fetchOne(
                db,
                sql: "SELECT * FROM message_media WHERE local_id = ?",
                arguments: [localId]
            ).map(Self.messageMedia(from:))
        }
    }

    func messageMedia(mediaId: String) throws -> [MessageMediaRecord] {
        try dbQueue.read { db in
            try Row.fetchAll(
                db,
                sql: "SELECT * FROM message_media WHERE media_id = ? ORDER BY dialog_id, msg_id",
                arguments: [mediaId]
            ).map(Self.messageMedia(from:))
        }
    }

    func mediaChatClass(dialogId: String) throws -> MediaChatClass {
        try dbQueue.read { db in
            let type = try String.fetchOne(
                db,
                sql: "SELECT type FROM dialogs WHERE dialog_id = ?",
                arguments: [dialogId]
            )
            return type == "group" ? .group : .privateChat
        }
    }

    func mediaIds(dialogId: String) throws -> Set<String> {
        try dbQueue.read { db in
            Set(try String.fetchAll(
                db,
                sql: "SELECT DISTINCT media_id FROM message_media WHERE dialog_id = ?",
                arguments: [dialogId]
            ))
        }
    }

    func mediaIds(kind: String) throws -> Set<String> {
        try dbQueue.read { db in
            Set(try String.fetchAll(
                db,
                sql: "SELECT DISTINCT media_id FROM message_media WHERE kind = ?",
                arguments: [kind]
            ))
        }
    }

    func upsertMediaCacheEntry(_ entry: MediaCacheEntry) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                INSERT INTO media_cache_entries (
                  media_id, variant, encrypted_path, byte_size, cached_bytes,
                  contiguous_offset, state, last_accessed_at, protected_until
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(media_id, variant) DO UPDATE SET
                  encrypted_path = excluded.encrypted_path,
                  byte_size = excluded.byte_size,
                  cached_bytes = excluded.cached_bytes,
                  contiguous_offset = excluded.contiguous_offset,
                  state = excluded.state,
                  last_accessed_at = excluded.last_accessed_at,
                  protected_until = excluded.protected_until
                """,
                arguments: [
                    entry.mediaId, entry.variant, entry.encryptedPath, entry.byteSize,
                    entry.cachedBytes, entry.contiguousOffset, entry.state,
                    entry.lastAccessedAt, entry.protectedUntil
                ]
            )
        }
    }

    func mediaCacheEntry(mediaId: String, variant: String) throws -> MediaCacheEntry? {
        try dbQueue.read { db in
            try Row.fetchOne(
                db,
                sql: "SELECT * FROM media_cache_entries WHERE media_id = ? AND variant = ?",
                arguments: [mediaId, variant]
            ).map(Self.mediaCacheEntry(from:))
        }
    }

    /// Returns the durable cache ledger in least-recently-used order. Passing an eviction date
    /// filters out entries whose active-use protection has not expired.
    func mediaCacheEntries(evictableAt date: Date? = nil) throws -> [MediaCacheEntry] {
        try dbQueue.read { db in
            let rows: [Row]
            if let date {
                rows = try Row.fetchAll(
                    db,
                    sql: """
                    SELECT * FROM media_cache_entries
                    WHERE protected_until IS NULL OR protected_until <= ?
                    ORDER BY last_accessed_at, media_id, variant
                    """,
                    arguments: [Self.sqliteTimestamp(date)]
                )
            } else {
                rows = try Row.fetchAll(
                    db,
                    sql: "SELECT * FROM media_cache_entries ORDER BY last_accessed_at, media_id, variant"
                )
            }
            return rows.map(Self.mediaCacheEntry(from:))
        }
    }

    func touchMediaCacheEntry(mediaId: String, variant: String, at date: Date = Date()) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                UPDATE media_cache_entries SET last_accessed_at = ?
                WHERE media_id = ? AND variant = ?
                """,
                arguments: [Self.sqliteTimestamp(date), mediaId, variant]
            )
        }
    }

    func removeMediaCacheEntry(mediaId: String, variant: String) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "DELETE FROM media_cache_entries WHERE media_id = ? AND variant = ?",
                arguments: [mediaId, variant]
            )
        }
    }

    func removeMediaCacheEntries(keys: Set<MediaCacheLedgerKey>) throws {
        guard !keys.isEmpty else { return }
        try dbQueue.write { db in
            for key in keys {
                try db.execute(
                    sql: "DELETE FROM media_cache_entries WHERE media_id = ? AND variant = ?",
                    arguments: [key.mediaId, key.variant]
                )
            }
        }
    }

    func removeMediaCacheEntries(mediaIds: [String]) throws {
        guard !mediaIds.isEmpty else { return }
        try dbQueue.write { db in
            for mediaId in Set(mediaIds) {
                try db.execute(sql: "DELETE FROM media_cache_entries WHERE media_id = ?", arguments: [mediaId])
            }
        }
    }

    func downloadedMediaUsageBytes() throws -> Int64 {
        try dbQueue.read { db in
            try Int64.fetchOne(db, sql: "SELECT COALESCE(SUM(cached_bytes), 0) FROM media_cache_entries") ?? 0
        }
    }

    func upsertMediaDownloadJob(_ job: MediaDownloadJobRecord) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                INSERT INTO media_download_jobs (
                  media_id, variant, dialog_id, priority, state, user_initiated,
                  retry_count, next_retry_at, last_error, updated_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(media_id, variant) DO UPDATE SET
                  dialog_id = COALESCE(excluded.dialog_id, media_download_jobs.dialog_id),
                  priority = MAX(media_download_jobs.priority, excluded.priority),
                  state = excluded.state,
                  user_initiated = MAX(media_download_jobs.user_initiated, excluded.user_initiated),
                  retry_count = excluded.retry_count,
                  next_retry_at = excluded.next_retry_at,
                  last_error = excluded.last_error,
                  updated_at = excluded.updated_at
                """,
                arguments: [
                    job.mediaId, job.variant, job.dialogId, job.priority, job.state.rawValue,
                    job.userInitiated, job.retryCount, job.nextRetryAt, job.lastError, job.updatedAt
                ]
            )
        }
    }

    /// Adds or reprioritizes an automatic download without making an in-flight claim visible to a
    /// second worker. State transitions after a claim use `upsertMediaDownloadJob(_:)` instead.
    func enqueueMediaDownloadJob(_ job: MediaDownloadJobRecord) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                INSERT INTO media_download_jobs (
                  media_id, variant, dialog_id, priority, state, user_initiated,
                  retry_count, next_retry_at, last_error, updated_at
                ) VALUES (?, ?, ?, ?, 'queued', ?, ?, ?, ?, ?)
                ON CONFLICT(media_id, variant) DO UPDATE SET
                  dialog_id = COALESCE(excluded.dialog_id, media_download_jobs.dialog_id),
                  priority = MAX(media_download_jobs.priority, excluded.priority),
                  state = CASE
                    WHEN media_download_jobs.state = 'downloading' THEN 'downloading'
                    ELSE 'queued'
                  END,
                  user_initiated = MAX(media_download_jobs.user_initiated, excluded.user_initiated),
                  retry_count = CASE
                    WHEN media_download_jobs.state = 'downloading' THEN media_download_jobs.retry_count
                    ELSE excluded.retry_count
                  END,
                  next_retry_at = CASE
                    WHEN media_download_jobs.state = 'downloading' THEN media_download_jobs.next_retry_at
                    ELSE excluded.next_retry_at
                  END,
                  last_error = CASE
                    WHEN media_download_jobs.state = 'downloading' THEN media_download_jobs.last_error
                    ELSE excluded.last_error
                  END,
                  updated_at = CASE
                    WHEN media_download_jobs.state = 'downloading' THEN media_download_jobs.updated_at
                    ELSE excluded.updated_at
                  END
                """,
                arguments: [
                    job.mediaId, job.variant, job.dialogId, job.priority,
                    job.userInitiated, job.retryCount, job.nextRetryAt, job.lastError, job.updatedAt
                ]
            )
        }
    }

    /// Claims exactly one ready job inside the writer transaction. Competing foreground and
    /// background drains therefore cannot both receive the same `(media_id, variant)` row.
    func claimNextMediaDownloadJob(
        variant: String? = nil,
        now: Date = Date()
    ) throws -> MediaDownloadJobRecord? {
        let nowText = Self.sqliteTimestamp(now)
        return try dbQueue.write { db in
            try Row.fetchOne(
                db,
                sql: """
                UPDATE media_download_jobs
                SET state = 'downloading', next_retry_at = NULL, last_error = NULL, updated_at = ?
                WHERE rowid = (
                  SELECT rowid
                  FROM media_download_jobs
                  WHERE state IN ('queued','failed')
                    AND (next_retry_at IS NULL OR next_retry_at <= ?)
                    AND (? IS NULL OR variant = ?)
                  ORDER BY user_initiated DESC, priority DESC, updated_at, media_id, variant
                  LIMIT 1
                )
                RETURNING *
                """,
                arguments: [nowText, nowText, variant, variant]
            ).map(Self.mediaDownloadJob(from:))
        }
    }

    /// A fresh process has no transfer capable of owning a persisted `.downloading` claim. Return
    /// every interrupted claim to the ready queue before workers start draining it.
    @discardableResult
    func recoverInterruptedMediaDownloadJobs(now: Date = Date()) throws -> Int {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                UPDATE media_download_jobs
                SET state = 'queued', next_retry_at = NULL, last_error = 'interrupted', updated_at = ?
                WHERE state = 'downloading'
                """,
                arguments: [Self.sqliteTimestamp(now)]
            )
            return db.changesCount
        }
    }

    /// Cancels future automatic work selected by a cache-clear action. A currently claimed
    /// transfer remains protected, as do media IDs with an active playback/share/export lease.
    @discardableResult
    func cancelMediaDownloadJobs(
        mediaIds: Set<String>? = nil,
        excluding protectedMediaIds: Set<String> = []
    ) throws -> Int {
        try dbQueue.write { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT media_id, variant, state FROM media_download_jobs"
            )
            var removed = 0
            for row in rows {
                let mediaId: String = row["media_id"]
                let state: String = row["state"]
                if let mediaIds, !mediaIds.contains(mediaId) { continue }
                guard state != MediaDownloadJobState.downloading.rawValue else { continue }
                guard !protectedMediaIds.contains(mediaId) else { continue }
                let variant: String = row["variant"]
                try db.execute(
                    sql: "DELETE FROM media_download_jobs WHERE media_id = ? AND variant = ?",
                    arguments: [mediaId, variant]
                )
                removed += db.changesCount
            }
            return removed
        }
    }

    func mediaDownloadJob(mediaId: String, variant: String) throws -> MediaDownloadJobRecord? {
        try dbQueue.read { db in
            try Row.fetchOne(
                db,
                sql: "SELECT * FROM media_download_jobs WHERE media_id = ? AND variant = ?",
                arguments: [mediaId, variant]
            ).map(Self.mediaDownloadJob(from:))
        }
    }

    func mediaDownloadJobsReady(now: Date = Date(), limit: Int = 20) throws -> [MediaDownloadJobRecord] {
        try dbQueue.read { db in
            try Row.fetchAll(
                db,
                sql: """
                SELECT * FROM media_download_jobs
                WHERE state IN ('queued','failed')
                  AND (next_retry_at IS NULL OR next_retry_at <= ?)
                ORDER BY user_initiated DESC, priority DESC, updated_at, media_id
                LIMIT ?
                """,
                arguments: [Self.sqliteTimestamp(now), max(1, limit)]
            ).map(Self.mediaDownloadJob(from:))
        }
    }

    func nextMediaDownloadRetryDate(now: Date = Date()) throws -> Date? {
        try dbQueue.read { db in
            guard let value = try String.fetchOne(
                db,
                sql: """
                SELECT MIN(next_retry_at)
                FROM media_download_jobs
                WHERE state IN ('queued','failed') AND next_retry_at > ?
                """,
                arguments: [Self.sqliteTimestamp(now)]
            ) else { return nil }
            return Self.makeSQLiteDateFormatter().date(from: value)
        }
    }

    func removeMediaDownloadJob(mediaId: String, variant: String) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "DELETE FROM media_download_jobs WHERE media_id = ? AND variant = ?",
                arguments: [mediaId, variant]
            )
        }
    }

    nonisolated static func upsertMessageMedia(
        _ db: Database,
        localId: String,
        dialogId: String,
        msgId: Int64?,
        media: CloudMedia
    ) throws {
        try db.execute(
            sql: """
            INSERT INTO message_media (
              local_id, dialog_id, msg_id, media_id, kind, content_type, file_name,
              byte_size, duration_ms, width, height, has_thumbnail
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(local_id) DO UPDATE SET
              dialog_id = excluded.dialog_id,
              msg_id = excluded.msg_id,
              media_id = excluded.media_id,
              kind = excluded.kind,
              content_type = excluded.content_type,
              file_name = excluded.file_name,
              byte_size = excluded.byte_size,
              duration_ms = excluded.duration_ms,
              width = excluded.width,
              height = excluded.height,
              has_thumbnail = excluded.has_thumbnail
            """,
            arguments: [
                localId, dialogId, msgId, media.id, media.kind, media.contentType,
                media.fileName, media.byteSize, media.durationMs, media.width, media.height,
                media.hasThumbnail
            ]
        )
    }

    func upsertSendingMedia(
        _ db: Database,
        transfer: MediaTransferRecord,
        senderAccountId: String
    ) throws {
        let mediaJSON = String(data: try JSONEncoder().encode(transfer.media), encoding: .utf8)
        try upsertDialog(
            db,
            dialogId: transfer.dialogId,
            type: "direct",
            title: nil,
            lastMsgId: 0,
            updatedAt: nil
        )
        try db.execute(
            sql: """
            INSERT INTO messages (
              local_id, dialog_id, msg_id, client_msg_id, sender_account_id, kind, text,
              reply_to_msg_id, is_forwarded, media_json, edit_version, state, server_ts, local_state
            ) VALUES (?, ?, NULL, ?, ?, ?, ?, ?, 0, ?, 0, 'visible', NULL, 'sending')
            ON CONFLICT(client_msg_id) DO UPDATE SET
              kind = excluded.kind,
              text = excluded.text,
              reply_to_msg_id = excluded.reply_to_msg_id,
              media_json = excluded.media_json,
              local_state = 'sending'
            """,
            arguments: [
                "pending:\(transfer.clientMsgId)", transfer.dialogId, transfer.clientMsgId,
                senderAccountId, transfer.kind, transfer.caption, transfer.replyToMsgId, mediaJSON,
            ]
        )
        try Self.upsertMessageMedia(
            db,
            localId: "pending:\(transfer.clientMsgId)",
            dialogId: transfer.dialogId,
            msgId: nil,
            media: transfer.media
        )
        try refreshDialogSummary(db, dialogId: transfer.dialogId)
        try refreshAllUnreadSummaries(db, dialogId: transfer.dialogId)
    }

    nonisolated static func historyState(from row: Row) -> DialogHistoryState {
        DialogHistoryState(
            dialogId: row["dialog_id"],
            ceilingMsgId: row["ceiling_msg_id"],
            nextBeforeMsgId: row["next_before_msg_id"],
            historyComplete: row["history_complete"],
            retryCount: row["retry_count"],
            nextRetryAt: row["next_retry_at"],
            updatedAt: row["updated_at"]
        )
    }

    nonisolated static func bootstrapState(from row: Row) -> ReplicaBootstrapState {
        ReplicaBootstrapState(
            accountId: row["account_id"],
            token: row["token"],
            nextCursor: row["next_cursor"],
            snapshotPts: row["snapshot_pts"],
            status: row["status"],
            mode: ReplicaBootstrapMode(rawValue: row["mode"]) ?? .initial,
            updatedAt: row["updated_at"]
        )
    }

    nonisolated private static func messageMedia(from row: Row) -> MessageMediaRecord {
        MessageMediaRecord(
            localId: row["local_id"],
            dialogId: row["dialog_id"],
            msgId: row["msg_id"],
            media: CloudMedia(
                id: row["media_id"],
                kind: row["kind"],
                contentType: row["content_type"],
                fileName: row["file_name"],
                byteSize: row["byte_size"],
                durationMs: row["duration_ms"],
                width: row["width"],
                height: row["height"],
                hasThumbnail: row["has_thumbnail"]
            )
        )
    }

    nonisolated private static func mediaCacheEntry(from row: Row) -> MediaCacheEntry {
        MediaCacheEntry(
            mediaId: row["media_id"], variant: row["variant"],
            encryptedPath: row["encrypted_path"], byteSize: row["byte_size"],
            cachedBytes: row["cached_bytes"], contiguousOffset: row["contiguous_offset"],
            state: row["state"], lastAccessedAt: row["last_accessed_at"],
            protectedUntil: row["protected_until"]
        )
    }

    nonisolated private static func mediaDownloadJob(from row: Row) -> MediaDownloadJobRecord {
        MediaDownloadJobRecord(
            mediaId: row["media_id"], variant: row["variant"], dialogId: row["dialog_id"],
            priority: row["priority"],
            state: MediaDownloadJobState(rawValue: row["state"]) ?? .failed,
            userInitiated: row["user_initiated"], retryCount: row["retry_count"],
            nextRetryAt: row["next_retry_at"], lastError: row["last_error"],
            updatedAt: row["updated_at"]
        )
    }
}
