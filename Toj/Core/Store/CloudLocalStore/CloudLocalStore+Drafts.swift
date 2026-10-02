import Foundation
import GRDB
import os
import Security

extension CloudLocalStore {
    func loadDraft(accountId: String, dialogId: String) throws -> LocalDraft? {
        try dbQueue.read { db in
            try Self.fetchDraft(db, accountId: accountId, dialogId: dialogId)
        }
    }

    func observeDraft(
        accountId: String,
        dialogId: String
    ) -> AsyncThrowingStream<LocalDraft?, Error> {
        let values = ValueObservation
            .tracking {
                try Self.fetchDraft($0, accountId: accountId, dialogId: dialogId)
            }
            .removeDuplicates()
            .values(
                in: dbQueue,
                scheduling: .async(onQueue: .global(qos: .userInitiated)),
                bufferingPolicy: .bufferingNewest(1)
            )
        return Self.stream(values)
    }

    /// Commits the visible draft and replaces the dialog's queued network mutation in one WAL
    /// transaction. Raw text is never normalized; trim is used only to decide an empty clear.
    func saveLocalDraft(
        accountId: String,
        dialogId: String,
        text: String,
        replyToMsgId: Int64?,
        replyPreview: CloudDraftReplyPreview?,
        mentions: [CloudMention]
    ) throws -> LocalDraft {
        try dbQueue.write { db in
            let attachmentCount = try Int.fetchOne(
                db,
                sql: """
                SELECT COUNT(*) FROM draft_attachments
                WHERE account_id = ? AND dialog_id = ?
                """,
                arguments: [accountId, dialogId]
            ) ?? 0
            let active = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || replyToMsgId != nil
                || attachmentCount > 0
            let state = active ? "active" : "cleared"
            let storedText = active ? text : ""
            let storedReply = active ? replyToMsgId : nil
            let storedMentions = active ? mentions : []
            if !active {
                try db.execute(
                    sql: "DELETE FROM draft_attachments WHERE account_id = ? AND dialog_id = ?",
                    arguments: [accountId, dialogId]
                )
            }
            try rewriteDraftMutation(
                db,
                accountId: accountId,
                dialogId: dialogId,
                state: state,
                text: storedText,
                replyToMsgId: storedReply,
                replyPreview: active ? replyPreview : nil,
                mentions: storedMentions
            )
            guard let draft = try Self.fetchDraft(db, accountId: accountId, dialogId: dialogId) else {
                throw CloudLocalStoreBootstrapError.invalidStagedMessage
            }
            return draft
        }
    }

    /// Adds a protected, encrypted staging file and its draft chip atomically with the coalesced
    /// mutation. The picker may release its source bytes as soon as this returns.
    func stageDraftAttachment(
        prepared: PreparedMediaUpload,
        accountId: String,
        dialogId: String,
        attachmentId: String,
        position: Int
    ) throws -> LocalDraft {
        try dbQueue.write { db in
            let count = try Int.fetchOne(
                db,
                sql: """
                SELECT COUNT(*) FROM draft_attachments
                WHERE account_id = ? AND dialog_id = ?
                """,
                arguments: [accountId, dialogId]
            ) ?? 0
            guard count < 10 else {
                throw CloudLocalStoreBootstrapError.invalidStagedMessage
            }
            // The database write queue serializes staging for a dialog. Allocating the next
            // position inside this transaction prevents two concurrent picker callbacks from
            // claiming the same slot; the caller's position is only a stale UI hint.
            let allocatedPosition = count
            try db.execute(
                sql: """
                INSERT INTO media_transfers (
                  transfer_id, dialog_id, client_msg_id, caption, reply_to_msg_id,
                  purpose, draft_attachment_id, kind, content_type, file_name, byte_size,
                  sha256, duration_ms, width, height, encrypted_source_path,
                  encrypted_thumbnail_path, state, created_at
                ) VALUES (
                  ?, ?, ?, '', NULL, 'draft', ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'pending',
                  datetime('now')
                )
                """,
                arguments: [
                    prepared.transferId, dialogId, attachmentId, attachmentId,
                    prepared.kind, prepared.contentType, prepared.fileName, prepared.byteSize,
                    prepared.sha256, prepared.durationMs, prepared.width, prepared.height,
                    prepared.encryptedSourcePath, prepared.encryptedThumbnailPath,
                ]
            )
            try db.execute(
                sql: """
                INSERT INTO draft_attachments (
                  account_id, dialog_id, attachment_id, position, transfer_id, state, progress
                ) VALUES (?, ?, ?, ?, ?, 'staging', 0)
                """,
                arguments: [accountId, dialogId, attachmentId, allocatedPosition, prepared.transferId]
            )
            let current = try Self.fetchDraftRow(db, accountId: accountId, dialogId: dialogId)
            try rewriteDraftMutation(
                db,
                accountId: accountId,
                dialogId: dialogId,
                state: "active",
                text: current?.text ?? "",
                replyToMsgId: current?.replyToMsgId,
                replyPreview: current?.replyPreview,
                mentions: current?.mentions ?? []
            )
            guard let draft = try Self.fetchDraft(db, accountId: accountId, dialogId: dialogId) else {
                throw CloudLocalStoreBootstrapError.invalidStagedMessage
            }
            return draft
        }
    }

