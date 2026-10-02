import Foundation
import GRDB
import os
import Security

extension CloudLocalStore {
    @discardableResult
    func createPendingGroup(
        groupId: String,
        title: String,
        memberIds: [String],
        creatorAccountId: String,
        localPhotoReference: String? = nil
    ) throws -> Bool {
        let normalizedMembers = Array(Set(memberIds.filter { $0 != creatorAccountId })).sorted()
        let memberData = try JSONEncoder().encode(normalizedMembers)
        guard let memberJSON = String(data: memberData, encoding: .utf8) else {
            throw CloudLocalStoreBootstrapError.invalidGroupState
        }
        return try dbQueue.write { db in
            let exists = try Bool.fetchOne(
                db,
                sql: "SELECT EXISTS(SELECT 1 FROM pending_group_creations WHERE group_id = ?)",
                arguments: [groupId]
            ) ?? false
            if exists { return false }
            try db.execute(
                sql: """
                INSERT INTO dialogs (
                  dialog_id, type, title, last_msg_id, updated_at, revision, member_count,
                  self_role, notification_mode, access_state
                ) VALUES (?, 'group', ?, 0, datetime('now'), 0, ?, 'owner', 'all', 'pending')
                ON CONFLICT(dialog_id) DO NOTHING
                """,
                arguments: [groupId, title, normalizedMembers.count + 1]
            )
            try ensureDialogSummary(db, dialogId: groupId)
            try db.execute(
                sql: """
                INSERT INTO dialog_members (
                  dialog_id, account_id, role, last_read_msg_id, joined_at, is_active, revision
                ) VALUES (?, ?, 'owner', 0, datetime('now'), 1, 0)
                ON CONFLICT(dialog_id, account_id) DO UPDATE SET
                  role = 'owner', is_active = 1, left_at = NULL
                """,
                arguments: [groupId, creatorAccountId]
            )
            for memberId in normalizedMembers {
                try db.execute(
                    sql: """
                    INSERT INTO dialog_members (
                      dialog_id, account_id, role, last_read_msg_id, joined_at, is_active, revision
                    ) VALUES (?, ?, 'member', 0, datetime('now'), 1, 0)
                    ON CONFLICT(dialog_id, account_id) DO UPDATE SET
                      role = 'member', is_active = 1, left_at = NULL
                    """,
                    arguments: [groupId, memberId]
                )
            }
            try db.execute(
                sql: """
                INSERT INTO pending_group_creations (
                  group_id, title, member_ids_json, local_photo_reference, state,
                  created_at, updated_at
                ) VALUES (?, ?, ?, ?, 'queued', datetime('now'), datetime('now'))
                """,
                arguments: [groupId, title, memberJSON, localPhotoReference]
            )
            return true
        }
    }

    func pendingGroupCreationsReady(limit: Int = 10) throws -> [PendingGroupCreation] {
        try dbQueue.read { db in
            try Row.fetchAll(
                db,
                sql: """
                SELECT * FROM pending_group_creations
                WHERE terminal = 0 AND state IN ('queued','creating')
                  AND (next_retry_at IS NULL OR next_retry_at <= datetime('now'))
                ORDER BY created_at
                LIMIT ?
                """,
                arguments: [max(1, min(50, limit))]
            ).compactMap(Self.pendingGroupCreation(from:))
        }
    }

    func nextPendingGroupCreationDelay(now: Date = Date()) throws -> TimeInterval? {
        let nowText = Self.sqliteTimestamp(now)
        return try dbQueue.read { db in
            let due = try Int.fetchOne(
                db,
                sql: """
                SELECT COUNT(*) FROM pending_group_creations
                WHERE terminal = 0 AND state IN ('queued','creating')
                  AND (next_retry_at IS NULL OR next_retry_at <= ?)
                """,
                arguments: [nowText]
            ) ?? 0
            if due > 0 { return 0 }
            guard let next = try String.fetchOne(
                db,
                sql: """
                SELECT MIN(next_retry_at) FROM pending_group_creations
                WHERE terminal = 0 AND state IN ('queued','creating') AND next_retry_at > ?
                """,
                arguments: [nowText]
            ), let date = Self.makeSQLiteDateFormatter().date(from: next) else { return nil }
            return max(0, date.timeIntervalSince(now))
        }
    }

