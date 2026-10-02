import Foundation
import GRDB
import os
import Security

extension CloudLocalStore {
    func insertMediaTransfer(
        prepared: PreparedMediaUpload, dialogId: String, clientMsgId: String,
        caption: String, replyToMsgId: Int64?, purpose: String = "message"
    ) throws {
        try dbQueue.write { db in
            guard try !Self.isDialogRevoked(db, dialogId: dialogId) else {
                throw CloudLocalStoreAccessError.revoked
            }
            try db.execute(
                sql: """
                INSERT INTO media_transfers (
                  transfer_id, dialog_id, client_msg_id, caption, reply_to_msg_id,
                  purpose, kind, content_type, file_name, byte_size, sha256, duration_ms, width, height,
                  encrypted_source_path, encrypted_thumbnail_path, state, created_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'pending', datetime('now'))
                ON CONFLICT(transfer_id) DO NOTHING
                """,
                arguments: [
                    prepared.transferId, dialogId, clientMsgId, caption, replyToMsgId, purpose,
                    prepared.kind, prepared.contentType, prepared.fileName, prepared.byteSize,
                    prepared.sha256, prepared.durationMs, prepared.width, prepared.height,
                    prepared.encryptedSourcePath, prepared.encryptedThumbnailPath
                ]
            )
        }
    }

    func updateMediaTransfer(
        transferId: String, mediaId: String?, uploadOffset: Int64,
        state: String, error: String?, retryAfter: TimeInterval? = nil
    ) throws {
        let next = retryAfter.map { Self.sqliteTimestamp(Date().addingTimeInterval($0)) }
        try dbQueue.write { db in
            try db.execute(
                sql: """
                UPDATE media_transfers
                SET media_id = COALESCE(?, media_id), upload_offset = ?, state = ?,
                    last_error = ?, next_retry_at = ?,
                    retry_count = retry_count + CASE WHEN ? IS NULL THEN 0 ELSE 1 END
                WHERE transfer_id = ?
                """,
                arguments: [mediaId, uploadOffset, state, error, next, retryAfter, transferId]
            )
        }
    }

    func markMediaRetrying(clientMsgId: String) throws {
        try dbQueue.write { db in
            let dialogId = try String.fetchOne(
                db, sql: "SELECT dialog_id FROM messages WHERE client_msg_id = ?", arguments: [clientMsgId]
            )
            try db.execute(
                sql: "UPDATE media_transfers SET next_retry_at = NULL, last_error = NULL, terminal = 0 WHERE client_msg_id = ?",
                arguments: [clientMsgId]
            )
            if let dialogId { try refreshDialogSummary(db, dialogId: dialogId) }
            try db.execute(
                sql: "UPDATE messages SET local_state = 'sending' WHERE client_msg_id = ?",
                arguments: [clientMsgId]
            )
        }
    }