    func updateDraftAttachment(
        transferId: String,
        mediaId: String?,
        state: String,
        progress: Double,
        error: String?,
        retryAfter: TimeInterval? = nil
    ) throws {
        let nextRetryAt = retryAfter.map {
            Self.sqliteTimestamp(Date().addingTimeInterval($0))
        }
        try dbQueue.write { db in
            guard let row = try Row.fetchOne(
                db,
                sql: """
                SELECT attachment.account_id, attachment.dialog_id, transfer.kind,
                       transfer.content_type, transfer.file_name, transfer.byte_size,
                       transfer.duration_ms, transfer.width, transfer.height,
                       transfer.encrypted_thumbnail_path, transfer.state AS transfer_state
                FROM draft_attachments attachment
                JOIN media_transfers transfer ON transfer.transfer_id = attachment.transfer_id
                WHERE attachment.transfer_id = ?
                """,
                arguments: [transferId]
            ) else { return }
            let accountId: String = row["account_id"]
            let dialogId: String = row["dialog_id"]
            let media = mediaId.map {
                CloudMedia(
                    id: $0,
                    kind: row["kind"],
                    contentType: row["content_type"],
                    fileName: row["file_name"],
                    byteSize: row["byte_size"],
                    durationMs: row["duration_ms"],
                    width: row["width"],
                    height: row["height"],
                    hasThumbnail: (row["encrypted_thumbnail_path"] as String?) != nil
                )
            }
            let mediaJSON = media
                .flatMap { try? JSONEncoder().encode($0) }
                .flatMap { String(data: $0, encoding: .utf8) }
            try db.execute(
                sql: """
                UPDATE draft_attachments SET
                  media_id = COALESCE(?, media_id),
                  media_json = COALESCE(?, media_json),
                  state = ?,
                  progress = ?,
                  last_error = ?
                WHERE transfer_id = ?
                """,
                arguments: [
                    mediaId, mediaJSON, state, max(0, min(1, progress)), error, transferId,
                ]
            )
            let currentTransferState: String = row["transfer_state"]
            let transferState: String
            switch state {
            case "ready":
                transferState = "ready_to_send"
            case "uploading":
                transferState = "uploading"
            default:
                // `failed` and `terminal` describe the draft chip, not the transport. Preserve
                // its valid pending/uploading/ready_to_send state instead of violating the table
                // domain or making retry scans depend on UI state names.
                transferState = currentTransferState
            }
            let terminal = state == "terminal"
            let transientFailure = state == "failed"
            try db.execute(
                sql: """
                UPDATE media_transfers SET
                  media_id = COALESCE(?, media_id),
                  upload_offset = CASE WHEN ? = 'ready' THEN byte_size ELSE upload_offset END,
                  state = ?,
                  last_error = ?,
                  terminal = CASE
                    WHEN ? THEN 1
                    WHEN ? THEN 0
                    ELSE terminal
                  END,
                  next_retry_at = CASE
                    WHEN ? THEN NULL
                    WHEN ? THEN ?
                    ELSE next_retry_at
                  END,
                  retry_count = retry_count + CASE WHEN ? THEN 1 ELSE 0 END
                WHERE transfer_id = ?
                """,
                arguments: [
                    mediaId, state, transferState, error,
                    terminal, transientFailure,
                    terminal, transientFailure, nextRetryAt,
                    transientFailure,
                    transferId,
                ]
            )
            let current = try Self.fetchDraftRow(db, accountId: accountId, dialogId: dialogId)
            try rewriteDraftMutation(
                db,
                accountId: accountId,
                dialogId: dialogId,
                state: "active",
                text: current?.text ?? "",
                replyToMsgId: current?.replyToMsgId,
                replyPreview: current?.replyPreview,
                mentions: current?.mentions ?? []
            )
        }
    }

