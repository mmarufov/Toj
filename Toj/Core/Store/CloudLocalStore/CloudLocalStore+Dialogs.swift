import Foundation
import GRDB
import os
import Security

extension CloudLocalStore {
    func upsertDialog(dialogId: String, type: String = "direct", title: String? = nil, lastMsgId: Int64 = 0, updatedAt: String? = nil) throws {
        try dbQueue.write { db in
            try upsertDialog(db, dialogId: dialogId, type: type, title: title, lastMsgId: lastMsgId, updatedAt: updatedAt)
        }
    }

    func savedMessagesDialogId(accountId: String) throws -> String? {
        try dbQueue.read { db in
            try String.fetchOne(
                db,
                sql: """
                SELECT dialog.dialog_id
                FROM dialogs dialog
                JOIN dialog_members member ON member.dialog_id = dialog.dialog_id
                WHERE dialog.type = 'saved'
                  AND dialog.access_state = 'active'
                  AND member.account_id = ?
                  AND member.is_active = 1
                ORDER BY dialog.updated_at DESC, dialog.dialog_id
                LIMIT 1
                """,
                arguments: [accountId]
            )
        }
    }

    func ensureSavedDialog(
        dialogId: String,
        accountId: String,
        updatedAt: String?
    ) throws {
        try Task.checkCancellation()
        try dbQueue.write { db in
            try Task.checkCancellation()
            try ensureSavedDialog(
                db,
                dialogId: dialogId,
                accountId: accountId,
                updatedAt: updatedAt
            )
        }
    }

    func dialogs(accountId: String) throws -> [LocalDialog] {
        try dbQueue.read { db in
            try Self.fetchDialogs(db, accountId: accountId)
        }
    }

    func isDialogAccessRevoked(dialogId: String) throws -> Bool {
        try dbQueue.read { db in
            try Self.isDialogRevoked(db, dialogId: dialogId)
        }
    }

    func isMediaPresentable(mediaId: String, dialogId: String) throws -> Bool {
        try mediaPresentationAuthorization(
            mediaId: mediaId,
            dialogId: dialogId
        ) != nil
    }

    func mediaPresentationAuthorization(
        mediaId: String,
        dialogId: String? = nil
    ) throws -> MediaPresentationAuthorization? {
        try dbQueue.read { db in
            try Row.fetchOne(
                db,
                sql: """
                SELECT media.dialog_id, media.media_id,
                       COALESCE(access.generation, 0) AS access_generation
                FROM message_media AS media
                JOIN dialogs AS dialog ON dialog.dialog_id = media.dialog_id
                LEFT JOIN dialog_access_generations AS access
                  ON access.dialog_id = media.dialog_id
                WHERE media.media_id = ?
                  AND (? IS NULL OR media.dialog_id = ?)
                  AND dialog.access_state = 'active'
                  AND COALESCE(access.authorized, 1) = 1
                  AND NOT EXISTS (
                    SELECT 1 FROM revoked_dialogs revoked
                    WHERE revoked.dialog_id = media.dialog_id
                  )
                UNION ALL
                SELECT dialog.dialog_id,
                       json_extract(profile.photo_media_json, '$.id') AS media_id,
                       COALESCE(access.generation, 0) AS access_generation
                FROM profiles AS profile
                JOIN dialog_members AS member ON member.account_id = profile.account_id
                  AND member.is_active = 1
                JOIN dialogs AS dialog ON dialog.dialog_id = member.dialog_id
                  AND dialog.access_state = 'active'
                LEFT JOIN dialog_access_generations AS access
                  ON access.dialog_id = dialog.dialog_id
                WHERE json_extract(profile.photo_media_json, '$.id') = ?
                  AND (? IS NULL OR dialog.dialog_id = ?)
                  AND COALESCE(access.authorized, 1) = 1
                  AND NOT EXISTS (
                    SELECT 1 FROM revoked_dialogs revoked
                    WHERE revoked.dialog_id = dialog.dialog_id
                  )
                ORDER BY 1
                LIMIT 1
                """,
                arguments: [mediaId, dialogId, dialogId, mediaId, dialogId, dialogId]
            ).map {
                MediaPresentationAuthorization(
                    dialogId: $0["dialog_id"],
                    mediaId: $0["media_id"],
                    accessGeneration: $0["access_generation"]
                )
            }
        }
    }

    func validatesMediaPresentationAuthorization(
        _ authorization: MediaPresentationAuthorization
    ) throws -> Bool {
        try mediaPresentationAuthorization(
            mediaId: authorization.mediaId,
            dialogId: authorization.dialogId
        ) == authorization
    }

