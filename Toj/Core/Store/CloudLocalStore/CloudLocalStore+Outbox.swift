import Foundation
import GRDB
import os
import Security

extension CloudLocalStore {
    func insertSending(
        dialogId: String,
        clientMsgId: String,
        text: String,
        senderAccountId: String,
        replyToMsgId: Int64? = nil,
        mentions: [CloudMention] = [],
        draftConsumeOperationId: String? = nil,
        requiresCloudDraftSync: Bool = true,
        forwardedFromAccountId: String? = nil,
        forwardedFromDialogId: String? = nil,
        forwardedFromMsgId: Int64? = nil,
        kind: String = "text",
        media: CloudMedia? = nil,
        silent: Bool = false,
        deliverAfter: Date? = nil
    ) throws -> LocalMessage {
        let localId = "pending:\(clientMsgId)"
        let mentionsJSON = try String(
            data: JSONEncoder().encode(mentions),
            encoding: .utf8
        ) ?? "[]"
        let mediaJSON = media
            .flatMap { try? JSONEncoder().encode($0) }
            .flatMap { String(data: $0, encoding: .utf8) }
        try dbQueue.write { db in
            guard try !Self.isDialogRevoked(db, dialogId: dialogId) else {
                throw CloudLocalStoreAccessError.revoked
            }
            try upsertDialog(db, dialogId: dialogId, type: "direct", title: nil, lastMsgId: 0, updatedAt: nil)
            try db.execute(
                sql: """
                INSERT INTO messages (
                  local_id, dialog_id, msg_id, client_msg_id, sender_account_id, kind, text,
                  reply_to_msg_id, forwarded_from_account_id, forwarded_from_dialog_id,
                  forwarded_from_msg_id, is_forwarded, mentions_json,
                  media_json, edit_version, state, server_ts, local_state
                )
                VALUES (?, ?, NULL, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0, 'visible', NULL, 'sending')
                ON CONFLICT(client_msg_id) DO UPDATE SET
                  kind = excluded.kind,
                  text = excluded.text,
                  reply_to_msg_id = excluded.reply_to_msg_id,
                  forwarded_from_account_id = excluded.forwarded_from_account_id,
                  forwarded_from_dialog_id = excluded.forwarded_from_dialog_id,
                  forwarded_from_msg_id = excluded.forwarded_from_msg_id,
                  is_forwarded = excluded.is_forwarded,
                  mentions_json = excluded.mentions_json,
                  media_json = excluded.media_json,
                  local_state = 'sending'
                """,
                arguments: [
                    localId, dialogId, clientMsgId, senderAccountId, kind, text, replyToMsgId,
                    forwardedFromAccountId, forwardedFromDialogId, forwardedFromMsgId,
                    forwardedFromMsgId != nil, mentionsJSON, mediaJSON
                ]
            )
            if let media {
                try Self.upsertMessageMedia(
                    db,
                    localId: localId,
                    dialogId: dialogId,
                    msgId: nil,
                    media: media
                )
            }
            try db.execute(
                sql: """
                INSERT INTO pending_outbox (
                  client_msg_id, dialog_id, body, reply_to_msg_id,
                  forwarded_from_dialog_id, forwarded_from_msg_id, mentions_json,
                  draft_consume_operation_id, silent, next_retry_at, created_at
                )
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, datetime('now'))
                ON CONFLICT(client_msg_id) DO UPDATE SET
                  body = excluded.body,
                  reply_to_msg_id = excluded.reply_to_msg_id,
                  forwarded_from_dialog_id = excluded.forwarded_from_dialog_id,
                  forwarded_from_msg_id = excluded.forwarded_from_msg_id,
                  mentions_json = excluded.mentions_json,
                  draft_consume_operation_id = excluded.draft_consume_operation_id,
                  silent = excluded.silent,
                  next_retry_at = excluded.next_retry_at
                """,
                arguments: [
                    clientMsgId, dialogId, text, replyToMsgId,
                    forwardedFromDialogId, forwardedFromMsgId, mentionsJSON,
                    draftConsumeOperationId, silent,
                    deliverAfter.map(Self.sqliteTimestamp)
                ]
            )
            if let draftConsumeOperationId {
                try db.execute(
                    sql: """
                    UPDATE drafts SET
                      state = 'cleared',
                      text = '',
                      reply_to_msg_id = NULL,
                      reply_preview_json = NULL,
                      mentions_json = '[]',
                      consumed_operation_id = ?,
                      updated_at = datetime('now')
                    WHERE account_id = ? AND dialog_id = ? AND operation_id = ?
                    """,
                    arguments: [
                        draftConsumeOperationId, senderAccountId, dialogId,
                        draftConsumeOperationId,
                    ]
                )
                if !requiresCloudDraftSync {
                    try db.execute(
                        sql: """
                        DELETE FROM pending_draft_mutations
                        WHERE account_id = ? AND dialog_id = ? AND operation_id = ?
                        """,
                        arguments: [
                            senderAccountId, dialogId, draftConsumeOperationId,
                        ]
                    )
                }
            }
            try refreshDialogSummary(db, dialogId: dialogId)
            try refreshAllUnreadSummaries(db, dialogId: dialogId)
        }
        return LocalMessage(
            localId: localId,
            dialogId: dialogId,
            msgId: nil,
            clientMsgId: clientMsgId,
            senderAccountId: senderAccountId,
            senderDisplayName: nil,
            kind: kind,
            text: text,
            replyToMsgId: replyToMsgId,
            forwardedFromAccountId: forwardedFromAccountId,
            forwardedFromDialogId: forwardedFromDialogId,
            forwardedFromMsgId: forwardedFromMsgId,
            isForwarded: forwardedFromMsgId != nil,
            reactions: [],
            mentions: mentions,
            media: media,
            serviceType: nil,
            serviceData: nil,
            editVersion: 0,
            state: "visible",
            serverTs: nil,
            localState: "sending"
        )
    }

