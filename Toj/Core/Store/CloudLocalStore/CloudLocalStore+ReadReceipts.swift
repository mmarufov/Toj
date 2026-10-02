import Foundation
import GRDB
import os
import Security

extension CloudLocalStore {
    func markRead(
        dialogId: String,
        accountId: String,
        maxReadMsgId: Int64,
        exactUnreadCount: Int? = nil
    ) throws {
        try dbQueue.write { db in
            try markRead(
                db,
                dialogId: dialogId,
                accountId: accountId,
                maxReadMsgId: maxReadMsgId,
                exactUnreadCount: exactUnreadCount
            )
        }
    }

    /// Advances the UI watermark and durably queues its server acknowledgement in one transaction.
    func queueReadReceipt(dialogId: String, accountId: String, maxReadMsgId: Int64) throws {
        try dbQueue.write { db in
            try markRead(db, dialogId: dialogId, accountId: accountId, maxReadMsgId: maxReadMsgId)
            try db.execute(
                sql: """
                INSERT INTO pending_read_receipts (
                  dialog_id, account_id, max_read_msg_id, retry_count,
                  next_retry_at, last_error, updated_at
                ) VALUES (?, ?, ?, 0, NULL, NULL, datetime('now'))
                ON CONFLICT(dialog_id, account_id) DO UPDATE SET
                  max_read_msg_id = MAX(
                    pending_read_receipts.max_read_msg_id,
                    excluded.max_read_msg_id
                  ),
                  retry_count = CASE
                    WHEN excluded.max_read_msg_id > pending_read_receipts.max_read_msg_id THEN 0
                    ELSE pending_read_receipts.retry_count
                  END,
                  next_retry_at = NULL,
                  last_error = NULL,
                  updated_at = excluded.updated_at
                """,
                arguments: [dialogId, accountId, maxReadMsgId]
            )
        }
    }

    func pendingReadReceiptsReady(limit: Int = 50) throws -> [PendingReadReceipt] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT dialog_id, account_id, max_read_msg_id, retry_count, next_retry_at
                FROM pending_read_receipts
                WHERE next_retry_at IS NULL OR next_retry_at <= datetime('now')
                ORDER BY updated_at, dialog_id
                LIMIT ?
                """,
                arguments: [max(1, min(limit, 200))]
            )
            return rows.map { row in
                PendingReadReceipt(
                    dialogId: row["dialog_id"],
                    accountId: row["account_id"],
                    maxReadMsgId: row["max_read_msg_id"],
                    retryCount: row["retry_count"],
                    nextRetryAt: row["next_retry_at"]
                )
            }
        }
    }

    func completeReadReceipt(
        dialogId: String,
        accountId: String,
        acknowledgedMsgId: Int64
    ) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                DELETE FROM pending_read_receipts
                WHERE dialog_id = ? AND account_id = ? AND max_read_msg_id <= ?
                """,
                arguments: [dialogId, accountId, acknowledgedMsgId]
            )
        }
    }

    func failReadReceipt(
        dialogId: String,
        accountId: String,
        retryAfter: TimeInterval,
        error: String? = nil,
        attemptedMsgId: Int64? = nil
    ) throws {
        let nextRetryAt = Self.sqliteTimestamp(Date().addingTimeInterval(max(1, retryAfter)))
        try dbQueue.write { db in
            try db.execute(
                sql: """
                UPDATE pending_read_receipts
                SET retry_count = retry_count + 1,
                    next_retry_at = ?, last_error = ?, updated_at = datetime('now')
                WHERE dialog_id = ? AND account_id = ?
                  AND (? IS NULL OR max_read_msg_id <= ?)
                """,
                arguments: [
                    nextRetryAt, error, dialogId, accountId,
                    attemptedMsgId, attemptedMsgId,
                ]
            )
        }
    }

    func markRead(
        _ db: Database,
        dialogId: String,
        accountId: String,
        maxReadMsgId: Int64,
        exactUnreadCount: Int? = nil
    ) throws {
        let previousMaxRead = try Int64.fetchOne(
            db,
            sql: """
            SELECT last_read_msg_id FROM dialog_members
            WHERE dialog_id = ? AND account_id = ?
            """,
            arguments: [dialogId, accountId]
        ) ?? 0
        try db.execute(
            sql: """
            INSERT INTO dialog_members (dialog_id, account_id, role, last_read_msg_id)
            VALUES (?, ?, 'member', ?)
            ON CONFLICT(dialog_id, account_id) DO UPDATE SET
              last_read_msg_id = MAX(dialog_members.last_read_msg_id, excluded.last_read_msg_id)
            """,
            arguments: [dialogId, accountId, maxReadMsgId]
        )
        if let exactUnreadCount {
            try setUnreadSummary(
                db,
                dialogId: dialogId,
                accountId: accountId,
                unreadCount: exactUnreadCount,
                isExact: true
            )
        } else if try Bool.fetchOne(
            db,
            sql: """
            SELECT is_exact FROM dialog_unread_summaries
            WHERE dialog_id = ? AND account_id = ?
            """,
            arguments: [dialogId, accountId]
        ) == true {
            let locallyCovered = try Int.fetchOne(
                db,
                sql: """
                SELECT COUNT(*) FROM messages
                WHERE dialog_id = ?
                  AND msg_id > ? AND msg_id <= ?
                  AND sender_account_id != ?
                  AND state = 'visible'
                """,
                arguments: [dialogId, previousMaxRead, maxReadMsgId, accountId]
            ) ?? 0
            try adjustUnreadSummary(
                db,
                dialogId: dialogId,
                accountId: accountId,
                delta: -locallyCovered
            )
        } else {
            try refreshUnreadSummary(db, dialogId: dialogId, accountId: accountId)
        }
    }
}