    func containsProfile(accountId: String) throws -> Bool {
        try dbQueue.read { db in
            try Bool.fetchOne(
                db,
                sql: "SELECT EXISTS(SELECT 1 FROM profiles WHERE account_id = ?)",
                arguments: [accountId]
            ) ?? false
        }
    }

    nonisolated static func referencedAccountIds(_ update: CloudUpdate) -> Set<String> {
        var result = Set([
            update.readerAccountId,
            update.subjectAccountId,
            update.peerAccountId,
            update.member?.accountId,
            update.message?.senderAccountId,
            update.message?.forwardedFromAccountId,
            update.message?.serviceData?.actorAccountId,
            update.message?.serviceData?.subjectAccountId,
            update.message?.serviceData?.successorAccountId,
        ].compactMap { $0 })
        result.formUnion(update.message?.reactions.map(\.accountId) ?? [])
        result.formUnion(update.message?.mentions.map(\.accountId) ?? [])
        result.formUnion(update.message?.serviceData?.memberAccountIds ?? [])
        return result
    }

    func observeDialogs(accountId: String) -> AsyncThrowingStream<[LocalDialog], Error> {
        let values = ValueObservation
            .tracking { db in try Self.fetchDialogs(db, accountId: accountId) }
            .removeDuplicates()
            .values(
                in: dbQueue,
                scheduling: .async(onQueue: .global(qos: .userInitiated)),
                bufferingPolicy: .bufferingNewest(1)
            )
        return Self.stream(values)
    }

    func observeTimeline(
        dialogId: String,
        window: TimelineWindow = .initial
    ) -> AsyncThrowingStream<TimelineSnapshot, Error> {
        let values = ValueObservation
            .tracking { db in try Self.fetchTimeline(db, dialogId: dialogId, window: window) }
            .removeDuplicates()
            .values(
                in: dbQueue,
                scheduling: .async(onQueue: .global(qos: .userInitiated)),
                bufferingPolicy: .bufferingNewest(1)
            )
        return Self.stream(values)
    }

    /// Its first element is the authoritative initial load; the same observation owns all later
    /// database-driven updates. Consumers must not issue a second initial query beside this stream.
    func observeConversation(
        dialogId: String,
        window: TimelineWindow = .initial
    ) -> AsyncThrowingStream<ConversationLocalSnapshot, Error> {
        let values = ValueObservation
            .tracking {
                try Self.fetchConversationSnapshot($0, dialogId: dialogId, window: window)
            }
            .removeDuplicates()
            .values(
                in: dbQueue,
                scheduling: .async(onQueue: .global(qos: .userInitiated)),
                bufferingPolicy: .bufferingNewest(1)
            )
        return Self.stream(values)
    }

    func latestDialogId() throws -> String? {
        try dbQueue.read { db in
            try String.fetchOne(
                db,
                sql: """
                SELECT dialog_id
                FROM dialogs
                ORDER BY updated_at DESC, dialog_id DESC
                LIMIT 1
                """
            )
        }
    }

    func ensureDialogSummary(_ db: Database, dialogId: String) throws {
        try db.execute(
            sql: "INSERT INTO dialog_summaries (dialog_id) VALUES (?) ON CONFLICT(dialog_id) DO NOTHING",
            arguments: [dialogId]
        )
    }

    func refreshDialogSummary(_ db: Database, dialogId: String) throws {
        let row = try Row.fetchOne(
            db,
            sql: """
            SELECT local_id, msg_id, text, kind, state, sender_account_id, local_state, server_ts
            FROM messages candidate
            WHERE candidate.dialog_id = ?
              AND candidate.state = 'visible'
              AND NOT EXISTS (
                SELECT 1 FROM pending_message_mutations pending_delete
                WHERE pending_delete.dialog_id = candidate.dialog_id
                  AND pending_delete.msg_id = candidate.msg_id
                  AND pending_delete.operation = 'delete'
              )
            ORDER BY COALESCE(candidate.msg_id, 9223372036854775807) DESC, candidate.rowid DESC
            LIMIT 1
            """,
            arguments: [dialogId]
        )
        try db.execute(
            sql: """
            INSERT INTO dialog_summaries (
              dialog_id, last_local_id, last_msg_id, last_text, last_kind, last_state,
              last_sender_account_id, last_local_state, last_server_ts
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(dialog_id) DO UPDATE SET
              last_local_id = excluded.last_local_id,
              last_msg_id = excluded.last_msg_id,
              last_text = excluded.last_text,
              last_kind = excluded.last_kind,
              last_state = excluded.last_state,
              last_sender_account_id = excluded.last_sender_account_id,
              last_local_state = excluded.last_local_state,
              last_server_ts = excluded.last_server_ts
            """,
            arguments: [
                dialogId,
                row?["local_id"], row?["msg_id"], row?["text"], row?["kind"],
                row?["state"], row?["sender_account_id"], row?["local_state"], row?["server_ts"]
            ]
        )
    }

