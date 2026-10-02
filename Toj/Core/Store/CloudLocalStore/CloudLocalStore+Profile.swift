import Foundation
import GRDB
import os
import Security

extension CloudLocalStore {
    func saveMembers(dialogId: String, members: [BootstrapDialogMember]) throws {
        try dbQueue.write { db in
            for member in members {
                try upsertMember(db, dialogId: dialogId, member: member)
            }
        }
    }

    func saveProfile(_ profile: CloudProfile) throws {
        try dbQueue.write { db in
            try upsertProfile(db, profile: profile)
        }
    }

    func profile(accountId: String) throws -> CloudProfile? {
        try dbQueue.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT * FROM profiles WHERE account_id = ?",
                arguments: [accountId]
            ) else { return nil }
            return try Self.profile(from: row)
        }
    }

    /// Persists the local overlay and its encrypted upload record as one crash-safe unit.
    func stageProfilePhotoSet(
        accountId: String,
        prepared: PreparedMediaUpload,
        basePhotoRevision: Int64,
        source: String = "user"
    ) throws -> PendingProfilePhotoMutation {
        let mutationId = UUID().uuidString.lowercased()
        try dbQueue.write { db in
            try db.execute(
                sql: "DELETE FROM media_transfers WHERE transfer_id IN (SELECT transfer_id FROM pending_profile_photo_mutations WHERE account_id = ?)",
                arguments: [accountId]
            )
            try db.execute(
                sql: "DELETE FROM pending_profile_photo_mutations WHERE account_id = ?",
                arguments: [accountId]
            )
            try db.execute(
                sql: """
                INSERT INTO media_transfers (
                  transfer_id, dialog_id, client_msg_id, caption, reply_to_msg_id,
                  purpose, kind, content_type, file_name, byte_size, sha256, duration_ms, width, height,
                  encrypted_source_path, encrypted_thumbnail_path, state, created_at
                ) VALUES (?, ?, ?, '', NULL, 'profile_photo', ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'pending', datetime('now'))
                """,
                arguments: [
                    prepared.transferId, accountId, "profile-photo:\(mutationId)", prepared.kind,
                    prepared.contentType, prepared.fileName, prepared.byteSize, prepared.sha256,
                    prepared.durationMs, prepared.width, prepared.height, prepared.encryptedSourcePath,
                    prepared.encryptedThumbnailPath,
                ]
            )
            try db.execute(
                sql: """
                INSERT INTO pending_profile_photo_mutations (
                  account_id, client_mutation_id, base_photo_revision, operation,
                  transfer_id, source, state, created_at, updated_at
                ) VALUES (?, ?, ?, 'set', ?, ?, 'pending', datetime('now'), datetime('now'))
                """,
                arguments: [accountId, mutationId, basePhotoRevision, prepared.transferId, source]
            )
        }
        return try pendingProfilePhotoMutation(accountId: accountId)!
    }

    func stageProfilePhotoRemoval(
        accountId: String,
        basePhotoRevision: Int64
    ) throws -> PendingProfilePhotoMutation {
        let mutationId = UUID().uuidString.lowercased()
        try dbQueue.write { db in
            try db.execute(
                sql: "DELETE FROM media_transfers WHERE transfer_id IN (SELECT transfer_id FROM pending_profile_photo_mutations WHERE account_id = ?)",
                arguments: [accountId]
            )
            try db.execute(
                sql: "DELETE FROM pending_profile_photo_mutations WHERE account_id = ?",
                arguments: [accountId]
            )
            try db.execute(
                sql: """
                INSERT INTO pending_profile_photo_mutations (
                  account_id, client_mutation_id, base_photo_revision, operation,
                  source, state, created_at, updated_at
                ) VALUES (?, ?, ?, 'remove', 'user', 'ready_to_commit', datetime('now'), datetime('now'))
                """,
                arguments: [accountId, mutationId, basePhotoRevision]
            )
        }
        return try pendingProfilePhotoMutation(accountId: accountId)!
    }

    func pendingProfilePhotoMutation(accountId: String) throws -> PendingProfilePhotoMutation? {
        try dbQueue.read { db in
            try Row.fetchOne(
                db,
                sql: "SELECT * FROM pending_profile_photo_mutations WHERE account_id = ?",
                arguments: [accountId]
            ).map(Self.pendingProfilePhotoMutation(from:))
        }
    }

    func readyProfilePhotoMutation(accountId: String, now: Date = Date()) throws -> PendingProfilePhotoMutation? {
        try dbQueue.read { db in
            try Row.fetchOne(
                db,
                sql: """
                SELECT * FROM pending_profile_photo_mutations
                WHERE account_id = ? AND terminal = 0
                  AND state = 'ready_to_commit'
                  AND (next_retry_at IS NULL OR next_retry_at <= ?)
                """,
                arguments: [accountId, Self.sqliteTimestamp(now)]
            ).map(Self.pendingProfilePhotoMutation(from:))
        }
    }

    func markProfilePhotoUploaded(transferId: String, mediaId: String) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                UPDATE pending_profile_photo_mutations
                SET media_id = ?, state = 'ready_to_commit', last_error = NULL,
                    next_retry_at = NULL, updated_at = datetime('now')
                WHERE transfer_id = ?
                """,
                arguments: [mediaId, transferId]
            )
        }
    }

    func failProfilePhotoMutation(
        accountId: String,
        clientMutationId: String,
        error: String,
        retryAfter: TimeInterval?,
        conflict: Bool = false,
        terminal: Bool = false
    ) throws -> Bool {
        let next = retryAfter.map { Self.sqliteTimestamp(Date().addingTimeInterval($0)) }
        return try dbQueue.write { db in
            try db.execute(
                sql: """
                UPDATE pending_profile_photo_mutations
                SET state = ?, retry_count = retry_count + 1, next_retry_at = ?,
                    last_error = ?, terminal = ?, updated_at = datetime('now')
                WHERE account_id = ? AND client_mutation_id = ?
                """,
                arguments: [
                    conflict ? "conflict" : "ready_to_commit", next, error, terminal,
                    accountId, clientMutationId,
                ]
            )
            return db.changesCount == 1
        }
    }

    func failProfilePhotoUpload(
        accountId: String,
        clientMutationId: String,
        error: String,
        retryAfter: TimeInterval
    ) throws -> Bool {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                UPDATE pending_profile_photo_mutations
                SET state = 'pending', retry_count = retry_count + 1, next_retry_at = ?,
                    last_error = ?, terminal = 0, updated_at = datetime('now')
                WHERE account_id = ? AND client_mutation_id = ?
                """,
                arguments: [
                    Self.sqliteTimestamp(Date().addingTimeInterval(retryAfter)), error,
                    accountId, clientMutationId,
                ]
            )
            return db.changesCount == 1
        }
    }

    func rebaseProfilePhotoMutation(
        accountId: String,
        clientMutationId: String,
        baseRevision: Int64
    ) throws -> Bool {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                UPDATE pending_profile_photo_mutations
                SET client_mutation_id = ?, base_photo_revision = ?, state = 'ready_to_commit',
                    retry_count = 0, next_retry_at = NULL, last_error = NULL, terminal = 0,
                    updated_at = datetime('now')
                WHERE account_id = ? AND client_mutation_id = ?
                """,
                arguments: [
                    UUID().uuidString.lowercased(), baseRevision, accountId, clientMutationId,
                ]
            )
            return db.changesCount == 1
        }
    }

    func retryProfilePhotoMutation(accountId: String, clientMutationId: String) throws -> Bool {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                UPDATE pending_profile_photo_mutations
                SET state = CASE
                      WHEN operation = 'remove' THEN 'ready_to_commit'
                      WHEN media_id IS NULL THEN 'pending'
                      ELSE 'ready_to_commit'
                    END,
                    retry_count = 0, next_retry_at = NULL, last_error = NULL,
                    terminal = 0, updated_at = datetime('now')
                WHERE account_id = ? AND client_mutation_id = ? AND state <> 'conflict'
                """,
                arguments: [accountId, clientMutationId]
            )
            let retried = db.changesCount == 1
            guard retried else { return false }
            try db.execute(
                sql: """
                UPDATE media_transfers
                SET terminal = 0, next_retry_at = NULL, last_error = NULL,
                    state = CASE WHEN media_id IS NULL THEN 'pending' ELSE state END
                WHERE transfer_id IN (
                  SELECT transfer_id FROM pending_profile_photo_mutations
                  WHERE account_id = ? AND client_mutation_id = ?
                )
                """,
                arguments: [accountId, clientMutationId]
            )
            return true
        }
    }

    /// Applies canonical server state while completing only the mutation that produced it.
    /// A newer optimistic intent for the same account must survive a delayed response.
    func completeProfilePhotoMutation(
        accountId: String,
        clientMutationId: String,
        profile: CloudProfile
    ) throws -> Bool {
        try dbQueue.write { db in
            let mutation = try Row.fetchOne(
                db,
                sql: """
                SELECT transfer_id FROM pending_profile_photo_mutations
                WHERE account_id = ? AND client_mutation_id = ?
                """,
                arguments: [accountId, clientMutationId]
            )
            try upsertProfile(db, profile: profile)
            guard let mutation else { return false }
            let transferId: String? = mutation["transfer_id"]
            if let transferId {
                try db.execute(sql: "DELETE FROM media_transfers WHERE transfer_id = ?", arguments: [transferId])
            }
            try db.execute(
                sql: """
                DELETE FROM pending_profile_photo_mutations
                WHERE account_id = ? AND client_mutation_id = ?
                """,
                arguments: [accountId, clientMutationId]
            )
            return db.changesCount == 1
        }
    }

    func discardProfilePhotoMutation(accountId: String) throws -> String? {
        try dbQueue.write { db in
            let transferId = try String.fetchOne(
                db,
                sql: "SELECT transfer_id FROM pending_profile_photo_mutations WHERE account_id = ?",
                arguments: [accountId]
            )
            if let transferId {
                try db.execute(sql: "DELETE FROM media_transfers WHERE transfer_id = ?", arguments: [transferId])
            }
            try db.execute(
                sql: "DELETE FROM pending_profile_photo_mutations WHERE account_id = ?",
                arguments: [accountId]
            )
            return transferId
        }
    }

    /// Rolls back only the mutation created by a suspended coordinator operation. A newer intent
    /// for the same account must survive even if the older task resumes after reconfiguration.
    func discardProfilePhotoMutation(
        accountId: String,
        clientMutationId: String
    ) throws -> Bool {
        try dbQueue.write { db in
            guard let transferId = try String.fetchOne(
                db,
                sql: """
                SELECT transfer_id FROM pending_profile_photo_mutations
                WHERE account_id = ? AND client_mutation_id = ?
                """,
                arguments: [accountId, clientMutationId]
            ) else {
                let exists = try Bool.fetchOne(
                    db,
                    sql: """
                    SELECT EXISTS(
                      SELECT 1 FROM pending_profile_photo_mutations
                      WHERE account_id = ? AND client_mutation_id = ?
                    )
                    """,
                    arguments: [accountId, clientMutationId]
                ) ?? false
                guard exists else { return false }
                try db.execute(
                    sql: """
                    DELETE FROM pending_profile_photo_mutations
                    WHERE account_id = ? AND client_mutation_id = ?
                    """,
                    arguments: [accountId, clientMutationId]
                )
                return db.changesCount == 1
            }
            try db.execute(
                sql: "DELETE FROM media_transfers WHERE transfer_id = ?",
                arguments: [transferId]
            )
            try db.execute(
                sql: """
                DELETE FROM pending_profile_photo_mutations
                WHERE account_id = ? AND client_mutation_id = ?
                """,
                arguments: [accountId, clientMutationId]
            )
            return db.changesCount == 1
        }
    }

    func upsertMember(_ db: Database, dialogId: String, member: BootstrapDialogMember) throws {
        try db.execute(
            sql: """
            INSERT INTO dialog_members (dialog_id, account_id, role, last_read_msg_id)
            VALUES (?, ?, ?, ?)
            ON CONFLICT(dialog_id, account_id) DO UPDATE SET
              role = excluded.role,
              last_read_msg_id = MAX(dialog_members.last_read_msg_id, excluded.last_read_msg_id)
            """,
            arguments: [dialogId, member.accountId, member.role, member.lastReadMsgId]
        )
        try refreshUnreadSummary(db, dialogId: dialogId, accountId: member.accountId)
    }

    func upsertProfile(_ db: Database, profile: CloudProfile) throws {
        let photoJSON = profile.photo.flatMap { try? String(data: JSONEncoder().encode($0), encoding: .utf8) }
        try db.execute(
            sql: """
            INSERT INTO profiles (
              account_id, first_name, last_name, display_name, bio, birthday, color_index,
              photo_media_json, photo_revision, updated_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(account_id) DO UPDATE SET
              first_name = CASE WHEN excluded.updated_at > profiles.updated_at
                THEN excluded.first_name ELSE profiles.first_name END,
              last_name = CASE WHEN excluded.updated_at > profiles.updated_at
                THEN excluded.last_name ELSE profiles.last_name END,
              display_name = CASE WHEN excluded.updated_at > profiles.updated_at
                THEN excluded.display_name ELSE profiles.display_name END,
              bio = CASE WHEN excluded.updated_at > profiles.updated_at
                THEN excluded.bio ELSE profiles.bio END,
              birthday = CASE WHEN excluded.updated_at > profiles.updated_at
                THEN excluded.birthday ELSE profiles.birthday END,
              color_index = CASE WHEN excluded.updated_at > profiles.updated_at
                THEN excluded.color_index ELSE profiles.color_index END,
              photo_media_json = CASE WHEN excluded.photo_revision > profiles.photo_revision
                THEN excluded.photo_media_json ELSE profiles.photo_media_json END,
              photo_revision = MAX(profiles.photo_revision, excluded.photo_revision),
              updated_at = MAX(profiles.updated_at, excluded.updated_at)
            WHERE excluded.updated_at > profiles.updated_at
               OR excluded.photo_revision > profiles.photo_revision
            """,
            arguments: [
                profile.accountId, profile.firstName, profile.lastName, profile.displayName,
                profile.bio, profile.birthday, profile.colorIndex, photoJSON,
                profile.photoRevision, profile.updatedAt
            ]
        )
    }

    nonisolated private static func profile(from row: Row) throws -> CloudProfile {
        let photo: CloudMedia? = try (row["photo_media_json"] as String?).map {
            try JSONDecoder().decode(CloudMedia.self, from: Data($0.utf8))
        }
        return CloudProfile(
            accountId: row["account_id"], firstName: row["first_name"],
            lastName: row["last_name"], displayName: row["display_name"],
            bio: row["bio"], birthday: row["birthday"], colorIndex: row["color_index"],
            photo: photo, photoRevision: row["photo_revision"], updatedAt: row["updated_at"]
        )
    }

    nonisolated private static func pendingProfilePhotoMutation(from row: Row) -> PendingProfilePhotoMutation {
        PendingProfilePhotoMutation(
            accountId: row["account_id"], clientMutationId: row["client_mutation_id"],
            basePhotoRevision: row["base_photo_revision"], operation: row["operation"],
            transferId: row["transfer_id"], mediaId: row["media_id"], source: row["source"],
            state: row["state"], retryCount: row["retry_count"], nextRetryAt: row["next_retry_at"],
            lastError: row["last_error"], terminal: row["terminal"]
        )
    }
}