    func markGroupCreating(groupId: String) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                UPDATE pending_group_creations
                SET state = 'creating', last_error = NULL, updated_at = datetime('now')
                WHERE group_id = ? AND terminal = 0
                """,
                arguments: [groupId]
            )
        }
    }

    func retryGroupCreation(
        groupId: String,
        after delay: TimeInterval,
        error: String
    ) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                UPDATE pending_group_creations
                SET state = 'queued', retry_count = retry_count + 1,
                    next_retry_at = ?, last_error = ?, updated_at = datetime('now')
                WHERE group_id = ? AND terminal = 0
                """,
                arguments: [
                    Self.sqliteTimestamp(Date().addingTimeInterval(max(1, delay))),
                    error,
                    groupId,
                ]
            )
        }
    }

    func failGroupCreation(groupId: String, error: String) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                UPDATE pending_group_creations
                SET state = 'failed', terminal = 1, last_error = ?, updated_at = datetime('now')
                WHERE group_id = ?
                """,
                arguments: [error, groupId]
            )
        }
    }

    func retryFailedGroupCreation(groupId: String) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                UPDATE pending_group_creations
                SET state = 'queued', terminal = 0, next_retry_at = NULL,
                    last_error = NULL, updated_at = datetime('now')
                WHERE group_id = ?
                """,
                arguments: [groupId]
            )
        }
    }

    func enqueueGroupMutation(
        dialogId: String,
        operation: String,
        payloadJSON: String,
        clientMutationId: String,
        accountId: String? = nil
    ) throws {
        try dbQueue.write { db in
            let localOrder = try Self.nextLocalMutationOrder(db)
            let createdAt = Self.preferenceTimestamp(Date())
            if operation == "notifications" {
                // Coalesce only rows that provably never left this process. Attempted rows retain
                // their mutation ID and order until the server resolves them.
                try db.execute(
                    sql: """
                    DELETE FROM pending_group_mutations
                    WHERE dialog_id = ? AND operation = 'notifications'
                      AND terminal = 0 AND attempted_at IS NULL
                    """,
                    arguments: [dialogId]
                )
            }
            try db.execute(
                sql: """
                INSERT INTO pending_group_mutations (
                  client_mutation_id, dialog_id, operation, payload_json,
                  created_at, local_order, attempted_at
                ) VALUES (?, ?, ?, ?, ?, ?, NULL)
                ON CONFLICT(client_mutation_id) DO NOTHING
                """,
                arguments: [
                    clientMutationId, dialogId, operation, payloadJSON,
                    createdAt, localOrder,
                ]
            )
            _ = accountId
        }
    }

    func movePendingGroupMutesToLegacy(accountId: String) throws -> Int {
        try dbQueue.write { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT pending.*
                FROM pending_dialog_preference_mutations pending
                JOIN dialogs dialog ON dialog.dialog_id = pending.dialog_id
                WHERE pending.account_id = ?
                  AND pending.field = 'muted'
                  AND pending.terminal = 0
                  AND pending.acknowledged_pts IS NULL
                  AND pending.attempted_at IS NULL
                  AND dialog.type = 'group'
                  AND NOT EXISTS (
                    SELECT 1
                    FROM pending_dialog_preference_mutations attempted
                    WHERE attempted.account_id = pending.account_id
                      AND attempted.dialog_id = pending.dialog_id
                      AND attempted.field = pending.field
                      AND attempted.terminal = 0
                      AND attempted.acknowledged_pts IS NULL
                      AND attempted.attempted_at IS NOT NULL
                  )
                  AND pending.local_order = (
                    SELECT MAX(latest.local_order)
                    FROM pending_dialog_preference_mutations latest
                    WHERE latest.account_id = pending.account_id
                      AND latest.dialog_id = pending.dialog_id
                      AND latest.field = pending.field
                      AND latest.terminal = 0
                      AND latest.acknowledged_pts IS NULL
                  )
                ORDER BY pending.local_order
                """,
                arguments: [accountId]
            )
            for row in rows {
                let desired = (row["desired_value"] as Int) != 0
                let payload = desired ? #"{"mode":"muted"}"# : #"{"mode":"all"}"#
                let dialogId: String = row["dialog_id"]
                let localOrder: Int64 = row["local_order"]
                let newerLegacyOrder = try Int64.fetchOne(
                    db,
                    sql: """
                    SELECT MAX(local_order)
                    FROM pending_group_mutations
                    WHERE dialog_id = ? AND operation = 'notifications'
                      AND terminal = 0 AND attempted_at IS NULL
                    """,
                    arguments: [dialogId]
                )
                if newerLegacyOrder == nil || newerLegacyOrder! <= localOrder {
                    try db.execute(
                        sql: """
                        DELETE FROM pending_group_mutations
                        WHERE dialog_id = ? AND operation = 'notifications'
                          AND terminal = 0 AND attempted_at IS NULL
                        """,
                        arguments: [dialogId]
                    )
                    try db.execute(
                        sql: """
                        INSERT INTO pending_group_mutations (
                          client_mutation_id, dialog_id, operation, payload_json,
                          created_at, retry_count, next_retry_at, last_error,
                          terminal, local_order, attempted_at
                        ) VALUES (?, ?, 'notifications', ?, ?, ?, NULL, NULL, 0, ?, NULL)
                        """,
                        arguments: [
                            row["client_mutation_id"], dialogId, payload,
                            row["desired_at"], row["retry_count"], localOrder,
                        ]
                    )
                }
                try db.execute(
                    sql: """
                    DELETE FROM pending_dialog_preference_mutations
                    WHERE account_id = ? AND dialog_id = ? AND field = 'muted'
                      AND terminal = 0 AND acknowledged_pts IS NULL
                      AND attempted_at IS NULL
                    """,
                    arguments: [accountId, dialogId]
                )
            }
            try db.execute(
                sql: """
                UPDATE pending_dialog_preference_mutations
                SET dormant = 1, next_retry_at = NULL
                WHERE account_id = ? AND terminal = 0
                  AND acknowledged_pts IS NULL
                """,
                arguments: [accountId]
            )
            return rows.count
        }
    }

    func pendingGroupMutationsReady(
        now: Date = Date(),
        limit: Int = 20
    ) throws -> [PendingGroupMutation] {
        try dbQueue.read { db in
            try Row.fetchAll(
                db,
                sql: """
                SELECT pending_group_mutations.* FROM pending_group_mutations
                LEFT JOIN dialogs
                  ON dialogs.dialog_id = pending_group_mutations.dialog_id
                WHERE pending_group_mutations.terminal = 0
                  AND COALESCE(dialogs.access_state, 'active') <> 'pending'
                  AND (
                    pending_group_mutations.next_retry_at IS NULL
                    OR pending_group_mutations.next_retry_at <= ?
                  )
                ORDER BY pending_group_mutations.local_order
                LIMIT ?
                """,
                arguments: [Self.sqliteTimestamp(now), max(1, min(100, limit))]
            ).map(Self.pendingGroupMutation(from:))
        }
    }

    func markGroupMutationAttempted(clientMutationId: String) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                UPDATE pending_group_mutations
                SET attempted_at = COALESCE(attempted_at, ?)
                WHERE client_mutation_id = ? AND terminal = 0
                """,
                arguments: [Self.preferenceTimestamp(Date()), clientMutationId]
            )
        }
    }

    func completeGroupMutation(clientMutationId: String) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "DELETE FROM pending_group_mutations WHERE client_mutation_id = ?",
                arguments: [clientMutationId]
            )
        }
    }

    func failGroupMutation(
        clientMutationId: String,
        retryAfter: TimeInterval?,
        error: String,
        terminal: Bool
    ) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                UPDATE pending_group_mutations
                SET retry_count = retry_count + 1,
                    next_retry_at = ?,
                    last_error = ?,
                    terminal = ?
                WHERE client_mutation_id = ?
                """,
                arguments: [
                    retryAfter.map {
                        Self.sqliteTimestamp(Date().addingTimeInterval(max(1, $0)))
                    },
                    error,
                    terminal,
                    clientMutationId,
                ]
            )
        }
    }

    func nextPendingGroupMutationDelay(now: Date = Date()) throws -> TimeInterval? {
        let nowText = Self.sqliteTimestamp(now)
        return try dbQueue.read { db in
            let due = try Int.fetchOne(
                db,
                sql: """
                SELECT COUNT(*) FROM pending_group_mutations
                LEFT JOIN dialogs
                  ON dialogs.dialog_id = pending_group_mutations.dialog_id
                WHERE pending_group_mutations.terminal = 0
                  AND COALESCE(dialogs.access_state, 'active') <> 'pending'
                  AND (
                    pending_group_mutations.next_retry_at IS NULL
                    OR pending_group_mutations.next_retry_at <= ?
                  )
                """,
                arguments: [nowText]
            ) ?? 0
            if due > 0 { return 0 }
            guard let next = try String.fetchOne(
                db,
                sql: """
                SELECT MIN(pending_group_mutations.next_retry_at)
                FROM pending_group_mutations
                LEFT JOIN dialogs
                  ON dialogs.dialog_id = pending_group_mutations.dialog_id
                WHERE pending_group_mutations.terminal = 0
                  AND COALESCE(dialogs.access_state, 'active') <> 'pending'
                  AND pending_group_mutations.next_retry_at > ?
                """,
                arguments: [nowText]
            ), let date = Self.makeSQLiteDateFormatter().date(from: next) else { return nil }
            return max(0, date.timeIntervalSince(now))
        }
    }

    func applyGroupEnvelope(_ envelope: CloudGroupEnvelope) throws {
        try dbQueue.write { db in
            guard try !Self.isDialogRevoked(db, dialogId: envelope.group.id) else {
                throw CloudLocalStoreAccessError.revoked
            }
            for profile in envelope.profiles {
                try upsertProfile(db, profile: profile)
            }
            try applyGroup(db, group: envelope.group)
            for member in envelope.members ?? [] {
                try upsertGroupMember(
                    db,
                    dialogId: envelope.group.id,
                    member: member,
                    revision: envelope.group.revision
                )
            }
            try db.execute(
                sql: "DELETE FROM pending_group_creations WHERE group_id = ?",
                arguments: [envelope.group.id]
            )
        }
    }

    func applyGroupMembersPage(_ page: CloudGroupMembersPage, generation: String) throws {
        try dbQueue.write { db in
            guard try !Self.isDialogRevoked(db, dialogId: page.group.id) else {
                throw CloudLocalStoreAccessError.revoked
            }
            for profile in page.profiles {
                try upsertProfile(db, profile: profile)
            }
            try applyGroup(db, group: page.group)
            for member in page.members {
                try upsertGroupMember(
                    db,
                    dialogId: page.group.id,
                    member: member,
                    revision: page.group.revision,
                    generation: generation
                )
            }
            if !page.hasMore {
                try db.execute(
                    sql: """
                    DELETE FROM dialog_members
                    WHERE dialog_id = ? AND COALESCE(seen_generation, '') <> ?
                    """,
                    arguments: [page.group.id, generation]
                )
                try db.execute(
                    sql: "DELETE FROM group_member_hydration WHERE dialog_id = ?",
                    arguments: [page.group.id]
                )
            }
        }
    }

    func revokeGroupAccess(
        dialogId: String,
        accessState: String = "removed",
        reason: String
    ) throws {
        try dbQueue.write { db in
            try revokeGroupAccess(
                db,
                dialogId: dialogId,
                accessState: accessState,
                reason: reason
            )
        }
    }

    private func applyGroup(_ db: Database, group: CloudGroup) throws {
        let photoJSON = group.photo
            .flatMap { try? JSONEncoder().encode($0) }
            .flatMap { String(data: $0, encoding: .utf8) }
        try db.execute(
            sql: """
            INSERT INTO dialogs (
              dialog_id, type, title, last_msg_id, updated_at, revision, photo_media_json,
              member_count, self_role, notification_mode, access_state
            ) VALUES (?, 'group', ?, 0, datetime('now'), ?, ?, ?, ?, ?, 'active')
            ON CONFLICT(dialog_id) DO UPDATE SET
              type = 'group',
              title = CASE WHEN excluded.revision >= dialogs.revision
                THEN excluded.title ELSE dialogs.title END,
              photo_media_json = CASE WHEN excluded.revision >= dialogs.revision
                THEN excluded.photo_media_json ELSE dialogs.photo_media_json END,
              member_count = CASE WHEN excluded.revision >= dialogs.revision
                THEN excluded.member_count ELSE dialogs.member_count END,
              self_role = excluded.self_role,
              notification_mode = excluded.notification_mode,
              access_state = 'active',
              revision = MAX(dialogs.revision, excluded.revision),
              updated_at = MAX(dialogs.updated_at, excluded.updated_at)
            """,
            arguments: [
                group.id, group.title, group.revision, photoJSON, group.memberCount,
                group.selfRole, group.notificationMode,
            ]
        )
        try db.execute(
            sql: """
            UPDATE dialog_preferences
            SET is_muted = ?, server_updated_at = datetime('now')
            WHERE dialog_id = ?
              AND account_id = (
                SELECT account_id FROM sync_state ORDER BY updated_at DESC LIMIT 1
              )
            """,
            arguments: [group.notificationMode == "muted", group.id]
        )
        try ensureDialogSummary(db, dialogId: group.id)
    }

    func applyGroupMetadata(_ db: Database, group: CloudUpdateGroup) throws {
        let existingRevision = try Int64.fetchOne(
            db,
            sql: "SELECT revision FROM dialogs WHERE dialog_id = ?",
            arguments: [group.id]
        ) ?? -1
        guard group.revision > existingRevision else { return }
        try db.execute(
            sql: """
            INSERT INTO dialogs (
              dialog_id, type, title, last_msg_id, updated_at, revision, member_count,
              notification_mode, access_state
            ) VALUES (?, 'group', ?, 0, datetime('now'), ?, ?, 'all', 'active')
            ON CONFLICT(dialog_id) DO UPDATE SET
              type = 'group',
              title = COALESCE(excluded.title, dialogs.title),
              revision = excluded.revision,
              member_count = excluded.member_count,
              updated_at = excluded.updated_at
            """,
            arguments: [group.id, group.title, group.revision, group.memberCount]
        )
        try ensureDialogSummary(db, dialogId: group.id)
    }

    func upsertGroupMember(
        _ db: Database,
        dialogId: String,
        member: CloudGroupMember,
        revision: Int64,
        generation: String? = nil
    ) throws {
        let localRevision = try Int64.fetchOne(
            db,
            sql: """
            SELECT revision FROM dialog_members
            WHERE dialog_id = ? AND account_id = ?
            """,
            arguments: [dialogId, member.accountId]
        ) ?? -1
        guard revision >= localRevision else { return }
        try db.execute(
            sql: """
            INSERT INTO dialog_members (
              dialog_id, account_id, role, last_read_msg_id, joined_at, left_at,
              is_active, revision, seen_generation
            ) VALUES (?, ?, ?, 0, ?, NULL, ?, ?, ?)
            ON CONFLICT(dialog_id, account_id) DO UPDATE SET
              role = excluded.role,
              joined_at = excluded.joined_at,
              left_at = excluded.left_at,
              is_active = excluded.is_active,
              revision = excluded.revision,
              seen_generation = COALESCE(excluded.seen_generation, dialog_members.seen_generation)
            """,
            arguments: [
                dialogId, member.accountId, member.role, member.joinedAt,
                member.isActive, revision, generation,
            ]
        )
    }

    func revokeGroupAccess(
        _ db: Database,
        dialogId: String,
        accessState: String,
        reason: String,
        revokedPts: Int64 = 0,
        explicitDialogType: String? = nil
    ) throws {
        let storedDialogType = try String.fetchOne(
            db,
            sql: "SELECT type FROM dialogs WHERE dialog_id = ?",
            arguments: [dialogId]
        )
        let dialogType = explicitDialogType ?? storedDialogType
        try recordDialogRevocation(
            db,
            dialogId: dialogId,
            dialogType: dialogType,
            revokedPts: revokedPts
        )
        try db.execute(
            sql: """
            INSERT INTO revoked_dialogs (dialog_id, dialog_type, revoked_pts, created_at)
            VALUES (?, ?, ?, datetime('now'))
            ON CONFLICT(dialog_id) DO UPDATE SET
              dialog_type = COALESCE(excluded.dialog_type, revoked_dialogs.dialog_type),
              revoked_pts = MAX(revoked_dialogs.revoked_pts, excluded.revoked_pts)
            """,
            arguments: [dialogId, dialogType, revokedPts]
        )
        // Receipt replay after a completed purge refreshes the durable tombstone only. It must not
        // create an empty purge job or any presentation state.
        guard storedDialogType != nil else { return }
        let mediaIds = Set(try String.fetchAll(
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
        let purgeMediaIds = try Set(mediaIds.filter { mediaId in
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
        let encryptedPaths = Set(try String.fetchAll(
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
        // Access state is the first write in this transaction so every observation hides the
        // conversation even if the process exits before the durable purge is drained.
        try db.execute(
            sql: "UPDATE dialogs SET access_state = ?, updated_at = datetime('now') WHERE dialog_id = ?",
            arguments: [accessState, dialogId]
        )
        try db.execute(
            sql: """
            INSERT INTO pending_access_purges (
              id, dialog_id, all_media_ids_json, purge_media_ids_json,
              encrypted_paths_json, phase, attempts, created_at, updated_at
            ) VALUES (?, ?, ?, ?, ?, 'staged', 0, datetime('now'), datetime('now'))
            ON CONFLICT(dialog_id) DO NOTHING
            """,
            arguments: [
                UUID().uuidString.lowercased(), dialogId,
                Self.encodeStringSet(mediaIds), Self.encodeStringSet(purgeMediaIds),
                Self.encodeStringSet(encryptedPaths),
            ]
        )
        // Remove plaintext/outbox and encrypted-upload payloads immediately. The canonical message
        // archive stays hidden until encrypted files are gone, then finalization removes all SQL.
        let pendingLocalIds = try String.fetchAll(
            db,
            sql: "SELECT local_id FROM messages WHERE dialog_id = ? AND msg_id IS NULL",
            arguments: [dialogId]
        )
        for localId in pendingLocalIds {
            try db.execute(sql: "DELETE FROM message_media WHERE local_id = ?", arguments: [localId])
        }
        try db.execute(sql: "DELETE FROM messages WHERE dialog_id = ? AND msg_id IS NULL", arguments: [dialogId])
        try db.execute(sql: "DELETE FROM pending_outbox WHERE dialog_id = ?", arguments: [dialogId])
        try db.execute(sql: "DELETE FROM media_transfers WHERE dialog_id = ?", arguments: [dialogId])
        try db.execute(sql: "DELETE FROM pending_message_mutations WHERE dialog_id = ?", arguments: [dialogId])
        try db.execute(sql: "DELETE FROM pending_group_mutations WHERE dialog_id = ?", arguments: [dialogId])
        try db.execute(
            sql: "DELETE FROM pending_draft_dependencies WHERE dialog_id = ?",
            arguments: [dialogId]
        )
        try db.execute(
            sql: "DELETE FROM pending_draft_mutations WHERE dialog_id = ?",
            arguments: [dialogId]
        )
        try db.execute(
            sql: """
            DELETE FROM pending_media_group_cleanup
            WHERE client_group_id IN (
              SELECT client_group_id FROM pending_media_group_sends WHERE dialog_id = ?
            )
            """,
            arguments: [dialogId]
        )
        try db.execute(
            sql: "DELETE FROM pending_media_group_sends WHERE dialog_id = ?",
            arguments: [dialogId]
        )
        try db.execute(
            sql: "DELETE FROM draft_attachments WHERE dialog_id = ?",
            arguments: [dialogId]
        )
        try db.execute(
            sql: "DELETE FROM drafts WHERE dialog_id = ?",
            arguments: [dialogId]
        )
        try db.execute(sql: "DELETE FROM media_download_jobs WHERE dialog_id = ?", arguments: [dialogId])
        try db.execute(sql: "DELETE FROM dialog_unread_summaries WHERE dialog_id = ?", arguments: [dialogId])
        try db.execute(sql: "DELETE FROM group_member_hydration WHERE dialog_id = ?", arguments: [dialogId])
    }

    nonisolated static func encodeStringSet(_ values: Set<String>) -> String {
        let data = (try? JSONEncoder().encode(values.sorted())) ?? Data("[]".utf8)
        return String(data: data, encoding: .utf8) ?? "[]"
    }

    nonisolated static func decodeStringSet(_ value: String?) -> Set<String> {
        guard
            let value,
            let data = value.data(using: .utf8),
            let decoded = try? JSONDecoder().decode([String].self, from: data)
        else { return [] }
        return Set(decoded)
    }

    nonisolated static func accessPurgeJob(from row: Row) -> AccessPurgeJob? {
        guard let phase = AccessPurgePhase(rawValue: row["phase"]) else { return nil }
        return AccessPurgeJob(
            id: row["id"],
            dialogId: row["dialog_id"],
            allMediaIds: decodeStringSet(row["all_media_ids_json"]),
            purgeMediaIds: decodeStringSet(row["purge_media_ids_json"]),
            encryptedPaths: decodeStringSet(row["encrypted_paths_json"]),
            phase: phase,
            attempts: row["attempts"],
            lastError: row["last_error"]
        )
    }

    nonisolated static func isDialogRevoked(
        _ db: Database,
        dialogId: String
    ) throws -> Bool {
        try Bool.fetchOne(
            db,
            sql: "SELECT EXISTS(SELECT 1 FROM revoked_dialogs WHERE dialog_id = ?)",
            arguments: [dialogId]
        ) ?? false
    }

    nonisolated static func revokedDialog(
        _ db: Database,
        dialogId: String
    ) throws -> (dialogType: String?, pts: Int64)? {
        guard let row = try Row.fetchOne(
            db,
            sql: """
            SELECT dialog_type, revoked_pts
            FROM revoked_dialogs
            WHERE dialog_id = ?
            """,
            arguments: [dialogId]
        ) else { return nil }
        return (row["dialog_type"], row["revoked_pts"])
    }

    private func recordDialogRevocation(
        _ db: Database,
        dialogId: String,
        dialogType: String?,
        revokedPts: Int64
    ) throws {
        try db.execute(
            sql: """
            INSERT INTO dialog_access_generations (
              dialog_id, generation, authorized, dialog_type, last_pts
            ) VALUES (?, 1, 0, ?, ?)
            ON CONFLICT(dialog_id) DO UPDATE SET
              generation = CASE
                WHEN dialog_access_generations.authorized = 1
                  OR excluded.last_pts > dialog_access_generations.last_pts
                THEN dialog_access_generations.generation + 1
                ELSE dialog_access_generations.generation
              END,
              authorized = 0,
              dialog_type = COALESCE(excluded.dialog_type, dialog_access_generations.dialog_type),
              last_pts = MAX(dialog_access_generations.last_pts, excluded.last_pts)
            """,
            arguments: [dialogId, dialogType, revokedPts]
        )
    }

    func restoreGroupAccess(
        _ db: Database,
        dialogId: String,
        grantedPts: Int64
    ) throws {
        // A server-authored grant newer than the durable revoke PTS is the only transition that
        // removes a group tombstone. Saved tombstones never call this path.
        try db.execute(
            sql: """
            INSERT INTO dialog_access_generations (
              dialog_id, generation, authorized, dialog_type, last_pts
            ) VALUES (?, 1, 1, 'group', ?)
            ON CONFLICT(dialog_id) DO UPDATE SET
              generation = dialog_access_generations.generation + 1,
              authorized = 1,
              dialog_type = 'group',
              last_pts = excluded.last_pts
            """,
            arguments: [dialogId, grantedPts]
        )
        try db.execute(
            sql: "DELETE FROM pending_access_purges WHERE dialog_id = ?",
            arguments: [dialogId]
        )
        try db.execute(
            sql: "DELETE FROM revoked_dialogs WHERE dialog_id = ? AND dialog_type = 'group'",
            arguments: [dialogId]
        )
        try db.execute(
            sql: "UPDATE dialogs SET access_state = 'active', updated_at = datetime('now') WHERE dialog_id = ?",
            arguments: [dialogId]
        )
    }
}
