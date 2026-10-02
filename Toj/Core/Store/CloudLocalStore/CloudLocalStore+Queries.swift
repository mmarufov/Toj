import Foundation
import GRDB
import os
import Security

extension CloudLocalStore {
    func maxReadMsgId(dialogId: String, accountId: String) throws -> Int64 {
        try dbQueue.read { db in
            try Int64.fetchOne(
                db,
                sql: """
                SELECT last_read_msg_id
                FROM dialog_members
                WHERE dialog_id = ? AND account_id = ?
                """,
                arguments: [dialogId, accountId]
            ) ?? 0
        }
    }

    func maxPeerReadMsgId(dialogId: String, excluding accountId: String) throws -> Int64 {
        try dbQueue.read { db in
            try Int64.fetchOne(
                db,
                sql: """
                SELECT MAX(last_read_msg_id)
                FROM dialog_members
                WHERE dialog_id = ? AND account_id != ?
                """,
                arguments: [dialogId, accountId]
            ) ?? 0
        }
    }

    func peerAccountId(dialogId: String, excluding accountId: String) throws -> String? {
        try dbQueue.read { db in
            try String.fetchOne(
                db,
                sql: """
                SELECT account_id
                FROM dialog_members
                WHERE dialog_id = ? AND account_id != ?
                ORDER BY account_id
                LIMIT 1
                """,
                arguments: [dialogId, accountId]
            )
        }
    }