    func markRetrying(clientMsgId: String) throws {
        try dbQueue.write { db in
            let dialogId = try String.fetchOne(
                db, sql: "SELECT dialog_id FROM messages WHERE client_msg_id = ?", arguments: [clientMsgId]
            )
            try db.execute(
                sql: """
                UPDATE messages
                SET local_state = 'sending'
                WHERE client_msg_id = ?
                """,
                arguments: [clientMsgId]
            )
            try db.execute(
                sql: """
                UPDATE pending_outbox
                SET next_retry_at = NULL, terminal = 0
                WHERE client_msg_id = ?
                """,
                arguments: [clientMsgId]
            )
            if let dialogId { try refreshDialogSummary(db, dialogId: dialogId) }
        }
    }

    func markFailed(
        clientMsgId: String,
        retryAfter: TimeInterval? = nil,
        terminal: Bool = false
    ) throws {
        let nextRetryAt = retryAfter.map { Self.sqliteTimestamp(Date().addingTimeInterval($0)) }
        try dbQueue.write { db in
            let dialogId = try String.fetchOne(
                db, sql: "SELECT dialog_id FROM messages WHERE client_msg_id = ?", arguments: [clientMsgId]
            )
            // A late HTTP failure can arrive after sync already acknowledged the send (the reply
            // was lost but the POST committed). A row with a server msg_id is delivered; keep it.
            try db.execute(
                sql: "UPDATE messages SET local_state = 'failed' WHERE client_msg_id = ? AND msg_id IS NULL",
                arguments: [clientMsgId]
            )
            try db.execute(
                sql: """
                UPDATE pending_outbox
                SET retry_count = retry_count + 1, next_retry_at = ?, terminal = ?
                WHERE client_msg_id = ?
                """,
                arguments: [nextRetryAt, terminal, clientMsgId]
            )
            if let dialogId { try refreshDialogSummary(db, dialogId: dialogId) }
        }
    }

