import Foundation
import GRDB
import os
import Security

extension CloudLocalStore {
    /// Atomically converts a one-item draft into the existing resumable media outbox. The draft
    /// operation remains as a consume shield until the server confirms the matching revision.
    func consumeDraftAsSingleMedia(
        accountId: String,
        dialogId: String,
        operationId: String,
        silent: Bool = false
    ) throws -> MediaTransferRecord {
        try dbQueue.write { db in
            guard let draft = try Self.fetchDraft(db, accountId: accountId, dialogId: dialogId),
                  draft.operationId == operationId,
                  draft.state == "active",
                  draft.attachments.count == 1,
                  let attachment = draft.attachments.first,
                  attachment.state == "ready",
                  attachment.mediaId != nil,
                  let transferId = attachment.transferId else {
                throw CloudLocalStoreBootstrapError.invalidStagedMessage
            }
            let clientMsgId = UUID().uuidString.lowercased()
            let mentionsJSON = String(
                data: try JSONEncoder().encode(draft.mentions),
                encoding: .utf8
            ) ?? "[]"
            try db.execute(
                sql: """
                UPDATE media_transfers SET
                  client_msg_id = ?,
                  caption = ?,
                  reply_to_msg_id = ?,
                  mentions_json = ?,
                  silent = ?,
                  purpose = 'message',
                  draft_operation_id = ?,
                  state = 'ready_to_send',
                  terminal = 0,
                  last_error = NULL,
                  next_retry_at = NULL
                WHERE transfer_id = ? AND media_id IS NOT NULL
                """,
                arguments: [
                    clientMsgId, draft.text, draft.replyToMsgId, mentionsJSON, silent,
                    operationId, transferId,
                ]
            )
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT * FROM media_transfers WHERE transfer_id = ?",
                arguments: [transferId]
            ) else {
                throw CloudLocalStoreBootstrapError.invalidStagedMessage
            }
            let transfer = Self.mediaTransfer(from: row)
            try upsertSendingMedia(db, transfer: transfer, senderAccountId: accountId)
            try preserveDraftDependency(
                db,
                accountId: accountId,
                dialogId: dialogId,
                operationId: operationId
            )
            try db.execute(
                sql: """
                DELETE FROM pending_draft_mutations
                WHERE account_id = ? AND dialog_id = ? AND operation_id = ?
                """,
                arguments: [accountId, dialogId, operationId]
            )
            try markDraftConsumed(
                db,
                accountId: accountId,
                dialogId: dialogId,
                operationId: operationId
            )
            try db.execute(
                sql: "DELETE FROM draft_attachments WHERE account_id = ? AND dialog_id = ?",
                arguments: [accountId, dialogId]
            )
            try refreshDialogSummary(db, dialogId: dialogId)
            try refreshAllUnreadSummaries(db, dialogId: dialogId)
            return transfer
        }
    }

    /// Creates all optimistic album rows, the durable group request, and the consumed-draft shield
    /// in one transaction. A failed local commit therefore leaves the original draft untouched.
    func consumeDraftAsMediaGroup(
        accountId: String,
        dialogId: String,
        operationId: String,
        silent: Bool = false
    ) throws -> PendingMediaGroupSend {
        try dbQueue.write { db in
            guard let draft = try Self.fetchDraft(db, accountId: accountId, dialogId: dialogId),
                  draft.operationId == operationId,
                  draft.state == "active",
                  (2...10).contains(draft.attachments.count),
                  draft.attachments.allSatisfy({
                      $0.state == "ready" && $0.mediaId != nil && $0.transferId != nil && $0.media != nil
                  }) else {
                throw CloudLocalStoreBootstrapError.invalidStagedMessage
            }
            let ordered = draft.attachments.sorted { $0.position < $1.position }
            let clientGroupId = UUID().uuidString.lowercased()
            let items = ordered.map { attachment in
                PendingMediaGroupItem(
                    clientMsgId: UUID().uuidString.lowercased(),
                    mediaId: attachment.mediaId!,
                    transferId: attachment.transferId!,
                    media: attachment.media!
                )
            }
            let payload = PendingMediaGroupPayload(
                items: items,
                caption: draft.text,
                replyToMsgId: draft.replyToMsgId,
                mentions: draft.mentions,
                silent: silent
            )
            let encoder = JSONEncoder()
            let payloadJSON = String(data: try encoder.encode(payload), encoding: .utf8) ?? "{}"
            let mentionsJSON = String(data: try encoder.encode(draft.mentions), encoding: .utf8) ?? "[]"

            try upsertDialog(
                db,
                dialogId: dialogId,
                type: "direct",
                title: nil,
                lastMsgId: 0,
                updatedAt: nil
            )
            for (index, item) in items.enumerated() {
                let localId = "pending:\(item.clientMsgId)"
                let mediaJSON = String(data: try encoder.encode(item.media), encoding: .utf8)
                try db.execute(
                    sql: """
                    UPDATE media_transfers SET
                      client_msg_id = ?,
                      caption = ?,
                      reply_to_msg_id = ?,
                      silent = ?,
                      purpose = 'group_send',
                      draft_operation_id = ?,
                      state = 'ready_to_send',
                      terminal = 0,
                      last_error = NULL,
                      next_retry_at = NULL
                    WHERE transfer_id = ? AND media_id = ?
                    """,
                    arguments: [
                        item.clientMsgId, index == 0 ? draft.text : "",
                        index == 0 ? draft.replyToMsgId : nil, silent, operationId,
                        item.transferId, item.mediaId,
                    ]
                )
                try db.execute(
                    sql: """
                    INSERT INTO messages (
                      local_id, dialog_id, msg_id, client_msg_id, sender_account_id, kind, text,
                      reply_to_msg_id, is_forwarded, mentions_json, media_json,
                      media_group_id, media_group_index, media_group_count,
                      edit_version, state, server_ts, local_state
                    ) VALUES (?, ?, NULL, ?, ?, ?, ?, ?, 0, ?, ?, ?, ?, ?, 0, 'visible', NULL, 'sending')
                    ON CONFLICT(client_msg_id) DO NOTHING
                    """,
                    arguments: [
                        localId, dialogId, item.clientMsgId, accountId, item.media.kind,
                        index == 0 ? draft.text : "",
                        index == 0 ? draft.replyToMsgId : nil,
                        index == 0 ? mentionsJSON : "[]", mediaJSON,
                        clientGroupId, index, items.count,
                    ]
                )
                try Self.upsertMessageMedia(
                    db,
                    localId: localId,
                    dialogId: dialogId,
                    msgId: nil,
                    media: item.media
                )
            }
            try db.execute(
                sql: """
                INSERT INTO pending_media_group_sends (
                  client_group_id, account_id, dialog_id, payload_json,
                  draft_consume_operation_id, created_at
                ) VALUES (?, ?, ?, ?, ?, datetime('now'))
                """,
                arguments: [clientGroupId, accountId, dialogId, payloadJSON, operationId]
            )
            try preserveDraftDependency(
                db,
                accountId: accountId,
                dialogId: dialogId,
                operationId: operationId
            )
            try db.execute(
                sql: """
                DELETE FROM pending_draft_mutations
                WHERE account_id = ? AND dialog_id = ? AND operation_id = ?
                """,
                arguments: [accountId, dialogId, operationId]
            )
            try markDraftConsumed(
                db,
                accountId: accountId,
                dialogId: dialogId,
                operationId: operationId
            )
            try db.execute(
                sql: "DELETE FROM draft_attachments WHERE account_id = ? AND dialog_id = ?",
                arguments: [accountId, dialogId]
            )
            try refreshDialogSummary(db, dialogId: dialogId)
            try refreshAllUnreadSummaries(db, dialogId: dialogId)
            return PendingMediaGroupSend(
                clientGroupId: clientGroupId,
                accountId: accountId,
                dialogId: dialogId,
                payload: payload,
                draftConsumeOperationId: operationId,
                retryCount: 0,
                nextRetryAt: nil,
                lastError: nil,
                terminal: false
            )
        }
    }

    func pendingMediaGroupSendsReady(
        now: Date = Date(),
        limit: Int = 10
    ) throws -> [PendingMediaGroupSend] {
        try dbQueue.read { db in
            try Row.fetchAll(
                db,
                sql: """
                SELECT * FROM pending_media_group_sends
                WHERE terminal = 0 AND (next_retry_at IS NULL OR next_retry_at <= ?)
                  AND NOT EXISTS (
                    SELECT 1 FROM pending_media_group_cleanup cleanup
                    WHERE cleanup.client_group_id = pending_media_group_sends.client_group_id
                  )
                ORDER BY created_at, client_group_id
                LIMIT ?
                """,
                arguments: [Self.sqliteTimestamp(now), max(1, min(limit, 25))]
            ).compactMap(Self.pendingMediaGroupSend(from:))
        }
    }

    func markMediaGroupSendFailed(
        clientGroupId: String,
        error: String,
        retryAfter: TimeInterval?,
        terminal: Bool
    ) throws {
        let next = retryAfter.map { Self.sqliteTimestamp(Date().addingTimeInterval($0)) }
        try dbQueue.write { db in
            let dialogId = try String.fetchOne(
                db,
                sql: "SELECT dialog_id FROM pending_media_group_sends WHERE client_group_id = ?",
                arguments: [clientGroupId]
            )
            try db.execute(
                sql: """
                UPDATE pending_media_group_sends SET
                  retry_count = retry_count + 1,
                  next_retry_at = ?,
                  last_error = ?,
                  terminal = ?
                WHERE client_group_id = ?
                """,
                arguments: [next, error, terminal, clientGroupId]
            )
            try db.execute(
                sql: """
                UPDATE messages SET local_state = 'failed'
                WHERE media_group_id = ? AND msg_id IS NULL
                """,
                arguments: [clientGroupId]
            )
            if let dialogId { try refreshDialogSummary(db, dialogId: dialogId) }
        }
    }

    func retryMediaGroupSend(clientGroupId: String) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                UPDATE pending_media_group_sends SET
                  next_retry_at = NULL, last_error = NULL, terminal = 0
                WHERE client_group_id = ?
                """,
                arguments: [clientGroupId]
            )
            try db.execute(
                sql: """
                UPDATE messages SET local_state = 'sending'
                WHERE media_group_id = ? AND msg_id IS NULL
                """,
                arguments: [clientGroupId]
            )
        }
    }

    func removeMediaGroupSend(clientGroupId: String) throws -> [MediaTransferRecord] {
        try dbQueue.write { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT * FROM pending_media_group_sends WHERE client_group_id = ?",
                arguments: [clientGroupId]
            ), let group = Self.pendingMediaGroupSend(from: row) else { return [] }
            let transfers = try group.payload.items.compactMap { item in
                try Row.fetchOne(
                    db,
                    sql: "SELECT * FROM media_transfers WHERE transfer_id = ?",
                    arguments: [item.transferId]
                ).map(Self.mediaTransfer(from:))
            }
            try db.execute(
                sql: """
                DELETE FROM message_media WHERE local_id IN (
                  SELECT local_id FROM messages
                  WHERE media_group_id = ? AND msg_id IS NULL
                )
                """,
                arguments: [clientGroupId]
            )
            try db.execute(
                sql: "DELETE FROM messages WHERE media_group_id = ? AND msg_id IS NULL",
                arguments: [clientGroupId]
            )
            try db.execute(
                sql: "DELETE FROM pending_media_group_sends WHERE client_group_id = ?",
                arguments: [clientGroupId]
            )
            try db.execute(
                sql: "DELETE FROM pending_media_group_cleanup WHERE client_group_id = ?",
                arguments: [clientGroupId]
            )
            for item in group.payload.items {
                try db.execute(
                    sql: "DELETE FROM media_transfers WHERE transfer_id = ?",
                    arguments: [item.transferId]
                )
            }
            try refreshDialogSummary(db, dialogId: group.dialogId)
            return transfers
        }
    }

    /// Typed invalid-reply recovery: put every uploaded item back into a fresh draft generation,
    /// remove only the rejected reply context, and discard the failed optimistic album.
    func restoreMediaGroupAsDraftWithoutReply(
        _ group: PendingMediaGroupSend
    ) throws -> LocalDraft {
        try dbQueue.write { db in
            guard let stored = try Row.fetchOne(
                db,
                sql: """
                SELECT client_group_id FROM pending_media_group_sends
                WHERE client_group_id = ? AND account_id = ? AND dialog_id = ?
                """,
                arguments: [group.clientGroupId, group.accountId, group.dialogId]
            ), (stored["client_group_id"] as String?) != nil else {
                throw CloudLocalStoreBootstrapError.invalidStagedMessage
            }
            try db.execute(
                sql: """
                DELETE FROM message_media WHERE local_id IN (
                  SELECT local_id FROM messages
                  WHERE media_group_id = ? AND msg_id IS NULL
                )
                """,
                arguments: [group.clientGroupId]
            )
            try db.execute(
                sql: "DELETE FROM messages WHERE media_group_id = ? AND msg_id IS NULL",
                arguments: [group.clientGroupId]
            )
            try db.execute(
                sql: "DELETE FROM draft_attachments WHERE account_id = ? AND dialog_id = ?",
                arguments: [group.accountId, group.dialogId]
            )
            let encoder = JSONEncoder()
            for (position, item) in group.payload.items.enumerated() {
                let attachmentId = UUID().uuidString.lowercased()
                let mediaJSON = String(data: try encoder.encode(item.media), encoding: .utf8)
                try db.execute(
                    sql: """
                    UPDATE media_transfers SET
                      client_msg_id = ?,
                      caption = '',
                      reply_to_msg_id = NULL,
                      purpose = 'draft',
                      draft_attachment_id = ?,
                      draft_operation_id = NULL,
                      state = 'ready_to_send',
                      terminal = 0,
                      last_error = NULL,
                      next_retry_at = NULL
                    WHERE transfer_id = ?
                    """,
                    arguments: [attachmentId, attachmentId, item.transferId]
                )
                try db.execute(
                    sql: """
                    INSERT INTO draft_attachments (
                      account_id, dialog_id, attachment_id, media_id, position,
                      media_json, transfer_id, state, progress
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, 'ready', 1)
                    """,
                    arguments: [
                        group.accountId, group.dialogId, attachmentId, item.mediaId,
                        position, mediaJSON, item.transferId,
                    ]
                )
            }
            try db.execute(
                sql: "DELETE FROM pending_media_group_sends WHERE client_group_id = ?",
                arguments: [group.clientGroupId]
            )
            try rewriteDraftMutation(
                db,
                accountId: group.accountId,
                dialogId: group.dialogId,
                state: "active",
                text: group.payload.caption,
                replyToMsgId: nil,
                replyPreview: nil,
                mentions: group.payload.mentions
            )
            guard let draft = try Self.fetchDraft(
                db,
                accountId: group.accountId,
                dialogId: group.dialogId
            ) else {
                throw CloudLocalStoreBootstrapError.invalidStagedMessage
            }
            try refreshDialogSummary(db, dialogId: group.dialogId)
            return draft
        }
    }

    /// Typed invalid-reply recovery for a one-item send. The exact consumed draft is restored
    /// with its uploaded media and mentions, while only the now-invalid reply context is removed.
    func restoreSingleMediaAsDraftWithoutReply(
        _ transfer: MediaTransferRecord,
        accountId: String
    ) throws -> LocalDraft {
        try dbQueue.write { db in
            guard let attemptedOperationId = transfer.draftOperationId,
                  let draftRow = try Row.fetchOne(
                      db,
                      sql: """
                      SELECT operation_id, consumed_operation_id
                      FROM drafts
                      WHERE account_id = ? AND dialog_id = ?
                      """,
                      arguments: [accountId, transfer.dialogId]
                  ),
                  (draftRow["operation_id"] as String?) == attemptedOperationId,
                  (draftRow["consumed_operation_id"] as String?) == attemptedOperationId,
                  let storedTransfer = try Row.fetchOne(
                      db,
                      sql: """
                      SELECT media_id FROM media_transfers
                      WHERE transfer_id = ? AND draft_operation_id = ?
                        AND purpose = 'message'
                      """,
                      arguments: [transfer.transferId, attemptedOperationId]
                  ),
                  let mediaId: String = storedTransfer["media_id"] else {
                throw CloudLocalStoreBootstrapError.invalidStagedMessage
            }

            try db.execute(
                sql: """
                DELETE FROM message_media WHERE local_id IN (
                  SELECT local_id FROM messages
                  WHERE client_msg_id = ? AND msg_id IS NULL
                )
                """,
                arguments: [transfer.clientMsgId]
            )
            try db.execute(
                sql: "DELETE FROM messages WHERE client_msg_id = ? AND msg_id IS NULL",
                arguments: [transfer.clientMsgId]
            )
            try db.execute(
                sql: "DELETE FROM draft_attachments WHERE account_id = ? AND dialog_id = ?",
                arguments: [accountId, transfer.dialogId]
            )

            let attachmentId = UUID().uuidString.lowercased()
            try db.execute(
                sql: """
                UPDATE media_transfers SET
                  client_msg_id = ?,
                  caption = '',
                  reply_to_msg_id = NULL,
                  purpose = 'draft',
                  draft_attachment_id = ?,
                  draft_operation_id = NULL,
                  state = 'ready_to_send',
                  terminal = 0,
                  last_error = NULL,
                  next_retry_at = NULL
                WHERE transfer_id = ?
                """,
                arguments: [attachmentId, attachmentId, transfer.transferId]
            )
            let mediaJSON = String(
                data: try JSONEncoder().encode(transfer.media),
                encoding: .utf8
            )
            try db.execute(
                sql: """
                INSERT INTO draft_attachments (
                  account_id, dialog_id, attachment_id, media_id, position,
                  media_json, transfer_id, state, progress
                ) VALUES (?, ?, ?, ?, 0, ?, ?, 'ready', 1)
                """,
                arguments: [
                    accountId, transfer.dialogId, attachmentId, mediaId,
                    mediaJSON, transfer.transferId,
                ]
            )
            try rewriteDraftMutation(
                db,
                accountId: accountId,
                dialogId: transfer.dialogId,
                state: "active",
                text: transfer.caption,
                replyToMsgId: nil,
                replyPreview: nil,
                mentions: transfer.mentions
            )
            guard let draft = try Self.fetchDraft(
                db,
                accountId: accountId,
                dialogId: transfer.dialogId
            ) else {
                throw CloudLocalStoreBootstrapError.invalidStagedMessage
            }
            try refreshDialogSummary(db, dialogId: transfer.dialogId)
            return draft
        }
    }

    func completeMediaGroupSend(
        _ response: MediaGroupSendResponse,
        senderAccountId: String,
        attemptedOperationId: String?
    ) throws {
        try dbQueue.write { db in
            for message in response.messages {
                try upsertMessage(db, message: message, localState: "sent", refreshSummaries: false)
            }
            guard let group = try Row.fetchOne(
                db,
                sql: "SELECT payload_json FROM pending_media_group_sends WHERE client_group_id = ?",
                arguments: [response.clientGroupId]
            ), let payloadJSON: String = group["payload_json"] else { return }
            try db.execute(
                sql: """
                INSERT INTO pending_media_group_cleanup (
                  client_group_id, transfer_ids_json, created_at
                ) VALUES (?, ?, datetime('now'))
                ON CONFLICT(client_group_id) DO NOTHING
                """,
                arguments: [
                    response.clientGroupId,
                    String(
                        data: try JSONEncoder().encode(
                            try JSONDecoder().decode(
                                PendingMediaGroupPayload.self,
                                from: Data(payloadJSON.utf8)
                            ).items.map(\.transferId)
                        ),
                        encoding: .utf8
                    ) ?? "[]",
                ]
            )
            if let attemptedOperationId, let revision = response.clearedDraftRevision {
                try db.execute(
                    sql: """
                    UPDATE drafts SET
                      server_revision = MAX(server_revision, ?),
                      consumed_operation_id = NULL,
                      terminal = 0,
                      last_error = NULL,
                      updated_at = datetime('now')
                    WHERE account_id = ? AND dialog_id = ?
                      AND operation_id = ?
                      AND consumed_operation_id = ?
                    """,
                    arguments: [
                        revision, senderAccountId, response.dialogId,
                        attemptedOperationId, attemptedOperationId,
                    ]
                )
                try materializeServerShadowIfUnblocked(
                    db,
                    accountId: senderAccountId,
                    dialogId: response.dialogId
                )
                try db.execute(
                    sql: "DELETE FROM pending_draft_dependencies WHERE operation_id = ?",
                    arguments: [attemptedOperationId]
                )
            }
            try refreshDialogSummary(db, dialogId: response.dialogId)
            try refreshAllUnreadSummaries(db, dialogId: response.dialogId)
        }
    }

    func pendingMediaGroupCleanups(limit: Int = 25) throws -> [PendingMediaGroupCleanup] {
        try dbQueue.read { db in
            try Row.fetchAll(
                db,
                sql: """
                SELECT client_group_id, transfer_ids_json
                FROM pending_media_group_cleanup
                ORDER BY created_at, client_group_id
                LIMIT ?
                """,
                arguments: [max(1, min(limit, 100))]
            ).compactMap { row in
                guard let json: String = row["transfer_ids_json"],
                      let ids = try? JSONDecoder().decode([String].self, from: Data(json.utf8))
                else { return nil }
                return PendingMediaGroupCleanup(
                    clientGroupId: row["client_group_id"],
                    transferIds: ids
                )
            }
        }
    }

    func mediaTransfers(ids: [String]) throws -> [MediaTransferRecord] {
        guard !ids.isEmpty else { return [] }
        return try dbQueue.read { db in
            try ids.compactMap { id in
                try Row.fetchOne(
                    db,
                    sql: "SELECT * FROM media_transfers WHERE transfer_id = ?",
                    arguments: [id]
                ).map(Self.mediaTransfer(from:))
            }
        }
    }

    func finalizeMediaGroupCleanup(_ cleanup: PendingMediaGroupCleanup) throws {
        try dbQueue.write { db in
            for transferId in cleanup.transferIds {
                try db.execute(
                    sql: "DELETE FROM media_transfers WHERE transfer_id = ?",
                    arguments: [transferId]
                )
            }
            try db.execute(
                sql: "DELETE FROM pending_media_group_sends WHERE client_group_id = ?",
                arguments: [cleanup.clientGroupId]
            )
            try db.execute(
                sql: "DELETE FROM pending_media_group_cleanup WHERE client_group_id = ?",
                arguments: [cleanup.clientGroupId]
            )
        }
    }

    func nextMediaGroupSendDelay(now: Date = Date()) throws -> TimeInterval? {
        let nowText = Self.sqliteTimestamp(now)
        return try dbQueue.read { db in
            let due = try Int.fetchOne(
                db,
                sql: """
                SELECT COUNT(*) FROM pending_media_group_sends
                WHERE terminal = 0 AND (next_retry_at IS NULL OR next_retry_at <= ?)
                """,
                arguments: [nowText]
            ) ?? 0
            if due > 0 { return 0 }
            guard let next = try String.fetchOne(
                db,
                sql: """
                SELECT MIN(next_retry_at) FROM pending_media_group_sends
                WHERE terminal = 0 AND next_retry_at > ?
                """,
                arguments: [nowText]
            ), let date = Self.makeSQLiteDateFormatter().date(from: next) else { return nil }
            return max(0, date.timeIntervalSince(now))
        }
    }
}