    func messages(dialogId: String) throws -> [LocalMessage] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT local_id, dialog_id, msg_id, client_msg_id, sender_account_id, kind, text,
                       reply_to_msg_id, forwarded_from_account_id, forwarded_from_dialog_id,
                       forwarded_from_msg_id, is_forwarded, media_json, edit_version, state, server_ts, local_state
                FROM messages
                WHERE dialog_id = ?
                ORDER BY COALESCE(msg_id, 9223372036854775807), rowid
                """,
                arguments: [dialogId]
            )
            return try Self.messages(from: rows, in: db, dialogId: dialogId)
        }
    }

    /// A bounded keyset read. With no cursor it returns the newest messages in ascending display
    /// order, including optimistic rows. `beforeMsgId` pages older server messages and
    /// `afterMsgId` pages newer server messages without an OFFSET scan.
    func messages(
        dialogId: String,
        limit: Int,
        beforeMsgId: Int64? = nil,
        afterMsgId: Int64? = nil
    ) throws -> [LocalMessage] {
        try dbQueue.read { db in
            try Self.fetchMessages(
                db,
                dialogId: dialogId,
                limit: limit,
                beforeMsgId: beforeMsgId,
                afterMsgId: afterMsgId
            )
        }
    }

    func messageWindow(
        dialogId: String,
        anchorMsgId: Int64,
        beforeCount: Int = 60,
        afterCount: Int = 59
    ) throws -> [LocalMessage] {
        try dbQueue.read { db in
            let before = try Self.fetchMessages(
                db,
                dialogId: dialogId,
                limit: beforeCount,
                beforeMsgId: anchorMsgId,
                afterMsgId: nil
            )
            let anchorRows = try Row.fetchAll(
                db,
                sql: Self.messageSelectionSQL + " WHERE dialog_id = ? AND msg_id = ? LIMIT 1",
                arguments: [dialogId, anchorMsgId]
            )
            let anchor = try Self.messages(from: anchorRows, in: db, dialogId: dialogId)
            let after = try Self.fetchMessages(
                db,
                dialogId: dialogId,
                limit: afterCount,
                beforeMsgId: nil,
                afterMsgId: anchorMsgId
            )
            return Array((before + anchor + after).prefix(TimelineWindow.maximumRetainedMessages))
        }
    }

    func timelineWindow(
        dialogId: String,
        anchorMsgId: Int64,
        beforeCount: Int = 60,
        afterCount: Int = 59
    ) throws -> TimelineSnapshot {
        try dbQueue.read { db in
            let before = try Self.fetchMessages(
                db,
                dialogId: dialogId,
                limit: beforeCount,
                beforeMsgId: anchorMsgId,
                afterMsgId: nil
            )
            let anchorRows = try Row.fetchAll(
                db,
                sql: Self.messageSelectionSQL + " WHERE dialog_id = ? AND msg_id = ? LIMIT 1",
                arguments: [dialogId, anchorMsgId]
            )
            let anchor = try Self.messages(from: anchorRows, in: db, dialogId: dialogId)
            let after = try Self.fetchMessages(
                db,
                dialogId: dialogId,
                limit: afterCount,
                beforeMsgId: nil,
                afterMsgId: anchorMsgId
            )
            let messages = Array(
                (before + anchor + after).prefix(TimelineWindow.maximumRetainedMessages)
            )
            return try Self.timelineSnapshot(db, dialogId: dialogId, messages: messages)
        }
    }

    func timeline(dialogId: String, window: TimelineWindow = .initial) throws -> TimelineSnapshot {
        try dbQueue.read { db in
            try Self.fetchTimeline(db, dialogId: dialogId, window: window)
        }
    }

    func conversationSnapshot(
        dialogId: String,
        window: TimelineWindow = .initial
    ) throws -> ConversationLocalSnapshot {
        try dbQueue.read { db in
            try Self.fetchConversationSnapshot(db, dialogId: dialogId, window: window)
        }
    }

    func firstUnreadMessageId(dialogId: String, accountId: String) throws -> Int64? {
        try dbQueue.read { db in
            try Self.fetchFirstUnreadMessageId(db, dialogId: dialogId, accountId: accountId)
        }
    }

    func resolveOpeningAnchor(dialogId: String, accountId: String) throws -> TimelineAnchor {
        try dbQueue.read { db in
            let lastReadMsgId = try Int64.fetchOne(
                db,
                sql: """
                SELECT last_read_msg_id FROM dialog_members
                WHERE dialog_id = ? AND account_id = ?
                """,
                arguments: [dialogId, accountId]
            ) ?? 0
            let dialogCeiling = try Int64.fetchOne(
                db,
                sql: "SELECT last_msg_id FROM dialogs WHERE dialog_id = ?",
                arguments: [dialogId]
            ) ?? 0
            let historyComplete = try Bool.fetchOne(
                db,
                sql: "SELECT history_complete FROM dialog_history_state WHERE dialog_id = ?",
                arguments: [dialogId]
            ) ?? false
            let unreadSummary = try Row.fetchOne(
                db,
                sql: """
                SELECT unread_count, is_exact FROM dialog_unread_summaries
                WHERE dialog_id = ? AND account_id = ?
                """,
                arguments: [dialogId, accountId]
            )
            let unreadIsExact: Bool = unreadSummary?["is_exact"] ?? false
            let exactUnreadCount: Int? = unreadIsExact ? unreadSummary?["unread_count"] : nil
            let localFirstUnread = try Self.fetchFirstUnreadMessageId(
                db,
                dialogId: dialogId,
                accountId: accountId
            )

            if exactUnreadCount != 0, let localFirstUnread {
                if historyComplete {
                    return .firstUnread(msgId: localFirstUnread)
                }
                if try Self.hasContiguousMessageRange(
                    db,
                    dialogId: dialogId,
                    lowerBound: lastReadMsgId + 1,
                    upperBound: localFirstUnread
                ) {
                    return .firstUnread(msgId: localFirstUnread)
                }
            }
            if exactUnreadCount.map({ $0 > 0 }) == true
                || (exactUnreadCount == nil && !historyComplete && lastReadMsgId < dialogCeiling) {
                // A sparse bootstrap can contain the candidate row itself (including an outgoing
                // row from another device) without containing every row through the first incoming
                // message. Keep it provisional until targeted forward hydration proves continuity.
                return .provisionalFirstUnread(msgId: lastReadMsgId + 1)
            }
            if let viewport = try Self.fetchViewportState(db, dialogId: dialogId, accountId: accountId) {
                if viewport.wasAtBottom { return .bottom }
                if let msgId = viewport.topVisibleMsgId,
                   let resolved = try Self.resolveVisibleSavedMessage(
                       db,
                       dialogId: dialogId,
                       targetMsgId: msgId
                   ) {
                    return .saved(msgId: resolved)
                }
            }
            return .bottom
        }
    }

    func loadViewportState(dialogId: String, accountId: String) throws -> ChatViewportState? {
        try dbQueue.read { db in
            try Self.fetchViewportState(db, dialogId: dialogId, accountId: accountId)
        }
    }

    func saveViewportState(_ state: ChatViewportState) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                INSERT INTO chat_viewport_state (
                  dialog_id, account_id, top_visible_msg_id, was_at_bottom, updated_at
                ) VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(dialog_id, account_id) DO UPDATE SET
                  top_visible_msg_id = excluded.top_visible_msg_id,
                  was_at_bottom = excluded.was_at_bottom,
                  updated_at = excluded.updated_at
                """,
                arguments: [
                    state.dialogId, state.accountId, state.topVisibleMsgId,
                    state.wasAtBottom, state.updatedAt
                ]
            )
        }
    }

    func loadHistoryState(dialogId: String) throws -> DialogHistoryState? {
        try dbQueue.read { db in
            try Row.fetchOne(
                db,
                sql: "SELECT * FROM dialog_history_state WHERE dialog_id = ?",
                arguments: [dialogId]
            ).map(Self.historyState(from:))
        }
    }

    func saveHistoryState(_ state: DialogHistoryState) throws {
        try dbQueue.write { db in
            try upsertHistoryState(db, state: state)
        }
    }

    func historyStatesReady(now: Date = Date(), limit: Int = 20) throws -> [DialogHistoryState] {
        try dbQueue.read { db in
            try Row.fetchAll(
                db,
                sql: """
                SELECT * FROM dialog_history_state
                WHERE history_complete = 0 AND (next_retry_at IS NULL OR next_retry_at <= ?)
                ORDER BY updated_at, dialog_id
                LIMIT ?
                """,
                arguments: [Self.sqliteTimestamp(now), max(1, limit)]
            ).map(Self.historyState(from:))
        }
    }

    func historyStatesReady(
        dialogIds: [String],
        now: Date = Date()
    ) throws -> [DialogHistoryState] {
        let uniqueIds = Array(Set(dialogIds)).sorted().prefix(200)
        guard !uniqueIds.isEmpty else { return [] }
        let placeholders = Array(repeating: "?", count: uniqueIds.count).joined(separator: ",")
        let arguments = StatementArguments(Array(uniqueIds) + [Self.sqliteTimestamp(now)])
        return try dbQueue.read { db in
            try Row.fetchAll(
                db,
                sql: """
                SELECT * FROM dialog_history_state
                WHERE dialog_id IN (\(placeholders))
                  AND history_complete = 0
                  AND (next_retry_at IS NULL OR next_retry_at <= ?)
                ORDER BY updated_at, dialog_id
                """,
                arguments: arguments
            ).map(Self.historyState(from:))
        }
    }

    func markHistoryHydrationFailed(
        dialogId: String,
        retryAfter: TimeInterval,
        now: Date = Date()
    ) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                UPDATE dialog_history_state
                SET retry_count = retry_count + 1, next_retry_at = ?, updated_at = ?
                WHERE dialog_id = ?
                """,
                arguments: [
                    Self.sqliteTimestamp(now.addingTimeInterval(max(0, retryAfter))),
                    Self.sqliteTimestamp(now), dialogId
                ]
            )
        }
    }

    func loadBootstrapState(accountId: String) throws -> ReplicaBootstrapState? {
        try dbQueue.read { db in
            try Row.fetchOne(
                db,
                sql: "SELECT * FROM bootstrap_state WHERE account_id = ?",
                arguments: [accountId]
            ).map(Self.bootstrapState(from:))
        }
    }

    nonisolated private static let messageSelectionSQL = """
    SELECT local_id, dialog_id, msg_id, client_msg_id, sender_account_id, kind, text,
           reply_to_msg_id, forwarded_from_account_id, forwarded_from_dialog_id,
           forwarded_from_msg_id, is_forwarded, mentions_json,
           media_json, service_type, service_data_json, link_preview_json,
           media_group_id, media_group_index, media_group_count,
           edit_version, state,
           server_ts, local_state,
           (SELECT display_name FROM profiles WHERE account_id = messages.sender_account_id)
             AS sender_display_name,
           rowid AS storage_rowid
    FROM messages
    """

    nonisolated private static func fetchMessages(
        _ db: Database,
        dialogId: String,
        limit: Int,
        beforeMsgId: Int64?,
        afterMsgId: Int64?
    ) throws -> [LocalMessage] {
        guard limit > 0 else { return [] }
        let boundedLimit = min(limit, TimelineWindow.maximumRetainedMessages)
        let rows: [Row]
        switch (beforeMsgId, afterMsgId) {
        case let (before?, after?):
            rows = try Row.fetchAll(
                db,
                sql: messageSelectionSQL + """
                 WHERE dialog_id = ? AND msg_id < ? AND msg_id > ?
                 ORDER BY msg_id ASC, storage_rowid ASC
                 LIMIT ?
                """,
                arguments: [dialogId, before, after, boundedLimit]
            )
        case let (before?, nil):
            rows = try Row.fetchAll(
                db,
                sql: """
                SELECT * FROM (
                  \(messageSelectionSQL)
                  WHERE dialog_id = ? AND msg_id < ?
                  ORDER BY msg_id DESC, storage_rowid DESC
                  LIMIT ?
                ) ORDER BY msg_id ASC, storage_rowid ASC
                """,
                arguments: [dialogId, before, boundedLimit]
            )
        case let (nil, after?):
            rows = try Row.fetchAll(
                db,
                sql: messageSelectionSQL + """
                 WHERE dialog_id = ? AND msg_id > ?
                 ORDER BY msg_id ASC, storage_rowid ASC
                 LIMIT ?
                """,
                arguments: [dialogId, after, boundedLimit]
            )
        case (nil, nil):
            // Keep optimistic rows at the end without wrapping the indexed server ordering in
            // COALESCE. COALESCE forced SQLite to sort the whole conversation before LIMIT,
            // turning every online observation into a visible hitch on large chats.
            let pendingRows = try Row.fetchAll(
                db,
                sql: messageSelectionSQL + """
                 WHERE dialog_id = ? AND msg_id IS NULL
                 ORDER BY storage_rowid ASC
                 LIMIT ?
                """,
                arguments: [dialogId, boundedLimit]
            )
            let serverLimit = max(0, boundedLimit - pendingRows.count)
            let serverRows: [Row]
            if serverLimit > 0 {
                serverRows = try Row.fetchAll(
                    db,
                    sql: """
                    SELECT * FROM (
                      \(messageSelectionSQL)
                      WHERE dialog_id = ? AND msg_id IS NOT NULL
                      ORDER BY msg_id DESC
                      LIMIT ?
                    ) ORDER BY msg_id ASC
                    """,
                    arguments: [dialogId, serverLimit]
                )
            } else {
                serverRows = []
            }
            rows = serverRows + pendingRows
        }
        return try messages(from: rows, in: db, dialogId: dialogId)
    }

    nonisolated private static func messages(
        from rows: [Row],
        in db: Database,
        dialogId: String
    ) throws -> [LocalMessage] {
        let serverIds: [Int64] = rows.compactMap { $0["msg_id"] }
        var reactionsByMessage: [Int64: [CloudReaction]] = [:]
        if let minimum = serverIds.min(), let maximum = serverIds.max() {
            let reactionRows = try Row.fetchAll(
                db,
                sql: """
                SELECT msg_id, account_id, emoji
                FROM message_reactions
                WHERE dialog_id = ? AND msg_id BETWEEN ? AND ?
                ORDER BY msg_id, account_id
                """,
                arguments: [dialogId, minimum, maximum]
            )
            for row in reactionRows {
                let msgId: Int64 = row["msg_id"]
                reactionsByMessage[msgId, default: []].append(
                    CloudReaction(accountId: row["account_id"], emoji: row["emoji"])
                )
            }
        }
        return rows.map { row in
            let msgId: Int64? = row["msg_id"]
            return message(from: row, reactions: msgId.flatMap { reactionsByMessage[$0] } ?? [])
        }
    }

    nonisolated static func fetchTimeline(
        _ db: Database,
        dialogId: String,
        window: TimelineWindow
    ) throws -> TimelineSnapshot {
        let messages = try fetchMessages(
            db,
            dialogId: dialogId,
            limit: window.limit,
            beforeMsgId: window.beforeMsgId,
            afterMsgId: window.afterMsgId
        )
        return try timelineSnapshot(db, dialogId: dialogId, messages: messages)
    }

    nonisolated static func fetchConversationSnapshot(
        _ db: Database,
        dialogId: String,
        window: TimelineWindow
    ) throws -> ConversationLocalSnapshot {
        let timeline = try fetchTimeline(db, dialogId: dialogId, window: window)
        let mutations = try Row.fetchAll(
            db,
            sql: """
            SELECT * FROM pending_message_mutations
            WHERE dialog_id = ?
            ORDER BY created_at, client_mutation_id
            """,
            arguments: [dialogId]
        ).map(Self.messageMutation(from:))
        let transfers = try Row.fetchAll(
            db,
            sql: """
            SELECT * FROM media_transfers
            WHERE dialog_id = ?
            ORDER BY created_at, transfer_id
            """,
            arguments: [dialogId]
        ).map(Self.mediaTransfer(from:))
        let accountId = try String.fetchOne(
            db,
            sql: "SELECT account_id FROM sync_state ORDER BY updated_at DESC LIMIT 1"
        )
        let peerReadMsgId: Int64
        if let accountId {
            peerReadMsgId = try Int64.fetchOne(
                db,
                sql: """
                SELECT MAX(last_read_msg_id)
                FROM dialog_members
                WHERE dialog_id = ? AND account_id != ?
                """,
                arguments: [dialogId, accountId]
            ) ?? 0
        } else {
            peerReadMsgId = 0
        }
        let historyState = try Row.fetchOne(
            db,
            sql: "SELECT * FROM dialog_history_state WHERE dialog_id = ?",
            arguments: [dialogId]
        ).map(Self.historyState(from:))
        return ConversationLocalSnapshot(
            timeline: timeline,
            mutations: mutations,
            transfers: transfers,
            peerReadMsgId: peerReadMsgId,
            historyState: historyState
        )
    }

    nonisolated private static func timelineSnapshot(
        _ db: Database,
        dialogId: String,
        messages: [LocalMessage]
    ) throws -> TimelineSnapshot {
        let ids = messages.compactMap(\.msgId)
        let oldest = ids.min()
        let newest = ids.max()
        let hasEarlier: Bool
        if let oldest {
            hasEarlier = try Bool.fetchOne(
                db,
                sql: "SELECT EXISTS(SELECT 1 FROM messages WHERE dialog_id = ? AND msg_id < ?)",
                arguments: [dialogId, oldest]
            ) ?? false
        } else {
            hasEarlier = false
        }
        let hasLaterServerMessage: Bool
        if let newest {
            hasLaterServerMessage = try Bool.fetchOne(
                db,
                sql: "SELECT EXISTS(SELECT 1 FROM messages WHERE dialog_id = ? AND msg_id > ?)",
                arguments: [dialogId, newest]
            ) ?? false
        } else {
            hasLaterServerMessage = false
        }
        let includesOptimisticRows = messages.contains { $0.msgId == nil }
        let hasLaterOptimisticMessage: Bool
        if includesOptimisticRows {
            hasLaterOptimisticMessage = false
        } else {
            hasLaterOptimisticMessage = try Bool.fetchOne(
                db,
                sql: "SELECT EXISTS(SELECT 1 FROM messages WHERE dialog_id = ? AND msg_id IS NULL)",
                arguments: [dialogId]
            ) ?? false
        }
        return TimelineSnapshot(
            messages: messages,
            oldestServerMsgId: oldest,
            newestServerMsgId: newest,
            hasEarlierLocalMessages: hasEarlier,
            hasLaterLocalMessages: hasLaterServerMessage || hasLaterOptimisticMessage
        )
    }

    nonisolated private static func hasContiguousMessageRange(
        _ db: Database,
        dialogId: String,
        lowerBound: Int64,
        upperBound: Int64
    ) throws -> Bool {
        guard lowerBound <= upperBound else { return false }
        let expectedCount = upperBound - lowerBound + 1
        let cachedCount = try Int64.fetchOne(
            db,
            sql: """
            SELECT COUNT(DISTINCT msg_id)
            FROM messages
            WHERE dialog_id = ? AND msg_id BETWEEN ? AND ?
            """,
            arguments: [dialogId, lowerBound, upperBound]
        ) ?? 0
        return cachedCount == expectedCount
    }

    /// Resolve a deleted/expired semantic anchor predictably: first the next visible server row,
    /// then the previous visible row. This remains stable as media/local-only rows are rewritten.
    nonisolated private static func resolveVisibleSavedMessage(
        _ db: Database,
        dialogId: String,
        targetMsgId: Int64
    ) throws -> Int64? {
        if let next = try Int64.fetchOne(
            db,
            sql: """
            SELECT msg_id FROM messages
            WHERE dialog_id = ? AND msg_id >= ? AND state = 'visible'
            ORDER BY msg_id ASC LIMIT 1
            """,
            arguments: [dialogId, targetMsgId]
        ) {
            return next
        }
        return try Int64.fetchOne(
            db,
            sql: """
            SELECT msg_id FROM messages
            WHERE dialog_id = ? AND msg_id < ? AND state = 'visible'
            ORDER BY msg_id DESC LIMIT 1
            """,
            arguments: [dialogId, targetMsgId]
        )
    }

    nonisolated private static func fetchFirstUnreadMessageId(
        _ db: Database,
        dialogId: String,
        accountId: String
    ) throws -> Int64? {
        try Int64.fetchOne(
            db,
            sql: """
            SELECT MIN(message.msg_id)
            FROM messages message
            WHERE message.dialog_id = ?
              AND message.msg_id IS NOT NULL
              AND message.sender_account_id != ?
              AND message.state = 'visible'
              AND message.msg_id > COALESCE((
                SELECT member.last_read_msg_id
                FROM dialog_members member
                WHERE member.dialog_id = ? AND member.account_id = ?
              ), 0)
            """,
            arguments: [dialogId, accountId, dialogId, accountId]
        )
    }

    nonisolated private static func fetchViewportState(
        _ db: Database,
        dialogId: String,
        accountId: String
    ) throws -> ChatViewportState? {
        guard let row = try Row.fetchOne(
            db,
            sql: "SELECT * FROM chat_viewport_state WHERE dialog_id = ? AND account_id = ?",
            arguments: [dialogId, accountId]
        ) else { return nil }
        return ChatViewportState(
            dialogId: row["dialog_id"],
            accountId: row["account_id"],
            topVisibleMsgId: row["top_visible_msg_id"],
            wasAtBottom: row["was_at_bottom"],
            updatedAt: row["updated_at"]
        )
    }

    nonisolated static func fetchDialogs(_ db: Database, accountId: String) throws -> [LocalDialog] {
        let rows = try Row.fetchAll(
            db,
            sql: """
            SELECT
              d.dialog_id,
              d.type,
              d.title,
              CASE WHEN d.type = 'direct' THEN profile.photo_media_json ELSE d.photo_media_json END
                AS photo_media_json,
              d.last_msg_id,
              CASE
                WHEN draft.updated_at IS NOT NULL
                  AND julianday(draft.updated_at) > julianday(d.updated_at)
                THEN draft.updated_at
                ELSE d.updated_at
              END AS updated_at,
              d.revision,
              d.member_count,
              d.self_role,
              d.notification_mode,
              d.access_state,
              COALESCE(pending_pin.desired_value, preference.is_pinned, 0) AS is_pinned,
              CASE
                WHEN pending_pin.client_mutation_id IS NOT NULL
                  THEN CASE WHEN pending_pin.desired_value = 1 THEN pending_pin.desired_at ELSE NULL END
                ELSE preference.pinned_at
              END AS pinned_at,
              CASE
                WHEN pending_mute.local_order IS NOT NULL
                  AND (
                    pending_legacy_mute.local_order IS NULL
                    OR pending_mute.local_order >= pending_legacy_mute.local_order
                  )
                  THEN pending_mute.desired_value
                WHEN pending_legacy_mute.local_order IS NOT NULL
                  THEN json_extract(pending_legacy_mute.payload_json, '$.mode') = 'muted'
                ELSE COALESCE(preference.is_muted, 0)
              END AS is_muted,
              COALESCE(pending_archive.desired_value, preference.is_archived, 0) AS is_archived,
              peer.account_id AS peer_account_id,
              profile.bio AS peer_bio,
              profile.birthday AS peer_birthday,
              profile.color_index AS peer_color_index,
              summary.last_text,
              summary.last_kind,
              summary.last_state,
              summary.last_sender_account_id,
              summary.last_local_state,
              summary.last_server_ts,
              COALESCE(unread.unread_count, 0) AS unread_count,
              COALESCE(unread.mention_count, 0) AS mention_count,
              CASE WHEN draft.state = 'active' THEN draft.text END AS draft_text,
              CASE
                WHEN draft.state = 'active' THEN (
                  SELECT COUNT(*) FROM draft_attachments attachment
                  WHERE attachment.account_id = draft.account_id
                    AND attachment.dialog_id = draft.dialog_id
                )
                ELSE 0
              END AS draft_attachment_count,
              CASE
                WHEN draft.state = 'active' AND draft.reply_to_msg_id IS NOT NULL THEN 1
                ELSE 0
              END AS has_draft_reply
            FROM dialogs d
            LEFT JOIN dialog_members peer ON peer.dialog_id = d.dialog_id
              AND peer.account_id != ? AND d.type = 'direct'
            LEFT JOIN profiles profile ON profile.account_id = peer.account_id
            LEFT JOIN dialog_summaries summary ON summary.dialog_id = d.dialog_id
            LEFT JOIN dialog_unread_summaries unread
              ON unread.dialog_id = d.dialog_id AND unread.account_id = ?
            LEFT JOIN dialog_preferences preference
              ON preference.dialog_id = d.dialog_id AND preference.account_id = ?
            LEFT JOIN pending_dialog_preference_mutations pending_pin
              ON pending_pin.dialog_id = d.dialog_id
             AND pending_pin.account_id = ?
             AND pending_pin.field = 'pinned'
             AND pending_pin.terminal = 0
             AND pending_pin.local_order = (
               SELECT MAX(latest.local_order)
               FROM pending_dialog_preference_mutations latest
               WHERE latest.account_id = pending_pin.account_id
                 AND latest.dialog_id = pending_pin.dialog_id
                 AND latest.field = pending_pin.field
                 AND latest.terminal = 0
             )
            LEFT JOIN pending_dialog_preference_mutations pending_mute
              ON pending_mute.dialog_id = d.dialog_id
             AND pending_mute.account_id = ?
             AND pending_mute.field = 'muted'
             AND pending_mute.terminal = 0
             AND pending_mute.local_order = (
               SELECT MAX(latest.local_order)
               FROM pending_dialog_preference_mutations latest
               WHERE latest.account_id = pending_mute.account_id
                 AND latest.dialog_id = pending_mute.dialog_id
                 AND latest.field = pending_mute.field
                 AND latest.terminal = 0
             )
            LEFT JOIN pending_group_mutations pending_legacy_mute
              ON pending_legacy_mute.dialog_id = d.dialog_id
             AND pending_legacy_mute.operation = 'notifications'
             AND pending_legacy_mute.terminal = 0
             AND pending_legacy_mute.local_order = (
               SELECT MAX(latest.local_order)
               FROM pending_group_mutations latest
               WHERE latest.dialog_id = pending_legacy_mute.dialog_id
                 AND latest.operation = 'notifications'
                 AND latest.terminal = 0
             )
            LEFT JOIN pending_dialog_preference_mutations pending_archive
              ON pending_archive.dialog_id = d.dialog_id
             AND pending_archive.account_id = ?
             AND pending_archive.field = 'archived'
             AND pending_archive.terminal = 0
             AND pending_archive.local_order = (
               SELECT MAX(latest.local_order)
               FROM pending_dialog_preference_mutations latest
               WHERE latest.account_id = pending_archive.account_id
                 AND latest.dialog_id = pending_archive.dialog_id
                 AND latest.field = pending_archive.field
                 AND latest.terminal = 0
             )
            LEFT JOIN drafts draft
              ON draft.dialog_id = d.dialog_id AND draft.account_id = ?
            WHERE d.access_state IN ('pending','active')
            ORDER BY
              is_pinned DESC,
              pinned_at DESC,
              MAX(
                julianday(d.updated_at),
                COALESCE(julianday(draft.updated_at), julianday(d.updated_at))
              ) DESC,
              d.dialog_id DESC
            """,
            arguments: [
                accountId, accountId,
                accountId, accountId, accountId, accountId, accountId,
            ]
        )
        return rows.map(dialog(from:))
    }

    nonisolated static func stream<Element: Sendable>(
        _ values: AsyncValueObservation<Element>
    ) -> AsyncThrowingStream<Element, Error> {
        let box = AsyncObservationBox(values)
        return AsyncThrowingStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let task = Task {
                do {
                    for try await value in box.values {
                        if case .terminated = continuation.yield(value) { break }
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }
}