    /// Atomically removes a terminal optimistic send and its target attachment reference. Cached
    /// bytes are keyed by media_id and intentionally remain because the source message may share
    /// them.
    func removePendingOutboxMessage(clientMsgId: String) throws {
        try dbQueue.write { db in
            guard let row = try Row.fetchOne(
                db,
                sql: """
                SELECT local_id, dialog_id
                FROM messages
                WHERE client_msg_id = ? AND msg_id IS NULL
                """,
                arguments: [clientMsgId]
            ) else {
                try db.execute(
                    sql: "DELETE FROM pending_outbox WHERE client_msg_id = ?",
                    arguments: [clientMsgId]
                )
                return
            }
            let localId: String = row["local_id"]
            let dialogId: String = row["dialog_id"]
            try db.execute(
                sql: "DELETE FROM pending_outbox WHERE client_msg_id = ?",
                arguments: [clientMsgId]
            )
            try db.execute(
                sql: "DELETE FROM message_media WHERE local_id = ?",
                arguments: [localId]
            )
            try db.execute(
                sql: "DELETE FROM messages WHERE client_msg_id = ? AND msg_id IS NULL",
                arguments: [clientMsgId]
            )
            try refreshDialogSummary(db, dialogId: dialogId)
            try refreshAllUnreadSummaries(db, dialogId: dialogId)
        }
    }

    func removeUnsentMessage(clientMsgId: String) throws {
        try removePendingOutboxMessage(clientMsgId: clientMsgId)
    }

    /// Removes only an invalid reply edge after a typed server rejection. The original composer
    /// content becomes a new draft only while the exact consumed operation is still current. If
    /// another device/local edit already replaced it, the failed bubble is retained for explicit
    /// retry instead of overwriting the newer draft.
    func recoverTextSendAfterInvalidReply(
        clientMsgId: String,
        accountId: String
    ) throws -> InvalidReplyTextRecovery {
        try dbQueue.write { db in
            guard let row = try Row.fetchOne(
                db,
                sql: """
                SELECT pending.dialog_id, pending.body, pending.mentions_json,
                       pending.draft_consume_operation_id,
                       draft.state AS draft_state,
                       draft.operation_id AS current_operation_id,
                       draft.consumed_operation_id
                FROM pending_outbox pending
                LEFT JOIN drafts draft
                  ON draft.account_id = ?
                 AND draft.dialog_id = pending.dialog_id
                WHERE pending.client_msg_id = ?
                """,
                arguments: [accountId, clientMsgId]
            ) else {
                throw CloudLocalStoreBootstrapError.invalidStagedMessage
            }
            let dialogId: String = row["dialog_id"]
            let body: String = row["body"]
            let attemptedOperationId: String? = row["draft_consume_operation_id"]
            let currentOperationId: String? = row["current_operation_id"]
            let consumedOperationId: String? = row["consumed_operation_id"]
            let pendingDraftOperation = try String.fetchOne(
                db,
                sql: """
                SELECT operation_id FROM pending_draft_mutations
                WHERE account_id = ? AND dialog_id = ?
                """,
                arguments: [accountId, dialogId]
            )
            let exactConsumedDraft = attemptedOperationId != nil
                && currentOperationId == attemptedOperationId
                && consumedOperationId == attemptedOperationId
            let safeMissingShield = attemptedOperationId == nil
                && (row["draft_state"] as String?) != "active"
                && pendingDraftOperation == nil

            if exactConsumedDraft || safeMissingShield {
                let mentions = (row["mentions_json"] as String?)
                    .flatMap { $0.data(using: .utf8) }
                    .flatMap { try? JSONDecoder().decode([CloudMention].self, from: $0) } ?? []
                try db.execute(
                    sql: "DELETE FROM pending_outbox WHERE client_msg_id = ?",
                    arguments: [clientMsgId]
                )
                try db.execute(
                    sql: "DELETE FROM messages WHERE client_msg_id = ? AND msg_id IS NULL",
                    arguments: [clientMsgId]
                )
                let active = !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                try rewriteDraftMutation(
                    db,
                    accountId: accountId,
                    dialogId: dialogId,
                    state: active ? "active" : "cleared",
                    text: active ? body : "",
                    replyToMsgId: nil,
                    replyPreview: nil,
                    mentions: active ? mentions : []
                )
                try refreshDialogSummary(db, dialogId: dialogId)
                try refreshAllUnreadSummaries(db, dialogId: dialogId)
                return .restoredDraft(dialogId: dialogId)
            }

            try db.execute(
                sql: """
                UPDATE pending_outbox
                SET reply_to_msg_id = NULL, terminal = 1, next_retry_at = NULL
                WHERE client_msg_id = ?
                """,
                arguments: [clientMsgId]
            )
            try db.execute(
                sql: """
                UPDATE messages SET reply_to_msg_id = NULL, local_state = 'failed'
                WHERE client_msg_id = ? AND msg_id IS NULL
                """,
                arguments: [clientMsgId]
            )
            try refreshDialogSummary(db, dialogId: dialogId)
            return .keptFailedMessage(dialogId: dialogId)
        }
    }