    func refreshUnreadSummary(_ db: Database, dialogId: String, accountId: String) throws {
        // Once bootstrap or a read acknowledgement supplied an authoritative server count, sparse
        // local history must never replace it with a count of only the cached rows.
        if try Bool.fetchOne(
            db,
            sql: """
            SELECT is_exact FROM dialog_unread_summaries
            WHERE dialog_id = ? AND account_id = ?
            """,
            arguments: [dialogId, accountId]
        ) == true {
            return
        }
        let count = try Int.fetchOne(
            db,
            sql: """
            SELECT COUNT(*)
            FROM messages message
            WHERE message.dialog_id = ?
              AND message.msg_id IS NOT NULL
              AND message.sender_account_id != ?
              AND message.state = 'visible'
              AND message.msg_id > COALESCE((
                SELECT last_read_msg_id FROM dialog_members
                WHERE dialog_id = ? AND account_id = ?
              ), 0)
            """,
            arguments: [dialogId, accountId, dialogId, accountId]
        ) ?? 0
        try setUnreadSummary(
            db,
            dialogId: dialogId,
            accountId: accountId,
            unreadCount: count,
            isExact: false
        )
    }

    func setUnreadSummary(
        _ db: Database,
        dialogId: String,
        accountId: String,
        unreadCount: Int,
        isExact: Bool
    ) throws {
        try db.execute(
            sql: """
            INSERT INTO dialog_unread_summaries (
              dialog_id, account_id, unread_count, is_exact, mention_count
            )
            VALUES (
              ?, ?, MAX(0, ?), ?,
              COALESCE((
                SELECT COUNT(*)
                FROM message_mentions mention
                JOIN messages message
                  ON message.dialog_id = mention.dialog_id AND message.msg_id = mention.msg_id
                WHERE mention.dialog_id = ? AND mention.account_id = ?
                  AND message.state = 'visible'
                  AND mention.msg_id > COALESCE((
                    SELECT last_read_msg_id FROM dialog_members
                    WHERE dialog_id = ? AND account_id = ?
                  ), 0)
              ), 0)
            )
            ON CONFLICT(dialog_id, account_id) DO UPDATE SET
              unread_count = excluded.unread_count,
              is_exact = excluded.is_exact,
              mention_count = excluded.mention_count
            """,
            arguments: [
                dialogId, accountId, unreadCount, isExact,
                dialogId, accountId, dialogId, accountId
            ]
        )
    }

    func adjustUnreadSummary(
        _ db: Database,
        dialogId: String,
        accountId: String,
        delta: Int
    ) throws {
        guard delta != 0 else { return }
        try db.execute(
            sql: """
            INSERT INTO dialog_unread_summaries (
              dialog_id, account_id, unread_count, is_exact, mention_count
            )
            VALUES (
              ?, ?, MAX(0, ?), 0,
              COALESCE((
                SELECT COUNT(*)
                FROM message_mentions mention
                JOIN messages message
                  ON message.dialog_id = mention.dialog_id AND message.msg_id = mention.msg_id
                WHERE mention.dialog_id = ? AND mention.account_id = ?
                  AND message.state = 'visible'
                  AND mention.msg_id > COALESCE((
                    SELECT last_read_msg_id FROM dialog_members
                    WHERE dialog_id = ? AND account_id = ?
                  ), 0)
              ), 0)
            )
            ON CONFLICT(dialog_id, account_id) DO UPDATE SET
              unread_count = MAX(0, dialog_unread_summaries.unread_count + ?),
              is_exact = dialog_unread_summaries.is_exact,
              mention_count = excluded.mention_count
            """,
            arguments: [
                dialogId, accountId, delta,
                dialogId, accountId, dialogId, accountId,
                delta
            ]
        )
    }

    func refreshAllUnreadSummaries(_ db: Database, dialogId: String) throws {
        let accountIds = try String.fetchAll(
            db,
            sql: "SELECT account_id FROM dialog_members WHERE dialog_id = ?",
            arguments: [dialogId]
        )
        for accountId in accountIds {
            try refreshUnreadSummary(db, dialogId: dialogId, accountId: accountId)
        }
    }