    func resetMediaUpload(transferId: String) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                UPDATE media_transfers
                SET media_id = NULL, upload_offset = 0, state = 'pending',
                    next_retry_at = NULL, last_error = NULL
                WHERE transfer_id = ?
                """,
                arguments: [transferId]
            )
        }
    }

    func mediaTransfersReady(
        now: Date = Date(),
        limit: Int = 10,
        includeCloudDraftDependencies: Bool = true
    ) throws -> [MediaTransferRecord] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT media_transfers.* FROM media_transfers
                LEFT JOIN dialogs ON dialogs.dialog_id = media_transfers.dialog_id
                WHERE media_transfers.terminal = 0
                  AND media_transfers.purpose <> 'group_send'
                  AND NOT (
                    media_transfers.purpose = 'draft'
                    AND media_transfers.state = 'ready_to_send'
                  )
                  AND (? OR media_transfers.draft_operation_id IS NULL)
                  AND COALESCE(dialogs.access_state, 'active') <> 'pending'
                  AND (media_transfers.next_retry_at IS NULL OR media_transfers.next_retry_at <= ?)
                ORDER BY media_transfers.created_at, media_transfers.transfer_id LIMIT ?
                """,
                arguments: [includeCloudDraftDependencies, Self.sqliteTimestamp(now), limit]
            )
            return rows.map(Self.mediaTransfer(from:))
        }
    }

    func nextMediaTransferDelay(
        now: Date = Date(),
        includeCloudDraftDependencies: Bool = true
    ) throws -> TimeInterval? {
        let nowText = Self.sqliteTimestamp(now)
        return try dbQueue.read { db in
            let due = try Int.fetchOne(
                db,
                sql: """
                SELECT COUNT(*) FROM media_transfers
                LEFT JOIN dialogs ON dialogs.dialog_id = media_transfers.dialog_id
                WHERE media_transfers.terminal = 0
                  AND media_transfers.purpose <> 'group_send'
                  AND NOT (
                    media_transfers.purpose = 'draft'
                    AND media_transfers.state = 'ready_to_send'
                  )
                  AND (? OR media_transfers.draft_operation_id IS NULL)
                  AND COALESCE(dialogs.access_state, 'active') <> 'pending'
                  AND (media_transfers.next_retry_at IS NULL OR media_transfers.next_retry_at <= ?)
                """,
                arguments: [includeCloudDraftDependencies, nowText]
            ) ?? 0
            if due > 0 { return 0 }
            guard let next = try String.fetchOne(
                db,
                sql: """
                SELECT MIN(media_transfers.next_retry_at) FROM media_transfers
                LEFT JOIN dialogs ON dialogs.dialog_id = media_transfers.dialog_id
                WHERE media_transfers.terminal = 0
                  AND media_transfers.purpose <> 'group_send'
                  AND NOT (
                    media_transfers.purpose = 'draft'
                    AND media_transfers.state = 'ready_to_send'
                  )
                  AND (? OR media_transfers.draft_operation_id IS NULL)
                  AND COALESCE(dialogs.access_state, 'active') <> 'pending'
                  AND media_transfers.next_retry_at > ?
                """,
                arguments: [includeCloudDraftDependencies, nowText]
            ), let date = Self.makeSQLiteDateFormatter().date(from: next) else { return nil }
            return max(0, date.timeIntervalSince(now))
        }
    }

    func mediaTransfer(id: String) throws -> MediaTransferRecord? {
        try dbQueue.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM media_transfers WHERE transfer_id = ?", arguments: [id])
                .map(Self.mediaTransfer(from:))
        }
    }

    func debugSQLiteTotalChanges() throws -> Int {
        try dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT total_changes()") ?? 0
        }
    }

    func mediaTransfer(clientMsgId: String) throws -> MediaTransferRecord? {
        try dbQueue.read { db in
            try Row.fetchOne(
                db,
                sql: "SELECT * FROM media_transfers WHERE client_msg_id = ? LIMIT 1",
                arguments: [clientMsgId]
            ).map(Self.mediaTransfer(from:))
        }
    }

    func mediaTransfers(dialogId: String) throws -> [MediaTransferRecord] {
        try dbQueue.read { db in
            try Row.fetchAll(
                db,
                sql: "SELECT * FROM media_transfers WHERE dialog_id = ? ORDER BY created_at, transfer_id",
                arguments: [dialogId]
            ).map(Self.mediaTransfer(from:))
        }
    }

    func completeMediaTransfer(transferId: String) throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM media_transfers WHERE transfer_id = ?", arguments: [transferId])
        }
    }

    func cancelMediaTransfer(transferId: String, clientMsgId: String) throws {
        try dbQueue.write { db in
            // Remove the durable outbox row and its optimistic bubble atomically. A later retry can
            // therefore never resurrect a transfer the user explicitly cancelled.
            try db.execute(sql: "DELETE FROM media_transfers WHERE transfer_id = ?", arguments: [transferId])
            let pendingRow = try Row.fetchOne(
                db,
                sql: "SELECT local_id, dialog_id FROM messages WHERE client_msg_id = ? AND msg_id IS NULL",
                arguments: [clientMsgId]
            )
            if let localId: String = pendingRow?["local_id"] {
                try db.execute(sql: "DELETE FROM message_media WHERE local_id = ?", arguments: [localId])
            }
            try db.execute(
                sql: "DELETE FROM messages WHERE client_msg_id = ? AND msg_id IS NULL",
                arguments: [clientMsgId]
            )
            if let dialogId: String = pendingRow?["dialog_id"] {
                try refreshDialogSummary(db, dialogId: dialogId)
                try refreshAllUnreadSummaries(db, dialogId: dialogId)
            }
        }
    }

    func insertSendingMedia(_ transfer: MediaTransferRecord, senderAccountId: String) throws {
        try dbQueue.write { db in
            guard try !Self.isDialogRevoked(db, dialogId: transfer.dialogId) else {
                throw CloudLocalStoreAccessError.revoked
            }
            try upsertSendingMedia(db, transfer: transfer, senderAccountId: senderAccountId)
        }
    }
}