    func markSent(_ response: SendMessageResponse, senderAccountId: String) throws {
        try dbQueue.write { db in
            guard try !Self.isDialogRevoked(db, dialogId: response.dialogId) else {
                try db.execute(
                    sql: "DELETE FROM pending_outbox WHERE client_msg_id = ?",
                    arguments: [response.clientMsgId]
                )
                return
            }
            let outboxDraftOperationId = try String.fetchOne(
                db,
                sql: """
                SELECT draft_consume_operation_id FROM pending_outbox
                WHERE client_msg_id = ?
                """,
                arguments: [response.clientMsgId]
            )
            let mediaDraftOperationId = try String.fetchOne(
                db,
                sql: """
                SELECT draft_operation_id FROM media_transfers
                WHERE client_msg_id = ?
                """,
                arguments: [response.clientMsgId]
            )
            let draftConsumeOperationId = outboxDraftOperationId ?? mediaDraftOperationId
            let previousLocalId = try String.fetchOne(
                db,
                sql: "SELECT local_id FROM messages WHERE client_msg_id = ?",
                arguments: [response.clientMsgId]
            )
            try db.execute(
                sql: """
                UPDATE messages
                SET local_id = ?, dialog_id = ?, msg_id = ?, sender_account_id = ?, text = COALESCE(?, text),
                    server_ts = ?, local_state = 'sent'
                WHERE client_msg_id = ?
                """,
                arguments: [
                    "\(response.dialogId):\(response.msgId)",
                    response.dialogId,
                    response.msgId,
                    senderAccountId,
                    response.text,
                    response.serverTs,
                    response.clientMsgId
                ]
            )
            if let previousLocalId {
                try db.execute(
                    sql: """
                    UPDATE message_media
                    SET local_id = ?, dialog_id = ?, msg_id = ?
                    WHERE local_id = ?
                    """,
                    arguments: [
                        "\(response.dialogId):\(response.msgId)", response.dialogId,
                        response.msgId, previousLocalId
                    ]
                )
            }
            try db.execute(sql: "DELETE FROM pending_outbox WHERE client_msg_id = ?", arguments: [response.clientMsgId])
            if let draftConsumeOperationId, let revision = response.clearedDraftRevision {
                try db.execute(
                    sql: """
                    UPDATE drafts SET
                      state = 'cleared',
                      text = '',
                      reply_to_msg_id = NULL,
                      reply_preview_json = NULL,
                      mentions_json = '[]',
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
                        draftConsumeOperationId, draftConsumeOperationId,
                    ]
                )
                try materializeServerShadowIfUnblocked(
                    db,
                    accountId: senderAccountId,
                    dialogId: response.dialogId
                )
                try db.execute(
                    sql: "DELETE FROM pending_draft_dependencies WHERE operation_id = ?",
                    arguments: [draftConsumeOperationId]
                )
            }
            try refreshDialogSummary(db, dialogId: response.dialogId)
            try refreshAllUnreadSummaries(db, dialogId: response.dialogId)
        }
    }

    func oldestServerMsgId(dialogId: String) throws -> Int64? {
        try dbQueue.read { db in
            try Int64.fetchOne(
                db,
                sql: """
                SELECT MIN(msg_id)
                FROM messages
                WHERE dialog_id = ? AND msg_id IS NOT NULL
                """,
                arguments: [dialogId]
            )
        }
    }

    func pendingOutboxReady(
        now: Date = Date(),
        limit: Int = 20,
        includeCloudDraftDependencies: Bool = true
    ) throws -> [PendingOutboxItem] {
        let nowText = Self.sqliteTimestamp(now)
        return try dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT pending_outbox.client_msg_id, pending_outbox.dialog_id, pending_outbox.body,
                       pending_outbox.reply_to_msg_id, pending_outbox.forwarded_from_dialog_id,
                       pending_outbox.forwarded_from_msg_id, pending_outbox.mentions_json,
                       pending_outbox.draft_consume_operation_id,
                       pending_outbox.silent,
                       pending_outbox.retry_count,
                       pending_outbox.next_retry_at
                FROM pending_outbox
                LEFT JOIN dialogs ON dialogs.dialog_id = pending_outbox.dialog_id
                WHERE pending_outbox.terminal = 0
                  AND COALESCE(dialogs.access_state, 'active') <> 'pending'
                  AND (? OR pending_outbox.draft_consume_operation_id IS NULL)
                  AND (pending_outbox.next_retry_at IS NULL OR pending_outbox.next_retry_at <= ?)
                ORDER BY pending_outbox.created_at ASC, pending_outbox.client_msg_id ASC
                LIMIT ?
                """,
                arguments: [includeCloudDraftDependencies, nowText, limit]
            )
            return rows.map(Self.pendingOutboxItem(from:))
        }
    }

    func pendingDestructiveLogoutItemCount() throws -> Int {
        try dbQueue.read { db in
            let pendingText = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM pending_outbox"
            ) ?? 0
            let pendingMutations = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM pending_message_mutations"
            ) ?? 0
            let pendingMedia = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM media_transfers"
            ) ?? 0
            let pendingGroups = try Int.fetchOne(
                db,
                sql: """
                SELECT
                  (SELECT COUNT(*) FROM pending_group_creations)
                  + (SELECT COUNT(*) FROM pending_group_mutations)
                """
            ) ?? 0
            let pendingDrafts = try Int.fetchOne(
                db,
                sql: """
                SELECT
                  (SELECT COUNT(*) FROM pending_draft_mutations)
                  + (SELECT COUNT(*) FROM pending_media_group_sends)
                """
            ) ?? 0
            let pendingDialogPreferences = try Int.fetchOne(
                db,
                sql: """
                SELECT COUNT(*)
                FROM pending_dialog_preference_mutations
                WHERE terminal = 0 AND acknowledged_pts IS NULL
                """
            ) ?? 0
            let pendingProductivity = try Int.fetchOne(
                db,
                sql: """
                SELECT
                  (SELECT COUNT(*) FROM pending_chat_folder_mutations WHERE terminal = 0)
                  + (SELECT COUNT(*) FROM pending_scheduled_delivery_creates WHERE terminal = 0)
                  + (SELECT COUNT(*) FROM pending_scheduled_delivery_mutations WHERE terminal = 0)
                """
            ) ?? 0
            let pendingProfilePhotos = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM pending_profile_photo_mutations"
            ) ?? 0
            return pendingText + pendingMutations + pendingMedia + pendingGroups
                + pendingDrafts + pendingDialogPreferences + pendingProductivity
                + pendingProfilePhotos
        }
    }

    func nextPendingOutboxDelay(
        now: Date = Date(),
        includeCloudDraftDependencies: Bool = true
    ) throws -> TimeInterval? {
        let nowText = Self.sqliteTimestamp(now)
        return try dbQueue.read { db in
            let dueCount = try Int.fetchOne(
                db,
                sql: """
                SELECT COUNT(*)
                FROM pending_outbox
                LEFT JOIN dialogs ON dialogs.dialog_id = pending_outbox.dialog_id
                WHERE pending_outbox.terminal = 0
                  AND COALESCE(dialogs.access_state, 'active') <> 'pending'
                  AND (? OR pending_outbox.draft_consume_operation_id IS NULL)
                  AND (pending_outbox.next_retry_at IS NULL OR pending_outbox.next_retry_at <= ?)
                """,
                arguments: [includeCloudDraftDependencies, nowText]
            ) ?? 0
            if dueCount > 0 {
                return 0
            }

            guard let next = try String.fetchOne(
                db,
                sql: """
                SELECT MIN(pending_outbox.next_retry_at)
                FROM pending_outbox
                LEFT JOIN dialogs ON dialogs.dialog_id = pending_outbox.dialog_id
                WHERE pending_outbox.terminal = 0
                  AND COALESCE(dialogs.access_state, 'active') <> 'pending'
                  AND (? OR pending_outbox.draft_consume_operation_id IS NULL)
                  AND pending_outbox.next_retry_at > ?
                """,
                arguments: [includeCloudDraftDependencies, nowText]
            ), let nextDate = Self.makeSQLiteDateFormatter().date(from: next) else {
                return nil
            }
            return max(0, nextDate.timeIntervalSince(now))
        }
    }
}