    func upsertDialog(
        _ db: Database,
        dialogId: String,
        type: String,
        title: String?,
        lastMsgId: Int64,
        updatedAt: String?
    ) throws {
        try db.execute(
            sql: """
            INSERT INTO dialogs (dialog_id, type, title, last_msg_id, updated_at)
            VALUES (?, ?, ?, ?, COALESCE(?, datetime('now')))
            ON CONFLICT(dialog_id) DO UPDATE SET
              type = CASE
                WHEN excluded.type = 'direct' AND dialogs.type <> 'direct' THEN dialogs.type
                ELSE excluded.type
              END,
              title = COALESCE(excluded.title, dialogs.title),
              last_msg_id = MAX(dialogs.last_msg_id, excluded.last_msg_id),
              updated_at = MAX(dialogs.updated_at, excluded.updated_at)
            """,
            arguments: [dialogId, type, title, lastMsgId, updatedAt]
        )
        try ensureDialogSummary(db, dialogId: dialogId)
    }

    func ensureSavedDialog(
        _ db: Database,
        dialogId: String,
        accountId: String,
        updatedAt: String?
    ) throws {
        try db.execute(
            sql: """
            INSERT INTO dialogs (
              dialog_id, type, title, last_msg_id, updated_at, revision,
              member_count, self_role, notification_mode, access_state
            ) VALUES (
              ?, 'saved', NULL, 0, COALESCE(?, datetime('now')), 0,
              1, 'owner', 'all', 'active'
            )
            ON CONFLICT(dialog_id) DO UPDATE SET
              type = 'saved',
              member_count = 1,
              self_role = 'owner',
              notification_mode = 'all',
              access_state = 'active',
              updated_at = CASE
                WHEN ? IS NULL THEN dialogs.updated_at
                ELSE MAX(dialogs.updated_at, excluded.updated_at)
              END
            """,
            arguments: [dialogId, updatedAt, updatedAt]
        )
        try ensureDialogSummary(db, dialogId: dialogId)
        try db.execute(
            sql: "DELETE FROM dialog_members WHERE dialog_id = ? AND account_id != ?",
            arguments: [dialogId, accountId]
        )
        try db.execute(
            sql: """
            INSERT INTO dialog_members (
              dialog_id, account_id, role, last_read_msg_id, joined_at,
              left_at, is_active, revision
            ) VALUES (
              ?, ?, 'owner', 0, datetime('now'), NULL, 1, 0
            )
            ON CONFLICT(dialog_id, account_id) DO UPDATE SET
              role = 'owner',
              left_at = NULL,
              is_active = 1
            """,
            arguments: [dialogId, accountId]
        )
        try setUnreadSummary(
            db,
            dialogId: dialogId,
            accountId: accountId,
            unreadCount: 0,
            isExact: true
        )
    }

    func ensureDialogPreferences(
        _ db: Database,
        accountId: String,
        dialogId: String
    ) throws {
        try db.execute(
            sql: """
            INSERT INTO dialog_preferences (
              account_id, dialog_id, is_pinned, pinned_at,
              is_muted, is_archived, server_updated_at
            )
            SELECT
              ?, dialog_id, 0, NULL,
              notification_mode = 'muted', 0, updated_at
            FROM dialogs
            WHERE dialog_id = ?
            ON CONFLICT(account_id, dialog_id) DO NOTHING
            """,
            arguments: [accountId, dialogId]
        )
    }

    func upsertDialogPreferences(
        _ db: Database,
        preferences: CloudDialogPreferences,
        accountId: String,
        clientMutationId: String?
    ) throws {
        guard try Bool.fetchOne(
            db,
            sql: "SELECT EXISTS(SELECT 1 FROM dialogs WHERE dialog_id = ?)",
            arguments: [preferences.dialogId]
        ) == true else { return }
        try db.execute(
            sql: """
            INSERT INTO dialog_preferences (
              account_id, dialog_id, is_pinned, pinned_at,
              is_muted, is_archived, server_updated_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(account_id, dialog_id) DO UPDATE SET
              is_pinned = excluded.is_pinned,
              pinned_at = excluded.pinned_at,
              is_muted = excluded.is_muted,
              is_archived = excluded.is_archived,
              server_updated_at = excluded.server_updated_at
            """,
            arguments: [
                accountId, preferences.dialogId, preferences.pinned, preferences.pinnedAt,
                preferences.muted, preferences.archived, preferences.updatedAt,
            ]
        )
        try db.execute(
            sql: """
            UPDATE dialogs
            SET notification_mode = ?
            WHERE dialog_id = ?
            """,
            arguments: [preferences.muted ? "muted" : "all", preferences.dialogId]
        )
        if let clientMutationId {
            try db.execute(
                sql: """
                DELETE FROM pending_dialog_preference_mutations
                WHERE account_id = ? AND client_mutation_id = ?
                """,
                arguments: [accountId, clientMutationId]
            )
        }
    }
}
