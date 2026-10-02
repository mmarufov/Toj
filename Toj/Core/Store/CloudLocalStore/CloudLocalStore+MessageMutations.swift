import Foundation
import GRDB
import os
import Security

extension CloudLocalStore {
    func applyMessageMutation(_ response: MessageMutationResponse) throws {
        try dbQueue.write { db in
            guard try !Self.isDialogRevoked(db, dialogId: response.message.dialogId) else { return }
            try upsertMessage(db, message: response.message, localState: "sent")
        }
    }

    func enqueueMessageMutation(
        clientMutationId: String,
        operation: String,
        dialogId: String,
        msgId: Int64,
        body: String? = nil,
        expectedEditVersion: Int? = nil,
        emoji: String? = nil
    ) throws {
        try dbQueue.write { db in
            guard try !Self.isDialogRevoked(db, dialogId: dialogId) else {
                throw CloudLocalStoreAccessError.revoked
            }
            try db.execute(
                sql: """
                INSERT INTO pending_message_mutations (
                  client_mutation_id, operation, dialog_id, msg_id, body,
                  expected_edit_version, emoji, created_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, datetime('now'))
                ON CONFLICT(client_mutation_id) DO NOTHING
                """,
                arguments: [
                    clientMutationId, operation, dialogId, msgId, body,
                    expectedEditVersion, emoji
                ]
            )
            try refreshDialogSummary(db, dialogId: dialogId)
        }
    }

    func messageMutations(dialogId: String) throws -> [PendingMessageMutation] {
        try dbQueue.read { db in
            try Row.fetchAll(
                db,
                sql: """
                SELECT * FROM pending_message_mutations
                WHERE dialog_id = ?
                ORDER BY created_at, client_mutation_id
                """,
                arguments: [dialogId]
            ).map(Self.messageMutation(from:))
        }
    }

    func pendingMessageMutationsReady(now: Date = Date(), limit: Int = 20) throws -> [PendingMessageMutation] {
        try dbQueue.read { db in
            try Row.fetchAll(
                db,
                sql: """
                SELECT * FROM pending_message_mutations
                WHERE terminal = 0 AND (next_retry_at IS NULL OR next_retry_at <= ?)
                ORDER BY created_at, client_mutation_id
                LIMIT ?
                """,
                arguments: [Self.sqliteTimestamp(now), limit]
            ).map(Self.messageMutation(from:))
        }
    }

    func markMessageMutationFailed(
        clientMutationId: String,
        error: String,
        retryAfter: TimeInterval?,
        terminal: Bool
    ) throws {
        let next = retryAfter.map { Self.sqliteTimestamp(Date().addingTimeInterval($0)) }
        try dbQueue.write { db in
            try db.execute(
                sql: """
                UPDATE pending_message_mutations
                SET retry_count = retry_count + 1, next_retry_at = ?, last_error = ?, terminal = ?
                WHERE client_mutation_id = ?
                """,
                arguments: [next, error, terminal, clientMutationId]
            )
        }
    }

    func retryMessageMutation(clientMutationId: String) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                UPDATE pending_message_mutations
                SET next_retry_at = NULL, last_error = NULL, terminal = 0
                WHERE client_mutation_id = ?
                """,
                arguments: [clientMutationId]
            )
        }
    }

    func completeMessageMutation(clientMutationId: String) throws {
        try dbQueue.write { db in
            let dialogId = try String.fetchOne(
                db,
                sql: "SELECT dialog_id FROM pending_message_mutations WHERE client_mutation_id = ?",
                arguments: [clientMutationId]
            )
            try db.execute(
                sql: "DELETE FROM pending_message_mutations WHERE client_mutation_id = ?",
                arguments: [clientMutationId]
            )
            if let dialogId { try refreshDialogSummary(db, dialogId: dialogId) }
        }
    }

    func nextMessageMutationDelay(now: Date = Date()) throws -> TimeInterval? {
        let nowText = Self.sqliteTimestamp(now)
        return try dbQueue.read { db in
            let due = try Int.fetchOne(
                db,
                sql: """
                SELECT COUNT(*) FROM pending_message_mutations
                WHERE terminal = 0 AND (next_retry_at IS NULL OR next_retry_at <= ?)
                """,
                arguments: [nowText]
            ) ?? 0
            if due > 0 { return 0 }
            guard let next = try String.fetchOne(
                db,
                sql: """
                SELECT MIN(next_retry_at) FROM pending_message_mutations
                WHERE terminal = 0 AND next_retry_at > ?
                """,
                arguments: [nowText]
            ), let date = Self.makeSQLiteDateFormatter().date(from: next) else { return nil }
            return max(0, date.timeIntervalSince(now))
        }
    }

    func markMediaTerminal(clientMsgId: String, error: String) throws {
        try dbQueue.write { db in
            let dialogId = try String.fetchOne(
                db, sql: "SELECT dialog_id FROM messages WHERE client_msg_id = ?", arguments: [clientMsgId]
            )
            try db.execute(
                sql: """
                UPDATE media_transfers
                SET terminal = 1, next_retry_at = NULL, last_error = ?
                WHERE client_msg_id = ?
                """,
                arguments: [error, clientMsgId]
            )
            try db.execute(
                sql: "UPDATE messages SET local_state = 'failed' WHERE client_msg_id = ?",
                arguments: [clientMsgId]
            )
            if let dialogId { try refreshDialogSummary(db, dialogId: dialogId) }
        }
    }
}