    func retryDraftAttachment(transferId: String) throws -> MediaTransferRecord? {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                UPDATE media_transfers SET
                  terminal = 0,
                  next_retry_at = NULL,
                  last_error = NULL,
                  state = CASE WHEN media_id IS NULL THEN 'pending' ELSE 'uploading' END
                WHERE transfer_id = ? AND purpose = 'draft'
                """,
                arguments: [transferId]
            )
            try db.execute(
                sql: """
                UPDATE draft_attachments SET
                  state = 'staging',
                  last_error = NULL
                WHERE transfer_id = ?
                """,
                arguments: [transferId]
            )
            return try Row.fetchOne(
                db,
                sql: "SELECT * FROM media_transfers WHERE transfer_id = ?",
                arguments: [transferId]
            ).map(Self.mediaTransfer(from:))
        }
    }

    func removeDraftAttachment(
        accountId: String,
        dialogId: String,
        attachmentId: String
    ) throws -> String? {
        try dbQueue.write { db in
            let transferId = try String.fetchOne(
                db,
                sql: """
                SELECT transfer_id FROM draft_attachments
                WHERE account_id = ? AND dialog_id = ? AND attachment_id = ?
                """,
                arguments: [accountId, dialogId, attachmentId]
            )
            try db.execute(
                sql: """
                DELETE FROM draft_attachments
                WHERE account_id = ? AND dialog_id = ? AND attachment_id = ?
                """,
                arguments: [accountId, dialogId, attachmentId]
            )
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT attachment_id FROM draft_attachments
                WHERE account_id = ? AND dialog_id = ?
                ORDER BY position
                """,
                arguments: [accountId, dialogId]
            )
            try rewriteDraftAttachmentOrder(
                db,
                accountId: accountId,
                dialogId: dialogId,
                attachmentIds: rows.map { $0["attachment_id"] as String }
            )
            let current = try Self.fetchDraftRow(db, accountId: accountId, dialogId: dialogId)
            let active = !(current?.text ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || current?.replyToMsgId != nil
                || !rows.isEmpty
            try rewriteDraftMutation(
                db,
                accountId: accountId,
                dialogId: dialogId,
                state: active ? "active" : "cleared",
                text: active ? current?.text ?? "" : "",
                replyToMsgId: active ? current?.replyToMsgId : nil,
                replyPreview: active ? current?.replyPreview : nil,
                mentions: active ? current?.mentions ?? [] : []
            )
            if let transferId {
                try db.execute(sql: "DELETE FROM media_transfers WHERE transfer_id = ?", arguments: [transferId])
            }
            return transferId
        }
    }

    func reorderDraftAttachments(
        accountId: String,
        dialogId: String,
        attachmentIds: [String]
    ) throws {
        try dbQueue.write { db in
            let existing = try String.fetchAll(
                db,
                sql: """
                SELECT attachment_id FROM draft_attachments
                WHERE account_id = ? AND dialog_id = ?
                ORDER BY position
                """,
                arguments: [accountId, dialogId]
            )
            guard Set(existing) == Set(attachmentIds), existing.count == attachmentIds.count else {
                throw CloudLocalStoreBootstrapError.invalidStagedMessage
            }
            try rewriteDraftAttachmentOrder(
                db,
                accountId: accountId,
                dialogId: dialogId,
                attachmentIds: attachmentIds
            )
            let current = try Self.fetchDraftRow(db, accountId: accountId, dialogId: dialogId)
            try rewriteDraftMutation(
                db,
                accountId: accountId,
                dialogId: dialogId,
                state: "active",
                text: current?.text ?? "",
                replyToMsgId: current?.replyToMsgId,
                replyPreview: current?.replyPreview,
                mentions: current?.mentions ?? []
            )
        }
    }

    func pendingDraftMutationsReady(
        now: Date = Date(),
        limit: Int = 20
    ) throws -> [PendingDraftMutation] {
        let nowText = Self.sqliteTimestamp(now)
        return try dbQueue.read { db in
            try Row.fetchAll(
                db,
                sql: """
                SELECT * FROM pending_draft_mutations
                WHERE terminal = 0 AND (next_retry_at IS NULL OR next_retry_at <= ?)
                  AND NOT EXISTS (
                    SELECT 1 FROM draft_attachments attachment
                    WHERE attachment.account_id = pending_draft_mutations.account_id
                      AND attachment.dialog_id = pending_draft_mutations.dialog_id
                      AND attachment.state != 'ready'
                  )
                ORDER BY updated_at, dialog_id
                LIMIT ?
                """,
                arguments: [nowText, max(1, min(limit, 100))]
            ).compactMap(Self.pendingDraftMutation(from:))
        }
    }

    /// Returns the durable dependency for one dialog even while it is backed off or terminal.
    /// Explicit send/navigation flushes use this to avoid mistaking "not due yet" for "synced."
    func pendingDraftMutation(
        accountId: String,
        dialogId: String
    ) throws -> PendingDraftMutation? {
        try dbQueue.read { db in
            try Row.fetchOne(
                db,
                sql: """
                SELECT * FROM pending_draft_mutations
                WHERE account_id = ? AND dialog_id = ?
                """,
                arguments: [accountId, dialogId]
            ).flatMap(Self.pendingDraftMutation(from:))
        }
    }

    func pendingDraftDialogIds(accountId: String) throws -> [String] {
        try dbQueue.read { db in
            try String.fetchAll(
                db,
                sql: """
                SELECT dialog_id FROM pending_draft_mutations
                WHERE account_id = ? AND terminal = 0
                ORDER BY updated_at, dialog_id
                LIMIT 100
                """,
                arguments: [accountId]
            )
        }
    }

    func acknowledgeDraftMutation(
        _ response: DraftMutationResponse,
        accountId: String,
        attemptedOperationId: String
    ) throws {
        try dbQueue.write { db in
            let currentOperation = try String.fetchOne(
                db,
                sql: """
                SELECT operation_id FROM pending_draft_mutations
                WHERE account_id = ? AND dialog_id = ?
                """,
                arguments: [accountId, response.draft.dialogId]
            )
            try applyCloudDraft(
                db,
                draft: response.draft,
                accountId: accountId,
                preserveLocalOverlay: currentOperation != nil
            )
            if currentOperation == attemptedOperationId {
                try db.execute(
                    sql: """
                    DELETE FROM pending_draft_mutations
                    WHERE account_id = ? AND dialog_id = ? AND operation_id = ?
                    """,
                    arguments: [accountId, response.draft.dialogId, attemptedOperationId]
                )
                try materializeServerShadowIfUnblocked(
                    db,
                    accountId: accountId,
                    dialogId: response.draft.dialogId
                )
            }
        }
    }

    @discardableResult
    func queueDialogPreference(
        accountId: String,
        dialogId: String,
        field: DialogPreferenceField,
        desiredValue explicitValue: Bool? = nil
    ) throws -> PendingDialogPreferenceMutation? {
        try dbQueue.write { db in
            guard try Bool.fetchOne(
                db,
                sql: "SELECT EXISTS(SELECT 1 FROM dialogs WHERE dialog_id = ?)",
                arguments: [dialogId]
            ) == true else { return nil }
            try ensureDialogPreferences(db, accountId: accountId, dialogId: dialogId)

            let existing = try Row.fetchOne(
                db,
                sql: """
                SELECT *
                FROM pending_dialog_preference_mutations
                WHERE account_id = ? AND dialog_id = ? AND field = ? AND terminal = 0
                ORDER BY local_order DESC
                LIMIT 1
                """,
                arguments: [accountId, dialogId, field.rawValue]
            )
            let canonicalColumn: String = switch field {
            case .pinned: "is_pinned"
            case .muted: "is_muted"
            case .archived: "is_archived"
            }
            let canonical = try Bool.fetchOne(
                db,
                sql: """
                SELECT \(canonicalColumn)
                FROM dialog_preferences
                WHERE account_id = ? AND dialog_id = ?
                """,
                arguments: [accountId, dialogId]
            ) ?? false
            let current = existing.map { ($0["desired_value"] as Int) != 0 } ?? canonical
            let desiredValue = explicitValue ?? !current
            if explicitValue != nil, desiredValue == current {
                return existing.map(Self.pendingDialogPreference(from:))
            }

            let mutationId = UUID().uuidString.lowercased()
            // Preserve sub-second toggle order and use the same lexical shape as server-authored
            // pinned_at values so rapid offline pins sort deterministically.
            let desiredAt = Self.preferenceTimestamp(Date())
            let localOrder = try Self.nextLocalMutationOrder(db)
            let coalescedMutationId: String?
            if let existing,
               (existing["attempted_at"] as String?) == nil,
               (existing["acknowledged_pts"] as Int64?) == nil {
                let existingId: String = existing["client_mutation_id"]
                try db.execute(
                    sql: """
                    UPDATE pending_dialog_preference_mutations
                    SET desired_value = ?, desired_at = ?, local_order = ?,
                        retry_count = 0, next_retry_at = NULL, last_error = NULL,
                        terminal = 0, dormant = 0
                    WHERE client_mutation_id = ?
                    """,
                    arguments: [desiredValue, desiredAt, localOrder, existingId]
                )
                coalescedMutationId = existingId
            } else {
                try db.execute(
                    sql: """
                    INSERT INTO pending_dialog_preference_mutations (
                      account_id, dialog_id, field, desired_value, desired_at,
                      client_mutation_id, acknowledged_pts, retry_count,
                      next_retry_at, last_error, terminal, local_order,
                      attempted_at, dormant
                    ) VALUES (?, ?, ?, ?, ?, ?, NULL, 0, NULL, NULL, 0, ?, NULL, 0)
                    """,
                    arguments: [
                        accountId, dialogId, field.rawValue, desiredValue,
                        desiredAt, mutationId, localOrder,
                    ]
                )
                coalescedMutationId = mutationId
            }
            return try Row.fetchOne(
                db,
                sql: """
                SELECT *
                FROM pending_dialog_preference_mutations
                WHERE account_id = ? AND client_mutation_id = ?
                """,
                arguments: [accountId, coalescedMutationId]
            ).map(Self.pendingDialogPreference(from:))
        }
    }

    func pendingDialogPreferencesReady(
        accountId: String,
        limit: Int = 50
    ) throws -> [PendingDialogPreferenceMutation] {
        try dbQueue.read { db in
            try Row.fetchAll(
                db,
                sql: """
                SELECT *
                FROM pending_dialog_preference_mutations
                WHERE account_id = ?
                  AND terminal = 0
                  AND dormant = 0
                  AND acknowledged_pts IS NULL
                  AND (next_retry_at IS NULL OR next_retry_at <= datetime('now'))
                ORDER BY local_order
                LIMIT ?
                """,
                arguments: [accountId, max(1, min(limit, 200))]
            ).map(Self.pendingDialogPreference(from:))
        }
    }

    func markDialogPreferenceAttempted(
        accountId: String,
        clientMutationId: String
    ) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                UPDATE pending_dialog_preference_mutations
                SET attempted_at = COALESCE(attempted_at, ?)
                WHERE account_id = ? AND client_mutation_id = ?
                  AND terminal = 0 AND acknowledged_pts IS NULL
                """,
                arguments: [
                    Self.preferenceTimestamp(Date()), accountId, clientMutationId,
                ]
            )
        }
    }

    func reactivateDormantDialogPreferences(accountId: String) throws -> Int {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                UPDATE pending_dialog_preference_mutations
                SET dormant = 0, next_retry_at = NULL, last_error = NULL
                WHERE account_id = ? AND terminal = 0
                  AND acknowledged_pts IS NULL AND dormant = 1
                """,
                arguments: [accountId]
            )
            return db.changesCount
        }
    }

    func acknowledgeDialogPreference(
        clientMutationId: String,
        pts: Int64,
        preferences _: CloudDialogPreferences,
        accountId: String
    ) throws {
        try dbQueue.write { db in
            // A delayed HTTP response may predate a difference event already applied locally.
            // The response therefore records only its acknowledgement cursor; canonical values
            // remain exclusively authored by the ordered event/bootstrap stream.
            let currentPts = try Int64.fetchOne(
                db,
                sql: "SELECT pts FROM sync_state WHERE account_id = ?",
                arguments: [accountId]
            ) ?? 0
            if currentPts >= pts {
                try db.execute(
                    sql: """
                    DELETE FROM pending_dialog_preference_mutations
                    WHERE account_id = ? AND client_mutation_id = ? AND terminal = 0
                    """,
                    arguments: [accountId, clientMutationId]
                )
            } else {
                try db.execute(
                    sql: """
                    UPDATE pending_dialog_preference_mutations
                    SET acknowledged_pts = ?, next_retry_at = NULL, last_error = NULL
                    WHERE account_id = ? AND client_mutation_id = ? AND terminal = 0
                    """,
                    arguments: [pts, accountId, clientMutationId]
                )
            }
        }
    }

    func applyCloudDraft(_ draft: CloudDraft, accountId: String) throws {
        try dbQueue.write { db in
            let pending = try String.fetchOne(
                db,
                sql: """
                SELECT operation_id FROM pending_draft_mutations
                WHERE account_id = ? AND dialog_id = ?
                """,
                arguments: [accountId, draft.dialogId]
            )
            try applyCloudDraft(
                db,
                draft: draft,
                accountId: accountId,
                preserveLocalOverlay: pending != nil
            )
        }
    }

    func markDraftMutationFailed(
        accountId: String,
        dialogId: String,
        operationId: String,
        error: String,
        retryAfter: TimeInterval?,
        terminal: Bool
    ) throws {
        let nextRetryAt = retryAfter.map {
            Self.sqliteTimestamp(Date().addingTimeInterval($0))
        }
        try dbQueue.write { db in
            try db.execute(
                sql: """
                UPDATE pending_draft_mutations SET
                  retry_count = retry_count + 1,
                  next_retry_at = ?,
                  last_error = ?,
                  terminal = ?
                WHERE account_id = ? AND dialog_id = ? AND operation_id = ?
                """,
                arguments: [
                    nextRetryAt, error, terminal, accountId, dialogId, operationId,
                ]
            )
            if terminal {
                let hasShadow = try String.fetchOne(
                    db,
                    sql: """
                    SELECT server_shadow_json FROM drafts
                    WHERE account_id = ? AND dialog_id = ? AND operation_id = ?
                    """,
                    arguments: [accountId, dialogId, operationId]
                ) != nil
                if hasShadow {
                    try db.execute(
                        sql: """
                        DELETE FROM pending_draft_mutations
                        WHERE account_id = ? AND dialog_id = ? AND operation_id = ?
                        """,
                        arguments: [accountId, dialogId, operationId]
                    )
                    try materializeServerShadowIfUnblocked(
                        db,
                        accountId: accountId,
                        dialogId: dialogId
                    )
                } else {
                    try db.execute(
                        sql: """
                        UPDATE drafts SET terminal = 1, last_error = ?
                        WHERE account_id = ? AND dialog_id = ? AND operation_id = ?
                        """,
                        arguments: [error, accountId, dialogId, operationId]
                    )
                }
            }
        }
    }

    func pendingDraftDependency(operationId: String) throws -> PendingDraftMutation? {
        try dbQueue.read { db in
            try Row.fetchOne(
                db,
                sql: "SELECT * FROM pending_draft_dependencies WHERE operation_id = ?",
                arguments: [operationId]
            ).flatMap(Self.pendingDraftMutation(from:))
        }
    }

    func acknowledgeDraftDependency(
        _ response: DraftMutationResponse,
        accountId: String,
        attemptedOperationId: String
    ) throws {
        try dbQueue.write { db in
            guard try String.fetchOne(
                db,
                sql: "SELECT operation_id FROM pending_draft_dependencies WHERE operation_id = ?",
                arguments: [attemptedOperationId]
            ) != nil else { return }
            try applyCloudDraft(
                db,
                draft: response.draft,
                accountId: accountId,
                preserveLocalOverlay: true
            )
            try db.execute(
                sql: "DELETE FROM pending_draft_dependencies WHERE operation_id = ?",
                arguments: [attemptedOperationId]
            )
        }
    }

    func nextDialogPreferenceRetryDelay(
        accountId: String,
        now: Date = Date()
    ) throws -> TimeInterval? {
        let nowText = Self.sqliteTimestamp(now)
        return try dbQueue.read { db in
            let due = try Int.fetchOne(
                db,
                sql: """
                SELECT COUNT(*)
                FROM pending_dialog_preference_mutations
                WHERE account_id = ?
                  AND terminal = 0
                  AND dormant = 0
                  AND acknowledged_pts IS NULL
                  AND (next_retry_at IS NULL OR next_retry_at <= ?)
                """,
                arguments: [accountId, nowText]
            ) ?? 0
            if due > 0 { return 0 }
            guard let next = try String.fetchOne(
                db,
                sql: """
                SELECT MIN(next_retry_at)
                FROM pending_dialog_preference_mutations
                WHERE account_id = ?
                  AND terminal = 0
                  AND dormant = 0
                  AND acknowledged_pts IS NULL
                  AND next_retry_at > ?
                """,
                arguments: [accountId, nowText]
            ), let date = Self.makeSQLiteDateFormatter().date(from: next) else { return nil }
            return max(0, date.timeIntervalSince(now))
        }
    }

    func failDialogPreference(
        accountId: String,
        clientMutationId: String,
        retryAfter: TimeInterval?,
        error: String,
        terminal: Bool,
        dormant: Bool = false
    ) throws {
        let nextRetryAt = retryAfter.map {
            Self.sqliteTimestamp(Date().addingTimeInterval(max(1, $0)))
        }
        try dbQueue.write { db in
            try db.execute(
                sql: """
                UPDATE pending_dialog_preference_mutations
                SET retry_count = retry_count + 1,
                    next_retry_at = ?,
                    last_error = ?,
                    terminal = ?,
                    dormant = ?
                WHERE account_id = ? AND client_mutation_id = ?
                """,
                arguments: [
                    nextRetryAt, error, terminal, dormant,
                    accountId, clientMutationId,
                ]
            )
        }
    }

    func applyDialogPreferences(
        _ preferences: CloudDialogPreferences,
        accountId: String,
        clientMutationId: String? = nil
    ) throws {
        try dbQueue.write { db in
            try upsertDialogPreferences(
                db,
                preferences: preferences,
                accountId: accountId,
                clientMutationId: clientMutationId
            )
        }
    }

    func markDraftDependencyFailed(
        operationId: String,
        error: String,
        retryAfter: TimeInterval?,
        terminal: Bool = false
    ) throws {
        try dbQueue.write { db in
            let dialogIds = try String.fetchAll(
                db,
                sql: """
                SELECT DISTINCT dialog_id FROM (
                  SELECT dialog_id FROM pending_outbox
                  WHERE draft_consume_operation_id = ?
                  UNION ALL
                  SELECT dialog_id FROM pending_media_group_sends
                  WHERE draft_consume_operation_id = ?
                  UNION ALL
                  SELECT dialog_id FROM media_transfers
                  WHERE draft_operation_id = ?
                )
                """,
                arguments: [operationId, operationId, operationId]
            )
            try db.execute(
                sql: """
                UPDATE pending_draft_dependencies SET
                  retry_count = retry_count + 1,
                  next_retry_at = ?,
                  last_error = ?,
                  terminal = ?
                WHERE operation_id = ?
                """,
                arguments: [
                    retryAfter.map { Self.sqliteTimestamp(Date().addingTimeInterval($0)) },
                    error,
                    terminal,
                    operationId,
                ]
            )
            if terminal {
                try db.execute(
                    sql: """
                    UPDATE messages SET local_state = 'failed'
                    WHERE client_msg_id IN (
                      SELECT client_msg_id FROM pending_outbox
                      WHERE draft_consume_operation_id = ?
                      UNION
                      SELECT client_msg_id FROM media_transfers
                      WHERE draft_operation_id = ?
                    )
                    OR media_group_id IN (
                      SELECT client_group_id FROM pending_media_group_sends
                      WHERE draft_consume_operation_id = ?
                    )
                    """,
                    arguments: [operationId, operationId, operationId]
                )
                try db.execute(
                    sql: """
                    UPDATE pending_outbox
                    SET terminal = 1, next_retry_at = NULL
                    WHERE draft_consume_operation_id = ?
                    """,
                    arguments: [operationId]
                )
                try db.execute(
                    sql: """
                    UPDATE pending_media_group_sends
                    SET terminal = 1, next_retry_at = NULL, last_error = ?
                    WHERE draft_consume_operation_id = ?
                    """,
                    arguments: [error, operationId]
                )
                try db.execute(
                    sql: """
                    UPDATE media_transfers
                    SET terminal = 1, next_retry_at = NULL, last_error = ?
                    WHERE draft_operation_id = ?
                    """,
                    arguments: [error, operationId]
                )
                for dialogId in dialogIds {
                    try refreshDialogSummary(db, dialogId: dialogId)
                }
            }
        }
    }

    func nextPendingDraftDelay(now: Date = Date()) throws -> TimeInterval? {
        let nowText = Self.sqliteTimestamp(now)
        return try dbQueue.read { db in
            let due = try Int.fetchOne(
                db,
                sql: """
                SELECT COUNT(*) FROM pending_draft_mutations
                WHERE terminal = 0 AND (next_retry_at IS NULL OR next_retry_at <= ?)
                  AND NOT EXISTS (
                    SELECT 1 FROM draft_attachments attachment
                    WHERE attachment.account_id = pending_draft_mutations.account_id
                      AND attachment.dialog_id = pending_draft_mutations.dialog_id
                      AND attachment.state != 'ready'
                  )
                """,
                arguments: [nowText]
            ) ?? 0
            if due > 0 { return 0 }
            guard let next = try String.fetchOne(
                db,
                sql: """
                SELECT MIN(next_retry_at) FROM pending_draft_mutations
                WHERE terminal = 0 AND next_retry_at > ?
                  AND NOT EXISTS (
                    SELECT 1 FROM draft_attachments attachment
                    WHERE attachment.account_id = pending_draft_mutations.account_id
                      AND attachment.dialog_id = pending_draft_mutations.dialog_id
                      AND attachment.state != 'ready'
                  )
                """,
                arguments: [nowText]
            ), let date = Self.makeSQLiteDateFormatter().date(from: next) else { return nil }
            return max(0, date.timeIntervalSince(now))
        }
    }

    private typealias DraftRowValue = (
        text: String,
        replyToMsgId: Int64?,
        replyPreview: CloudDraftReplyPreview?,
        mentions: [CloudMention]
    )

    func markDraftConsumed(
        _ db: Database,
        accountId: String,
        dialogId: String,
        operationId: String
    ) throws {
        try db.execute(
            sql: """
            UPDATE drafts SET
              state = 'cleared',
              text = '',
              reply_to_msg_id = NULL,
              reply_preview_json = NULL,
              mentions_json = '[]',
              consumed_operation_id = ?,
              terminal = 0,
              last_error = NULL,
              updated_at = datetime('now')
            WHERE account_id = ? AND dialog_id = ? AND operation_id = ?
            """,
            arguments: [operationId, accountId, dialogId, operationId]
        )
    }

    private static func fetchDraftRow(
        _ db: Database,
        accountId: String,
        dialogId: String
    ) throws -> DraftRowValue? {
        guard let row = try Row.fetchOne(
            db,
            sql: """
            SELECT text, reply_to_msg_id, reply_preview_json, mentions_json
            FROM drafts WHERE account_id = ? AND dialog_id = ?
            """,
            arguments: [accountId, dialogId]
        ) else { return nil }
        let decoder = JSONDecoder()
        return (
            text: row["text"],
            replyToMsgId: row["reply_to_msg_id"],
            replyPreview: (row["reply_preview_json"] as String?)
                .flatMap { $0.data(using: .utf8) }
                .flatMap { try? decoder.decode(CloudDraftReplyPreview.self, from: $0) },
            mentions: (row["mentions_json"] as String?)
                .flatMap { $0.data(using: .utf8) }
                .flatMap { try? decoder.decode([CloudMention].self, from: $0) } ?? []
        )
    }

    static func fetchDraft(
        _ db: Database,
        accountId: String,
        dialogId: String
    ) throws -> LocalDraft? {
        guard let row = try Row.fetchOne(
            db,
            sql: """
            SELECT * FROM drafts WHERE account_id = ? AND dialog_id = ?
            """,
            arguments: [accountId, dialogId]
        ) else { return nil }
        let decoder = JSONDecoder()
        let attachmentRows = try Row.fetchAll(
            db,
            sql: """
            SELECT * FROM draft_attachments
            WHERE account_id = ? AND dialog_id = ?
            ORDER BY position, attachment_id
            """,
            arguments: [accountId, dialogId]
        )
        let attachments = attachmentRows.map { attachment in
            LocalDraftAttachment(
                attachmentId: attachment["attachment_id"],
                mediaId: attachment["media_id"],
                position: attachment["position"],
                media: (attachment["media_json"] as String?)
                    .flatMap { $0.data(using: .utf8) }
                    .flatMap { try? decoder.decode(CloudMedia.self, from: $0) },
                transferId: attachment["transfer_id"],
                state: attachment["state"],
                progress: attachment["progress"],
                lastError: attachment["last_error"]
            )
        }
        return LocalDraft(
            accountId: row["account_id"],
            dialogId: row["dialog_id"],
            state: row["state"],
            text: row["text"],
            replyToMsgId: row["reply_to_msg_id"],
            replyPreview: (row["reply_preview_json"] as String?)
                .flatMap { $0.data(using: .utf8) }
                .flatMap { try? decoder.decode(CloudDraftReplyPreview.self, from: $0) },
            mentions: (row["mentions_json"] as String?)
                .flatMap { $0.data(using: .utf8) }
                .flatMap { try? decoder.decode([CloudMention].self, from: $0) } ?? [],
            attachments: attachments,
            localGeneration: row["local_generation"],
            operationId: row["operation_id"],
            serverRevision: row["server_revision"],
            terminal: (row["terminal"] as Int) != 0,
            lastError: row["last_error"],
            updatedAt: row["updated_at"]
        )
    }

    func rewriteDraftMutation(
        _ db: Database,
        accountId: String,
        dialogId: String,
        state: String,
        text: String,
        replyToMsgId: Int64?,
        replyPreview: CloudDraftReplyPreview?,
        mentions: [CloudMention]
    ) throws {
        let previous = try Row.fetchOne(
            db,
            sql: """
            SELECT local_generation, server_revision
            FROM drafts WHERE account_id = ? AND dialog_id = ?
            """,
            arguments: [accountId, dialogId]
        )
        let generation = (previous?["local_generation"] as Int64? ?? 0) + 1
        let operationId = UUID().uuidString.lowercased()
        let encoder = JSONEncoder()
        let mentionsJSON = String(
            data: try encoder.encode(mentions),
            encoding: .utf8
        ) ?? "[]"
        let replyJSON = replyPreview
            .flatMap { try? encoder.encode($0) }
            .flatMap { String(data: $0, encoding: .utf8) }
        try db.execute(
            sql: """
            INSERT INTO drafts (
              account_id, dialog_id, state, text, reply_to_msg_id, reply_preview_json,
              mentions_json, local_generation, operation_id, server_revision,
              terminal, last_error, consumed_operation_id, updated_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0, NULL, NULL, datetime('now'))
            ON CONFLICT(account_id, dialog_id) DO UPDATE SET
              state = excluded.state,
              text = excluded.text,
              reply_to_msg_id = excluded.reply_to_msg_id,
              reply_preview_json = excluded.reply_preview_json,
              mentions_json = excluded.mentions_json,
              local_generation = excluded.local_generation,
              operation_id = excluded.operation_id,
              terminal = 0,
              last_error = NULL,
              consumed_operation_id = NULL,
              updated_at = excluded.updated_at
            """,
            arguments: [
                accountId, dialogId, state, text, replyToMsgId, replyJSON,
                mentionsJSON, generation, operationId,
                previous?["server_revision"] as Int64? ?? 0,
            ]
        )
        let readyRows = try Row.fetchAll(
            db,
            sql: """
            SELECT attachment_id, media_id, position
            FROM draft_attachments
            WHERE account_id = ? AND dialog_id = ?
              AND state = 'ready' AND media_id IS NOT NULL
            ORDER BY position
            """,
            arguments: [accountId, dialogId]
        )
        let attachments = readyRows.map {
            DraftAttachmentRequest(
                attachmentId: $0["attachment_id"],
                mediaId: $0["media_id"],
                position: $0["position"]
            )
        }
        let payload = StoredDraftMutationPayload(
            state: state,
            text: text,
            replyToMsgId: replyToMsgId,
            mentions: mentions,
            attachments: attachments
        )
        let payloadJSON = String(
            data: try encoder.encode(payload),
            encoding: .utf8
        ) ?? "{}"
        try db.execute(
            sql: """
            INSERT INTO pending_draft_mutations (
              account_id, dialog_id, operation_id, local_generation, payload_json,
              retry_count, next_retry_at, last_error, terminal, updated_at
            ) VALUES (?, ?, ?, ?, ?, 0, NULL, NULL, 0, datetime('now'))
            ON CONFLICT(account_id, dialog_id) DO UPDATE SET
              operation_id = excluded.operation_id,
              local_generation = excluded.local_generation,
              payload_json = excluded.payload_json,
              retry_count = 0,
              next_retry_at = NULL,
              last_error = NULL,
              terminal = 0,
              updated_at = excluded.updated_at
            """,
            arguments: [accountId, dialogId, operationId, generation, payloadJSON]
        )
    }

    func applyCloudDraft(
        _ db: Database,
        draft: CloudDraft,
        accountId: String,
        preserveLocalOverlay: Bool
    ) throws {
        let current = try Row.fetchOne(
            db,
            sql: """
            SELECT server_revision, consumed_operation_id
            FROM drafts WHERE account_id = ? AND dialog_id = ?
            """,
            arguments: [accountId, draft.dialogId]
        )
        let currentRevision = current?["server_revision"] as Int64? ?? 0
        guard draft.revision >= currentRevision else { return }
        let encoder = JSONEncoder()
        let shadow = String(
            data: try encoder.encode(draft),
            encoding: .utf8
        )
        let consumedOperation: String? = current?["consumed_operation_id"]
        let preserveConsumed = consumedOperation == draft.operationId && draft.state == "active"
        if preserveLocalOverlay || preserveConsumed {
            try db.execute(
                sql: """
                UPDATE drafts SET
                  server_revision = ?,
                  server_shadow_json = ?
                WHERE account_id = ? AND dialog_id = ?
                """,
                arguments: [draft.revision, shadow, accountId, draft.dialogId]
            )
            return
        }
        let mentionsJSON = String(
            data: try encoder.encode(draft.mentions),
            encoding: .utf8
        ) ?? "[]"
        let replyJSON = draft.replyPreview
            .flatMap { try? encoder.encode($0) }
            .flatMap { String(data: $0, encoding: .utf8) }
        try db.execute(
            sql: """
            INSERT INTO drafts (
              account_id, dialog_id, state, text, reply_to_msg_id, reply_preview_json,
              mentions_json, local_generation, operation_id, server_revision,
              server_shadow_json, consumed_operation_id, terminal, last_error, updated_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, 0, ?, ?, ?, NULL, 0, NULL, ?)
            ON CONFLICT(account_id, dialog_id) DO UPDATE SET
              state = excluded.state,
              text = excluded.text,
              reply_to_msg_id = excluded.reply_to_msg_id,
              reply_preview_json = excluded.reply_preview_json,
              mentions_json = excluded.mentions_json,
              operation_id = excluded.operation_id,
              server_revision = excluded.server_revision,
              server_shadow_json = excluded.server_shadow_json,
              consumed_operation_id = NULL,
              terminal = 0,
              last_error = NULL,
              updated_at = excluded.updated_at
            """,
            arguments: [
                accountId, draft.dialogId, draft.state, draft.text, draft.replyToMsgId,
                replyJSON, mentionsJSON, draft.operationId, draft.revision, shadow,
                draft.updatedAt,
            ]
        )
        // A media id is not a transfer identity: the same uploaded object can be referenced by
        // multiple dialogs, accounts, and purposes. Only an exact existing draft attachment in
        // this account/dialog may retain its local transfer and encrypted staging files.
        let reusableTransferRows = try Row.fetchAll(
            db,
            sql: """
            SELECT attachment.attachment_id, attachment.transfer_id
            FROM draft_attachments attachment
            JOIN media_transfers transfer
              ON transfer.transfer_id = attachment.transfer_id
            WHERE attachment.account_id = ?
              AND attachment.dialog_id = ?
              AND transfer.dialog_id = ?
              AND transfer.purpose = 'draft'
              AND attachment.transfer_id IS NOT NULL
            """,
            arguments: [accountId, draft.dialogId, draft.dialogId]
        )
        let reusableTransferByAttachment = Dictionary(
            uniqueKeysWithValues: reusableTransferRows.compactMap { row -> (String, String)? in
                guard
                    let attachmentId: String = row["attachment_id"],
                    let transferId: String = row["transfer_id"]
                else { return nil }
                return (attachmentId, transferId)
            }
        )
        try db.execute(
            sql: "DELETE FROM draft_attachments WHERE account_id = ? AND dialog_id = ?",
            arguments: [accountId, draft.dialogId]
        )
        if draft.state == "active" {
            for attachment in draft.attachments.sorted(by: { $0.position < $1.position }) {
                // A different device has no staging file, but the server media id is already
                // sufficient to send. Keep a stable local transfer row so both paths are uniform.
                let reusableTransferId = reusableTransferByAttachment[attachment.attachmentId]
                let transferId = reusableTransferId
                    ?? "server:\(accountId):\(draft.dialogId):\(attachment.attachmentId)"
                let clientMsgId = reusableTransferId == nil
                    ? transferId
                    : attachment.attachmentId
                let mediaJSON = String(
                    data: try encoder.encode(attachment.media),
                    encoding: .utf8
                )
                try db.execute(
                    sql: """
                    INSERT INTO media_transfers (
                      transfer_id, dialog_id, client_msg_id, caption, reply_to_msg_id,
                      purpose, draft_attachment_id, kind, content_type, file_name, byte_size,
                      sha256, duration_ms, width, height, encrypted_source_path,
                      encrypted_thumbnail_path, media_id, upload_offset, state, created_at
                    ) VALUES (
                      ?, ?, ?, '', NULL, 'draft', ?, ?, ?, ?, ?, '', ?, ?, ?, '',
                      NULL, ?, 0, 'ready_to_send', datetime('now')
                    )
                    ON CONFLICT(transfer_id) DO UPDATE SET
                      dialog_id = excluded.dialog_id,
                      client_msg_id = excluded.client_msg_id,
                      media_id = excluded.media_id,
                      purpose = 'draft',
                      draft_attachment_id = excluded.draft_attachment_id,
                      state = 'ready_to_send',
                      terminal = 0,
                      next_retry_at = NULL,
                      last_error = NULL
                    """,
                    arguments: [
                        transferId, draft.dialogId, clientMsgId,
                        attachment.attachmentId, attachment.media.kind,
                        attachment.media.contentType, attachment.media.fileName,
                        attachment.media.byteSize, attachment.media.durationMs,
                        attachment.media.width, attachment.media.height, attachment.mediaId,
                    ]
                )
                try db.execute(
                    sql: """
                    INSERT INTO draft_attachments (
                      account_id, dialog_id, attachment_id, media_id, position,
                      media_json, transfer_id, state, progress
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, 'ready', 1)
                    """,
                    arguments: [
                        accountId, draft.dialogId, attachment.attachmentId,
                        attachment.mediaId, attachment.position, mediaJSON, transferId,
                    ]
                )
            }
        }
    }

    func preserveDraftDependency(
        _ db: Database,
        accountId: String,
        dialogId: String,
        operationId: String
    ) throws {
        try db.execute(
            sql: """
            INSERT INTO pending_draft_dependencies (
              account_id, dialog_id, operation_id, local_generation, payload_json,
              retry_count, next_retry_at, last_error, terminal, updated_at
            )
            SELECT account_id, dialog_id, operation_id, local_generation, payload_json,
                   retry_count, next_retry_at, last_error, terminal, updated_at
            FROM pending_draft_mutations
            WHERE account_id = ? AND dialog_id = ? AND operation_id = ?
            ON CONFLICT(operation_id) DO NOTHING
            """,
            arguments: [accountId, dialogId, operationId]
        )
        if try Int.fetchOne(
            db,
            sql: "SELECT COUNT(*) FROM pending_draft_dependencies WHERE operation_id = ?",
            arguments: [operationId]
        ) != 1 {
            // A draft restored on another device has already been acknowledged by the server and
            // therefore has no local mutation row. Reconstruct the exact immutable operation so
            // the send worker can idempotently re-ack it before consuming the draft.
            guard let draft = try Self.fetchDraft(
                db,
                accountId: accountId,
                dialogId: dialogId
            ), draft.operationId == operationId else {
                throw CloudLocalStoreBootstrapError.invalidStagedMessage
            }
            let payload = StoredDraftMutationPayload(
                state: draft.state,
                text: draft.text,
                replyToMsgId: draft.replyToMsgId,
                mentions: draft.mentions,
                attachments: draft.attachments.compactMap { attachment in
                    guard let mediaId = attachment.mediaId else { return nil }
                    return DraftAttachmentRequest(
                        attachmentId: attachment.attachmentId,
                        mediaId: mediaId,
                        position: attachment.position
                    )
                }
            )
            let payloadJSON = String(
                data: try JSONEncoder().encode(payload),
                encoding: .utf8
            ) ?? "{}"
            try db.execute(
                sql: """
                INSERT INTO pending_draft_dependencies (
                  account_id, dialog_id, operation_id, local_generation, payload_json,
                  retry_count, next_retry_at, last_error, terminal, updated_at
                ) VALUES (?, ?, ?, ?, ?, 0, NULL, NULL, 0, datetime('now'))
                ON CONFLICT(operation_id) DO NOTHING
                """,
                arguments: [
                    accountId, dialogId, operationId, draft.localGeneration, payloadJSON,
                ]
            )
        }
    }

    func materializeServerShadowIfUnblocked(
        _ db: Database,
        accountId: String,
        dialogId: String
    ) throws {
        let consumedCount = try Int.fetchOne(
            db,
            sql: """
            SELECT COUNT(*) FROM drafts
            WHERE account_id = ? AND dialog_id = ? AND consumed_operation_id IS NOT NULL
            """,
            arguments: [accountId, dialogId]
        ) ?? 0
        let pendingCount = try Int.fetchOne(
            db,
            sql: """
            SELECT COUNT(*) FROM pending_draft_mutations
            WHERE account_id = ? AND dialog_id = ?
            """,
            arguments: [accountId, dialogId]
        ) ?? 0
        let isBlocked = consumedCount != 0 || pendingCount != 0
        guard !isBlocked, let shadowJSON = try String.fetchOne(
            db,
            sql: """
            SELECT server_shadow_json FROM drafts
            WHERE account_id = ? AND dialog_id = ?
            """,
            arguments: [accountId, dialogId]
        ), let shadow = try? JSONDecoder().decode(CloudDraft.self, from: Data(shadowJSON.utf8))
        else { return }
        try applyCloudDraft(
            db,
            draft: shadow,
            accountId: accountId,
            preserveLocalOverlay: false
        )
        try db.execute(
            sql: """
            UPDATE drafts SET server_shadow_json = NULL
            WHERE account_id = ? AND dialog_id = ?
            """,
            arguments: [accountId, dialogId]
        )
    }

    private func rewriteDraftAttachmentOrder(
        _ db: Database,
        accountId: String,
        dialogId: String,
        attachmentIds: [String]
    ) throws {
        let rows = try Row.fetchAll(
            db,
            sql: """
            SELECT * FROM draft_attachments
            WHERE account_id = ? AND dialog_id = ?
            """,
            arguments: [accountId, dialogId]
        )
        let byId = Dictionary(uniqueKeysWithValues: rows.map {
            ($0["attachment_id"] as String, $0)
        })
        guard Set(byId.keys) == Set(attachmentIds), byId.count == attachmentIds.count else {
            throw CloudLocalStoreBootstrapError.invalidStagedMessage
        }
        try db.execute(
            sql: "DELETE FROM draft_attachments WHERE account_id = ? AND dialog_id = ?",
            arguments: [accountId, dialogId]
        )
        for (position, attachmentId) in attachmentIds.enumerated() {
            guard let row = byId[attachmentId] else {
                throw CloudLocalStoreBootstrapError.invalidStagedMessage
            }
            try db.execute(
                sql: """
                INSERT INTO draft_attachments (
                  account_id, dialog_id, attachment_id, media_id, position, media_json,
                  transfer_id, state, progress, last_error
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    accountId,
                    dialogId,
                    attachmentId,
                    row["media_id"] as String?,
                    position,
                    row["media_json"] as String?,
                    row["transfer_id"] as String?,
                    row["state"] as String,
                    row["progress"] as Double,
                    row["last_error"] as String?,
                ]
            )
        }
    }
}
