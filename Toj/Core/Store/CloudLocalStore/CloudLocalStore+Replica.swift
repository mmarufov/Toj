import Foundation
import GRDB
import os
import Security

extension CloudLocalStore {
    func loadPts(accountId: String) throws -> Int64 {
        try dbQueue.read { db in
            try Int64.fetchOne(db, sql: "SELECT pts FROM sync_state WHERE account_id = ?", arguments: [accountId]) ?? 0
        }
    }

    /// Reads the complete UI launch state from one WAL snapshot so the main actor can publish it
    /// atomically before any online reconciler starts writing.
    func loadLaunchSnapshot(accountId: String) throws -> LocalLaunchSnapshot {
        try dbQueue.read { db in
            LocalLaunchSnapshot(
                pts: try Int64.fetchOne(
                    db,
                    sql: "SELECT pts FROM sync_state WHERE account_id = ?",
                    arguments: [accountId]
                ) ?? 0,
                dialogs: try Self.fetchDialogs(db, accountId: accountId)
            )
        }
    }

    func savePts(_ pts: Int64, accountId: String) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                INSERT INTO sync_state (account_id, pts, updated_at)
                VALUES (?, ?, datetime('now'))
                ON CONFLICT(account_id) DO UPDATE SET pts = excluded.pts, updated_at = excluded.updated_at
                """,
                arguments: [accountId, pts]
            )
        }
    }

    func isReplicaInitialized(accountId: String) throws -> Bool {
        try dbQueue.read { db in
            try Bool.fetchOne(
                db,
                sql: "SELECT initialized FROM replica_state WHERE account_id = ?",
                arguments: [accountId]
            ) ?? false
        }
    }

    func clearAccount(accountId: String) throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM sync_state WHERE account_id = ?", arguments: [accountId])
            try db.execute(sql: "DELETE FROM replica_state WHERE account_id = ?", arguments: [accountId])
            try db.execute(sql: "DELETE FROM cloud_chat_folder_state WHERE account_id = ?", arguments: [accountId])
            try db.execute(sql: "DELETE FROM cloud_scheduled_deliveries WHERE account_id = ?", arguments: [accountId])
            try db.execute(sql: "DELETE FROM cloud_scheduled_delivery_state WHERE account_id = ?", arguments: [accountId])
            try db.execute(sql: "DELETE FROM pending_chat_folder_mutations WHERE account_id = ?", arguments: [accountId])
            try db.execute(sql: "DELETE FROM pending_scheduled_delivery_creates WHERE account_id = ?", arguments: [accountId])
            try db.execute(sql: "DELETE FROM pending_scheduled_delivery_mutations WHERE account_id = ?", arguments: [accountId])
            try deleteReplicaData(db, includeMediaTransfers: true)
        }
    }

    func beginBootstrap(accountId: String) throws {
        try beginBootstrap(accountId: accountId, token: nil, snapshotPts: nil)
    }

    func beginBootstrap(accountId: String, token: String?, snapshotPts: Int64?) throws {
        try beginBootstrap(accountId: accountId, token: token, snapshotPts: snapshotPts, mode: nil)
    }

    func beginBootstrap(
        accountId: String,
        token: String?,
        snapshotPts: Int64?,
        mode: ReplicaBootstrapMode
    ) throws {
        try beginBootstrap(accountId: accountId, token: token, snapshotPts: snapshotPts, mode: mode as ReplicaBootstrapMode?)
    }

    private func beginBootstrap(
        accountId: String,
        token: String?,
        snapshotPts: Int64?,
        mode requestedMode: ReplicaBootstrapMode?
    ) throws {
        try dbQueue.write { db in
            let savedMode = try String.fetchOne(
                db,
                sql: "SELECT mode FROM bootstrap_state WHERE account_id = ?",
                arguments: [accountId]
            ).flatMap(ReplicaBootstrapMode.init(rawValue:))
            let hasPublishedDialogs = try Bool.fetchOne(
                db,
                sql: "SELECT EXISTS(SELECT 1 FROM dialogs LIMIT 1)"
            ) ?? false
            let mode = requestedMode ?? savedMode ?? (hasPublishedDialogs ? .replacement : .initial)

            try clearBootstrapStaging(db, accountId: accountId)
            try db.execute(
                sql: """
                INSERT INTO bootstrap_baseline_dialogs (account_id, dialog_id)
                SELECT ?, dialog_id FROM dialogs
                """,
                arguments: [accountId]
            )
            try db.execute(
                sql: """
                INSERT INTO bootstrap_state (
                  account_id, token, next_cursor, snapshot_pts, status, mode, updated_at
                ) VALUES (?, ?, NULL, COALESCE(?, 0), 'in_progress', ?, datetime('now'))
                ON CONFLICT(account_id) DO UPDATE SET
                  token = COALESCE(excluded.token, bootstrap_state.token),
                  next_cursor = NULL,
                  snapshot_pts = CASE
                    WHEN ? IS NULL THEN bootstrap_state.snapshot_pts
                    ELSE excluded.snapshot_pts
                  END,
                  status = 'in_progress',
                  mode = excluded.mode,
                  updated_at = excluded.updated_at
                """,
                arguments: [accountId, token, snapshotPts, mode.rawValue, snapshotPts]
            )
        }
    }

    func applyBootstrapPage(_ page: BootstrapDialogsPage) throws {
        try dbQueue.write { db in
            guard let state = try Row.fetchOne(
                db,
                sql: "SELECT account_id, mode FROM bootstrap_state WHERE status = 'in_progress'"
            ) else {
                throw CloudLocalStoreBootstrapError.notInProgress
            }
            let accountId: String = state["account_id"]
            let mode = ReplicaBootstrapMode(rawValue: state["mode"]) ?? .initial

            try stageBootstrapPage(db, accountId: accountId, page: page)
            if mode == .initial {
                // A genuinely new device has no prior UI to protect. Publishing each committed page
                // lets it render after page one while the durable staging set still tracks which
                // rows belong to the eventual complete snapshot.
                for profile in page.dialogs.flatMap({ $0.profiles ?? [] }) {
                    try upsertProfile(db, profile: profile)
                }
                for dialog in page.dialogs {
                    try mergeBootstrapDialog(
                        db,
                        accountId: accountId,
                        dialog: dialog,
                        pruneSnapshotWindow: false
                    )
                }
            }
            try db.execute(
                sql: """
                UPDATE bootstrap_state
                SET token = ?, next_cursor = ?, snapshot_pts = ?, updated_at = datetime('now')
                WHERE account_id = ? AND status = 'in_progress'
                """,
                arguments: [page.token, page.nextCursor, page.state.pts, accountId]
            )
        }
    }

    func applyHistoryPage(_ page: HistoryPageResponse) throws {
        try dbQueue.write { db in
            guard try !Self.isDialogRevoked(db, dialogId: page.dialogId) else { return }
            for profile in page.profiles ?? [] {
                try upsertProfile(db, profile: profile)
            }
            let durableType = try String.fetchOne(
                db,
                sql: "SELECT type FROM dialogs WHERE dialog_id = ?",
                arguments: [page.dialogId]
            ) ?? "direct"
            for message in page.messages {
                try upsertDialog(
                    db,
                    dialogId: message.dialogId,
                    type: durableType,
                    title: nil,
                    lastMsgId: message.msgId,
                    updatedAt: message.serverTs
                )
                try upsertMessage(db, message: message, localState: "sent", refreshSummaries: false)
            }
            try refreshDialogSummary(db, dialogId: page.dialogId)
            let existingCeiling = try Int64.fetchOne(
                db,
                sql: "SELECT ceiling_msg_id FROM dialog_history_state WHERE dialog_id = ?",
                arguments: [page.dialogId]
            ) ?? 0
            let pageCeiling = page.messages.map(\.msgId).max() ?? 0
            try upsertHistoryState(
                db,
                state: DialogHistoryState(
                    dialogId: page.dialogId,
                    ceilingMsgId: max(existingCeiling, pageCeiling),
                    nextBeforeMsgId: page.nextBeforeMsgId,
                    historyComplete: !page.hasMore,
                    retryCount: 0,
                    nextRetryAt: nil
                )
            )
        }
    }

    /// Stores a window fetched around a semantic anchor without moving the sequential backfill
    /// cursor. This lets a sparse bootstrap locate first-unread immediately while normal hydration
    /// continues from its previously persisted position.
    func applyTargetedHistoryPage(_ page: HistoryPageResponse) throws {
        try dbQueue.write { db in
            guard try !Self.isDialogRevoked(db, dialogId: page.dialogId) else { return }
            for profile in page.profiles ?? [] {
                try upsertProfile(db, profile: profile)
            }
            let durableType = try String.fetchOne(
                db,
                sql: "SELECT type FROM dialogs WHERE dialog_id = ?",
                arguments: [page.dialogId]
            ) ?? "direct"
            for message in page.messages {
                try upsertDialog(
                    db,
                    dialogId: message.dialogId,
                    type: durableType,
                    title: nil,
                    lastMsgId: message.msgId,
                    updatedAt: message.serverTs
                )
                try upsertMessage(db, message: message, localState: "sent", refreshSummaries: false)
            }
            try refreshDialogSummary(db, dialogId: page.dialogId)
        }
    }

    func finishBootstrap(accountId: String, pts: Int64) throws {
        try dbQueue.write { db in
            guard try Bool.fetchOne(
                db,
                sql: "SELECT EXISTS(SELECT 1 FROM bootstrap_state WHERE account_id = ? AND status = 'in_progress')",
                arguments: [accountId]
            ) == true else {
                throw CloudLocalStoreBootstrapError.notInProgress
            }

            let snapshot = try loadStagedBootstrapSnapshot(db, accountId: accountId)
            for profile in snapshot.profiles {
                try upsertProfile(db, profile: profile)
            }
            for dialog in snapshot.dialogs {
                if let revoked = try Self.revokedDialog(db, dialogId: dialog.dialogId) {
                    let isAuthoritativeGroupGrant = dialog.type == "group"
                        && revoked.dialogType == "group"
                        && dialog.selfRole != nil
                        && pts > revoked.pts
                    guard isAuthoritativeGroupGrant else { continue }
                    // Replacement bootstrap remains invisible and fully purge-fenced until this
                    // transaction publishes the complete authoritative snapshot.
                    try restoreGroupAccess(db, dialogId: dialog.dialogId, grantedPts: pts)
                }
                try mergeBootstrapDialog(
                    db,
                    accountId: accountId,
                    dialog: dialog,
                    pruneSnapshotWindow: true
                )
            }
            try pruneDialogsMissingFromBootstrap(
                db,
                accountId: accountId,
                stagedDialogIds: Set(snapshot.dialogs.map(\.dialogId))
            )

            try db.execute(
                sql: """
                INSERT INTO sync_state (account_id, pts, updated_at)
                VALUES (?, ?, datetime('now'))
                ON CONFLICT(account_id) DO UPDATE SET pts = excluded.pts, updated_at = excluded.updated_at
                """,
                arguments: [accountId, pts]
            )
            try db.execute(
                sql: """
                INSERT INTO replica_state (account_id, initialized, updated_at)
                VALUES (?, 1, datetime('now'))
                ON CONFLICT(account_id) DO UPDATE SET
                  initialized = 1,
                  updated_at = excluded.updated_at
                """,
                arguments: [accountId]
            )
            // A response only proves that the server accepted the mutation. Keep its optimistic
            // overlay until the exact snapshot cursor is known to contain the canonical value.
            try db.execute(
                sql: """
                DELETE FROM pending_dialog_preference_mutations
                WHERE account_id = ?
                  AND acknowledged_pts IS NOT NULL
                  AND acknowledged_pts <= ?
                """,
                arguments: [accountId, pts]
            )
            try clearBootstrapStaging(db, accountId: accountId)
            try db.execute(sql: "DELETE FROM bootstrap_state WHERE account_id = ?", arguments: [accountId])
        }
    }

    func applyDifference(_ difference: DifferenceResponse, accountId: String) throws {
        try dbQueue.write { db in
            if difference.kind == "difference_too_long" {
                // Keep the last readable replica and every durable outbox row in place while a
                // replacement snapshot is fetched. The bootstrap merge is idempotent, so an app
                // termination never leaves the user with an empty chat list.
                try db.execute(
                    sql: """
                    INSERT INTO bootstrap_state (
                      account_id, token, next_cursor, snapshot_pts, status, mode, updated_at
                    ) VALUES (
                      ?, NULL, NULL, ?, 'needs_rebuild',
                      CASE WHEN EXISTS(SELECT 1 FROM dialogs LIMIT 1)
                        THEN 'replacement' ELSE 'initial' END,
                      datetime('now')
                    )
                    ON CONFLICT(account_id) DO UPDATE SET
                      status = 'needs_rebuild',
                      snapshot_pts = excluded.snapshot_pts,
                      mode = excluded.mode,
                      updated_at = excluded.updated_at
                    """,
                    arguments: [accountId, difference.state.pts]
                )
                return
            } else {
                var messageDialogsToRefresh: Set<String> = []
                let updates = difference.updates ?? []
                // Saved access is owner-only and non-regrantable. Pre-install any Saved revoke in
                // this page so a legacy receipt that precedes it cannot persist archive/profile
                // data. Group access remains strictly sequential to preserve remove then re-add.
                for update in updates where update.type == "dialog.access_revoked"
                    && update.dialogType == "saved" {
                    guard let dialogId = update.dialogId else { continue }
                    try db.execute(
                        sql: """
                        INSERT INTO revoked_dialogs (
                          dialog_id, dialog_type, revoked_pts, created_at
                        ) VALUES (?, 'saved', ?, datetime('now'))
                        ON CONFLICT(dialog_id) DO UPDATE SET
                          dialog_type = 'saved',
                          revoked_pts = MAX(revoked_dialogs.revoked_pts, excluded.revoked_pts)
                        """,
                        arguments: [dialogId, update.pts]
                    )
                }
                let pageDialogIds = Set(updates.compactMap(\.dialogId))
                var simulatedRevocations: [
                    String: (dialogType: String?, pts: Int64)
                ] = [:]
                for dialogId in pageDialogIds {
                    simulatedRevocations[dialogId] = try Self.revokedDialog(
                        db, dialogId: dialogId
                    )
                }
                var blockedUpdates: [Bool] = []
                blockedUpdates.reserveCapacity(updates.count)
                for update in updates {
                    guard let dialogId = update.dialogId else {
                        blockedUpdates.append(false)
                        continue
                    }
                    if update.type == "dialog.access_revoked" {
                        let previous = simulatedRevocations[dialogId]
                        simulatedRevocations[dialogId] = (
                            update.dialogType ?? previous?.dialogType,
                            max(previous?.pts ?? 0, update.pts)
                        )
                        blockedUpdates.append(true)
                        continue
                    }
                    if update.type == "dialog.created",
                       let revoked = simulatedRevocations[dialogId],
                       revoked.dialogType == "group",
                       update.dialogType == "group",
                       update.pts > revoked.pts {
                        simulatedRevocations[dialogId] = nil
                        blockedUpdates.append(false)
                        continue
                    }
                    blockedUpdates.append(simulatedRevocations[dialogId] != nil)
                }
                var blockedProfileIds: Set<String> = []
                var visibleProfileIds: Set<String> = []
                var hasVisibleNonRevocation = false
                for (index, update) in updates.enumerated()
                    where update.type != "dialog.access_revoked" {
                    let isBlocked = blockedUpdates[index]
                    if isBlocked {
                        blockedProfileIds.formUnion(Self.referencedAccountIds(update))
                    } else {
                        hasVisibleNonRevocation = true
                        visibleProfileIds.formUnion(Self.referencedAccountIds(update))
                    }
                }
                // A legacy page can carry message/profile receipts for a dialog that is reconciled
                // to access_revoked later in that same page. Suppress the entire profile payload if
                // no authorized update remains; in a mixed page, suppress identities referenced only
                // by blocked updates while retaining ordinary lifecycle actor profiles.
                let visibleProfiles = hasVisibleNonRevocation
                    ? (difference.profiles ?? []).filter {
                        !blockedProfileIds.contains($0.accountId)
                            || visibleProfileIds.contains($0.accountId)
                    }
                    : []
                for profile in visibleProfiles {
                    try upsertProfile(db, profile: profile)
                }
                for update in updates {
                    if let dialogId = update.dialogId,
                       update.type != "dialog.access_revoked",
                       let revoked = try Self.revokedDialog(db, dialogId: dialogId) {
                        let isNewerGroupGrant = update.type == "dialog.created"
                            && revoked.dialogType == "group"
                            && update.dialogType == "group"
                            && update.pts > revoked.pts
                        guard isNewerGroupGrant else {
                            // Delayed history/member/mutation receipts cannot resurrect a revoked
                            // dialog. Saved tombstones never satisfy the group-only grant predicate.
                            continue
                        }
                        try restoreGroupAccess(
                            db, dialogId: dialogId, grantedPts: update.pts
                        )
                    }
                    if update.type == "dialog.preferences_updated",
                       let preferences = update.preferences {
                        try upsertDialogPreferences(
                            db,
                            preferences: preferences,
                            accountId: accountId,
                            clientMutationId: update.clientMutationId
                        )
                    }
                    switch update.type {
                    case "message.new", "message.edited", "message.deleted", "reaction.updated",
                         "message.preview_updated":
                        guard let message = update.message else { continue }
                        let previousMessage = try Row.fetchOne(
                            db,
                            sql: """
                            SELECT msg_id, sender_account_id, state
                            FROM messages WHERE dialog_id = ? AND msg_id = ?
                            """,
                            arguments: [message.dialogId, message.msgId]
                        )
                        let currentRead = try Int64.fetchOne(
                            db,
                            sql: """
                            SELECT last_read_msg_id FROM dialog_members
                            WHERE dialog_id = ? AND account_id = ?
                            """,
                            arguments: [message.dialogId, accountId]
                        ) ?? 0
                        let wasUnread: Bool = {
                            guard let previousMessage else { return false }
                            let msgId: Int64? = previousMessage["msg_id"]
                            let sender: String = previousMessage["sender_account_id"]
                            let state: String = previousMessage["state"]
                            return state == "visible" && sender != accountId && (msgId ?? 0) > currentRead
                        }()
                        let storedType = try String.fetchOne(
                            db,
                            sql: "SELECT type FROM dialogs WHERE dialog_id = ?",
                            arguments: [message.dialogId]
                        )
                        let durableType = update.dialogType ?? storedType ?? "direct"
                        try upsertDialog(
                            db,
                            dialogId: message.dialogId,
                            type: durableType,
                            title: update.dialogTitle,
                            lastMsgId: message.msgId,
                            updatedAt: message.serverTs
                        )
                        // Incoming message events may carry the recipient's atomic auto-unarchive
                        // snapshot. Apply it in the same transaction as the message and pts cursor.
                        if let preferences = update.preferences {
                            try upsertDialogPreferences(
                                db,
                                preferences: preferences,
                                accountId: accountId,
                                clientMutationId: update.clientMutationId
                            )
                        }
                        try upsertMessage(
                            db,
                            message: message,
                            localState: "sent",
                            refreshSummaries: false
                        )
                        // A push/difference can beat the HTTP response or arrive after a process
                        // relaunch. Canonical client_msg_id acknowledgement owns outbox cleanup.
                        try db.execute(
                            sql: "DELETE FROM pending_outbox WHERE client_msg_id = ?",
                            arguments: [message.clientMsgId]
                        )
                        if let scheduledDeliveryId = update.scheduledDeliveryId {
                            try db.execute(
                                sql: "DELETE FROM cloud_scheduled_deliveries WHERE schedule_id = ?",
                                arguments: [scheduledDeliveryId]
                            )
                        }
                        let isUnread = message.state == "visible"
                            && message.senderAccountId != accountId
                            && message.msgId > currentRead
                        if wasUnread != isUnread {
                            try adjustUnreadSummary(
                                db,
                                dialogId: message.dialogId,
                                accountId: accountId,
                                delta: isUnread ? 1 : -1
                            )
                        }
                        messageDialogsToRefresh.insert(message.dialogId)
                        if let peerAccountId = update.peerAccountId {
                            try upsertMember(
                                db, dialogId: message.dialogId,
                                member: BootstrapDialogMember(accountId: accountId, role: "member", lastReadMsgId: 0)
                            )
                            try upsertMember(
                                db, dialogId: message.dialogId,
                                member: BootstrapDialogMember(accountId: peerAccountId, role: "member", lastReadMsgId: 0)
                            )
                        }
                    case "dialog.created":
                        guard let dialogId = update.dialogId else { continue }
                        let durableType = update.dialogType
                            ?? (update.group == nil ? "direct" : "group")
                        if durableType == "saved" {
                            try ensureSavedDialog(
                                db,
                                dialogId: dialogId,
                                accountId: accountId,
                                updatedAt: nil
                            )
                            continue
                        }
                        try upsertDialog(
                            db,
                            dialogId: dialogId,
                            type: durableType,
                            title: update.group?.title ?? update.dialogTitle,
                            lastMsgId: 0,
                            updatedAt: nil
                        )
                        if let group = update.group {
                            try applyGroupMetadata(db, group: group)
                        }
                        if let preferences = update.preferences {
                            try upsertDialogPreferences(
                                db,
                                preferences: preferences,
                                accountId: accountId,
                                clientMutationId: update.clientMutationId
                            )
                        }
                        if let peerAccountId = update.peerAccountId {
                            try upsertMember(
                                db, dialogId: dialogId,
                                member: BootstrapDialogMember(accountId: accountId, role: "member", lastReadMsgId: 0)
                            )
                            try upsertMember(
                                db, dialogId: dialogId,
                                member: BootstrapDialogMember(accountId: peerAccountId, role: "member", lastReadMsgId: 0)
                            )
                        }
                    case "member.added", "member.removed", "member.role_changed", "member.left",
                         "dialog.profile_updated", "dialog.closed":
                        if let group = update.group {
                            try applyGroupMetadata(db, group: group)
                        }
                        if let member = update.member, let dialogId = update.dialogId {
                            try upsertGroupMember(
                                db,
                                dialogId: dialogId,
                                member: member,
                                revision: update.group?.revision ?? 0
                            )
                        }
                    case "dialog.access_revoked":
                        guard let dialogId = update.dialogId else { continue }
                        let reason = update.dialogType == "saved"
                            ? "This Saved Messages archive is no longer authorized for this account."
                            : "You no longer have access to this group."
                        try revokeGroupAccess(
                            db,
                            dialogId: dialogId,
                            accessState: "removed",
                            reason: reason,
                            revokedPts: update.pts,
                            explicitDialogType: update.dialogType
                        )
                    case "read.updated":
                        guard
                            let dialogId = update.dialogId,
                            let accountId = update.readerAccountId,
                            let maxReadMsgId = update.maxReadMsgId
                        else { continue }
                        try markRead(
                            db,
                            dialogId: dialogId,
                            accountId: accountId,
                            maxReadMsgId: maxReadMsgId,
                            exactUnreadCount: update.unreadCount
                        )
                    case "chat_folders.updated":
                        guard let snapshot = update.chatFolders else { continue }
                        if let clientMutationId = update.clientMutationId {
                            try db.execute(
                                sql: """
                                DELETE FROM pending_chat_folder_mutations
                                WHERE account_id = ? AND client_mutation_id = ?
                                """,
                                arguments: [accountId, clientMutationId]
                            )
                        }
                        let snapshotJSON = String(
                            data: try JSONEncoder().encode(snapshot), encoding: .utf8
                        )!
                        let current = try Int64.fetchOne(
                            db,
                            sql: "SELECT collection_revision FROM cloud_chat_folder_state WHERE account_id = ?",
                            arguments: [accountId]
                        ) ?? -1
                        if snapshot.collectionRevision >= current {
                            try db.execute(
                                sql: """
                                INSERT INTO cloud_chat_folder_state(
                                  account_id, collection_revision, snapshot_json, updated_at
                                ) VALUES (?, ?, ?, datetime('now'))
                                ON CONFLICT(account_id) DO UPDATE SET
                                  collection_revision = excluded.collection_revision,
                                  snapshot_json = excluded.snapshot_json,
                                  updated_at = excluded.updated_at
                                """,
                                arguments: [accountId, snapshot.collectionRevision, snapshotJSON]
                            )
                        }
                    case "scheduled.created", "scheduled.updated", "scheduled.canceled",
                         "scheduled.failed":
                        guard let delivery = update.scheduledDelivery else { continue }
                        try db.execute(
                            sql: "DELETE FROM pending_scheduled_delivery_creates WHERE schedule_id = ? AND account_id = ?",
                            arguments: [delivery.scheduleId, accountId]
                        )
                        if let clientMutationId = update.clientMutationId {
                            let matchesLocalCancellation = try Bool.fetchOne(
                                db,
                                sql: """
                                SELECT EXISTS(
                                  SELECT 1 FROM pending_scheduled_delivery_mutations
                                  WHERE account_id = ? AND client_mutation_id = ?
                                    AND operation = 'cancel'
                                )
                                """,
                                arguments: [accountId, clientMutationId]
                            ) ?? false
                            let acknowledgesLocalCancellation = update.type == "scheduled.canceled"
                                && matchesLocalCancellation
                            if acknowledgesLocalCancellation {
                                // Cancellation wins over every earlier uncertain reschedule for the
                                // same message, including when the HTTP acknowledgement was lost and
                                // this sync event is the first authoritative response we observe.
                                try db.execute(
                                    sql: """
                                    DELETE FROM pending_scheduled_delivery_mutations
                                    WHERE account_id = ? AND schedule_id = ?
                                    """,
                                    arguments: [accountId, delivery.scheduleId]
                                )
                            } else {
                                try db.execute(
                                    sql: """
                                    DELETE FROM pending_scheduled_delivery_mutations
                                    WHERE account_id = ? AND client_mutation_id = ?
                                    """,
                                    arguments: [accountId, clientMutationId]
                                )
                            }
                        }
                        let payload = String(
                            data: try JSONEncoder().encode(delivery), encoding: .utf8
                        )!
                        try db.execute(
                            sql: """
                            INSERT INTO cloud_scheduled_deliveries(
                              schedule_id, account_id, dialog_id, state, deliver_at,
                              revision, payload_json, updated_at
                            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                            ON CONFLICT(schedule_id) DO UPDATE SET
                              state = excluded.state,
                              deliver_at = excluded.deliver_at,
                              revision = excluded.revision,
                              payload_json = excluded.payload_json,
                              updated_at = excluded.updated_at
                            WHERE excluded.revision >= cloud_scheduled_deliveries.revision
                            """,
                            arguments: [
                                delivery.scheduleId, accountId, delivery.dialogId, delivery.state,
                                delivery.deliverAt, delivery.revision, payload, delivery.updatedAt
                            ]
                        )
                        if let collectionRevision = update.collectionRevision {
                            try db.execute(
                                sql: """
                                INSERT INTO cloud_scheduled_delivery_state(
                                  account_id, collection_revision, updated_at
                                ) VALUES (?, ?, datetime('now'))
                                ON CONFLICT(account_id) DO UPDATE SET
                                  collection_revision = MAX(
                                    collection_revision, excluded.collection_revision
                                  ),
                                  updated_at = excluded.updated_at
                                """,
                                arguments: [accountId, collectionRevision]
                            )
                        }
                    case "draft.updated":
                        guard let draft = update.draft else { continue }
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
                    case "profile.updated":
                        guard
                            let subjectAccountId = update.subjectAccountId,
                            let firstName = update.firstName,
                            let lastName = update.lastName,
                            let displayName = update.displayName,
                            let bio = update.bio,
                            let colorIndex = update.colorIndex,
                            let updatedAt = update.profileUpdatedAt
                        else { continue }
                        try upsertProfile(
                            db,
                            profile: CloudProfile(
                                accountId: subjectAccountId,
                                username: update.username,
                                firstName: firstName,
                                lastName: lastName,
                                displayName: displayName,
                                bio: bio,
                                birthday: update.birthday,
                                colorIndex: colorIndex,
                                photo: update.photo,
                                photoRevision: update.photoRevision ?? 0,
                                updatedAt: updatedAt
                            )
                        )
                        if subjectAccountId != accountId, let sharedDialogIds = update.sharedDialogIds {
                            for dialogId in sharedDialogIds {
                                try db.execute(
                                    sql: """
                                    INSERT INTO dialogs (dialog_id, type, title, last_msg_id, updated_at)
                                    VALUES (?, 'direct', ?, 0, ?)
                                    ON CONFLICT(dialog_id) DO UPDATE SET title = excluded.title
                                    """,
                                    arguments: [dialogId, displayName, updatedAt]
                                )
                                try ensureDialogSummary(db, dialogId: dialogId)
                                try upsertMember(
                                    db, dialogId: dialogId,
                                    member: BootstrapDialogMember(accountId: accountId, role: "member", lastReadMsgId: 0)
                                )
                                try upsertMember(
                                    db, dialogId: dialogId,
                                    member: BootstrapDialogMember(accountId: subjectAccountId, role: "member", lastReadMsgId: 0)
                                )
                            }
                        } else if subjectAccountId != accountId {
                            try db.execute(
                                sql: """
                                UPDATE dialogs SET title = ?
                                WHERE type = 'direct' AND dialog_id IN (
                                  SELECT dialog_id FROM dialog_members WHERE account_id = ?
                                )
                                """,
                                arguments: [displayName, subjectAccountId]
                            )
                        }
                    default:
                        continue
                    }
                }
                for dialogId in messageDialogsToRefresh {
                    try refreshDialogSummary(db, dialogId: dialogId)
                    try refreshAllUnreadSummaries(db, dialogId: dialogId)
                }
            }
            try db.execute(
                sql: """
                INSERT INTO sync_state (account_id, pts, updated_at)
                VALUES (?, ?, datetime('now'))
                ON CONFLICT(account_id) DO UPDATE SET pts = excluded.pts, updated_at = excluded.updated_at
                """,
                arguments: [accountId, difference.state.pts]
            )
        }
    }

    private func clearBootstrapStaging(_ db: Database, accountId: String) throws {
        try db.execute(
            sql: "DELETE FROM bootstrap_baseline_dialogs WHERE account_id = ?",
            arguments: [accountId]
        )
        try db.execute(
            sql: "DELETE FROM bootstrap_staged_messages WHERE account_id = ?",
            arguments: [accountId]
        )
        try db.execute(
            sql: "DELETE FROM bootstrap_staged_members WHERE account_id = ?",
            arguments: [accountId]
        )
        try db.execute(
            sql: "DELETE FROM bootstrap_staged_profiles WHERE account_id = ?",
            arguments: [accountId]
        )
        try db.execute(
            sql: "DELETE FROM bootstrap_staged_dialogs WHERE account_id = ?",
            arguments: [accountId]
        )
    }

    private func stageBootstrapPage(
        _ db: Database,
        accountId: String,
        page: BootstrapDialogsPage
    ) throws {
        let encoder = JSONEncoder()
        for dialog in page.dialogs {
            if let revoked = try Self.revokedDialog(db, dialogId: dialog.dialogId) {
                let isAuthoritativeGroupGrant = dialog.type == "group"
                    && revoked.dialogType == "group"
                    && dialog.selfRole != nil
                    && page.state.pts > revoked.pts
                guard isAuthoritativeGroupGrant else { continue }
                // Stage the grant, but preserve the tombstone and purge job. finishBootstrap owns
                // the only atomic transition from the old published replica to this snapshot.
            }
            let photoJSON = dialog.photo
                .flatMap { try? encoder.encode($0) }
                .flatMap { String(data: $0, encoding: .utf8) }
            let draftJSON = dialog.draft
                .flatMap { try? encoder.encode($0) }
                .flatMap { String(data: $0, encoding: .utf8) }
            try db.execute(
                sql: """
                INSERT INTO bootstrap_staged_dialogs (
                  account_id, dialog_id, type, title, last_msg_id, updated_at, unread_count,
                  revision, member_count, self_role, notification_mode, photo_media_json,
                  draft_json,
                  preference_is_pinned, preference_pinned_at, preference_is_muted,
                  preference_is_archived, preference_updated_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(account_id, dialog_id) DO UPDATE SET
                  type = excluded.type,
                  title = excluded.title,
                  last_msg_id = excluded.last_msg_id,
                  updated_at = excluded.updated_at,
                  unread_count = excluded.unread_count,
                  revision = excluded.revision,
                  member_count = excluded.member_count,
                  self_role = excluded.self_role,
                  notification_mode = excluded.notification_mode,
                  photo_media_json = excluded.photo_media_json,
                  draft_json = excluded.draft_json,
                  preference_is_pinned = excluded.preference_is_pinned,
                  preference_pinned_at = excluded.preference_pinned_at,
                  preference_is_muted = excluded.preference_is_muted,
                  preference_is_archived = excluded.preference_is_archived,
                  preference_updated_at = excluded.preference_updated_at
                """,
                arguments: [
                    accountId, dialog.dialogId, dialog.type, dialog.title,
                    dialog.lastMsgId, dialog.updatedAt, dialog.unreadCount,
                    dialog.revision, dialog.memberCount, dialog.selfRole,
                    dialog.notificationMode, photoJSON, draftJSON,
                    dialog.preferences?.pinned ?? false,
                    dialog.preferences?.pinnedAt,
                    dialog.preferences?.muted ?? (dialog.notificationMode == "muted"),
                    dialog.preferences?.archived ?? false,
                    dialog.preferences?.updatedAt ?? dialog.updatedAt,
                ]
            )
            try db.execute(
                sql: "DELETE FROM bootstrap_staged_members WHERE account_id = ? AND dialog_id = ?",
                arguments: [accountId, dialog.dialogId]
            )
            try db.execute(
                sql: "DELETE FROM bootstrap_staged_messages WHERE account_id = ? AND dialog_id = ?",
                arguments: [accountId, dialog.dialogId]
            )
            for member in dialog.members {
                try db.execute(
                    sql: """
                    INSERT INTO bootstrap_staged_members (
                      account_id, dialog_id, member_account_id, role, last_read_msg_id,
                      joined_at, is_active
                    ) VALUES (?, ?, ?, ?, ?, ?, ?)
                    """,
                    arguments: [
                        accountId, dialog.dialogId, member.accountId,
                        member.role, member.lastReadMsgId, member.joinedAt, member.isActive
                    ]
                )
            }
            for profile in dialog.profiles ?? [] {
                let data = try encoder.encode(profile)
                guard let json = String(data: data, encoding: .utf8) else {
                    throw CloudLocalStoreBootstrapError.invalidStagedMessage
                }
                try db.execute(
                    sql: """
                    INSERT INTO bootstrap_staged_profiles (
                      account_id, profile_account_id, profile_json
                    ) VALUES (?, ?, ?)
                    ON CONFLICT(account_id, profile_account_id) DO UPDATE SET
                      profile_json = excluded.profile_json
                    """,
                    arguments: [accountId, profile.accountId, json]
                )
            }
            for message in dialog.messages {
                guard message.dialogId == dialog.dialogId else {
                    throw CloudLocalStoreBootstrapError.invalidStagedMessage
                }
                let data = try encoder.encode(message)
                guard let json = String(data: data, encoding: .utf8) else {
                    throw CloudLocalStoreBootstrapError.invalidStagedMessage
                }
                try db.execute(
                    sql: """
                    DELETE FROM bootstrap_staged_messages
                    WHERE account_id = ? AND client_msg_id = ?
                      AND (dialog_id != ? OR msg_id != ?)
                    """,
                    arguments: [accountId, message.clientMsgId, message.dialogId, message.msgId]
                )
                try db.execute(
                    sql: """
                    INSERT INTO bootstrap_staged_messages (
                      account_id, dialog_id, msg_id, client_msg_id, message_json
                    ) VALUES (?, ?, ?, ?, ?)
                    ON CONFLICT(account_id, dialog_id, msg_id) DO UPDATE SET
                      client_msg_id = excluded.client_msg_id,
                      message_json = excluded.message_json
                    """,
                    arguments: [accountId, message.dialogId, message.msgId, message.clientMsgId, json]
                )
            }
        }
    }

    private func loadStagedBootstrapSnapshot(
        _ db: Database,
        accountId: String
    ) throws -> StagedBootstrapSnapshot {
        let decoder = JSONDecoder()
        let memberRows = try Row.fetchAll(
            db,
            sql: """
            SELECT dialog_id, member_account_id, role, last_read_msg_id, joined_at, is_active
            FROM bootstrap_staged_members
            WHERE account_id = ?
            ORDER BY dialog_id, member_account_id
            """,
            arguments: [accountId]
        )
        var membersByDialog: [String: [BootstrapDialogMember]] = [:]
        for row in memberRows {
            let dialogId: String = row["dialog_id"]
            membersByDialog[dialogId, default: []].append(
                BootstrapDialogMember(
                    accountId: row["member_account_id"],
                    role: row["role"],
                    lastReadMsgId: row["last_read_msg_id"],
                    joinedAt: row["joined_at"],
                    isActive: row["is_active"]
                )
            )
        }

        let messageRows = try Row.fetchAll(
            db,
            sql: """
            SELECT dialog_id, message_json
            FROM bootstrap_staged_messages
            WHERE account_id = ?
            ORDER BY dialog_id, msg_id
            """,
            arguments: [accountId]
        )
        var messagesByDialog: [String: [CloudMessage]] = [:]
        for row in messageRows {
            let dialogId: String = row["dialog_id"]
            let json: String = row["message_json"]
            guard
                let data = json.data(using: .utf8),
                let message = try? decoder.decode(CloudMessage.self, from: data)
            else {
                throw CloudLocalStoreBootstrapError.invalidStagedMessage
            }
            messagesByDialog[dialogId, default: []].append(message)
        }

        let profileRows = try Row.fetchAll(
            db,
            sql: "SELECT profile_json FROM bootstrap_staged_profiles WHERE account_id = ?",
            arguments: [accountId]
        )
        let profiles = try profileRows.map { row -> CloudProfile in
            let json: String = row["profile_json"]
            guard
                let data = json.data(using: .utf8),
                let profile = try? decoder.decode(CloudProfile.self, from: data)
            else {
                throw CloudLocalStoreBootstrapError.invalidStagedMessage
            }
            return profile
        }

        let dialogRows = try Row.fetchAll(
            db,
            sql: """
            SELECT dialog_id, type, title, last_msg_id, updated_at, unread_count,
                   revision, member_count, self_role, notification_mode, photo_media_json,
                   draft_json,
                   preference_is_pinned, preference_pinned_at, preference_is_muted,
                   preference_is_archived, preference_updated_at
            FROM bootstrap_staged_dialogs
            WHERE account_id = ?
            ORDER BY updated_at DESC, dialog_id DESC
            """,
            arguments: [accountId]
        )
        let dialogs = dialogRows.map { row in
            let dialogId: String = row["dialog_id"]
            let photo = (row["photo_media_json"] as String?)
                .flatMap { $0.data(using: .utf8) }
                .flatMap { try? decoder.decode(CloudMedia.self, from: $0) }
            let draft = (row["draft_json"] as String?)
                .flatMap { $0.data(using: .utf8) }
                .flatMap { try? decoder.decode(CloudDraft.self, from: $0) }
            return BootstrapDialog(
                dialogId: dialogId,
                type: row["type"],
                title: row["title"],
                lastMsgId: row["last_msg_id"],
                updatedAt: row["updated_at"],
                unreadCount: row["unread_count"],
                revision: row["revision"],
                memberCount: row["member_count"],
                selfRole: row["self_role"],
                notificationMode: row["notification_mode"],
                preferences: CloudDialogPreferences(
                    dialogId: dialogId,
                    pinned: (row["preference_is_pinned"] as Int? ?? 0) != 0,
                    pinnedAt: row["preference_pinned_at"],
                    muted: (row["preference_is_muted"] as Int? ?? 0) != 0,
                    archived: (row["preference_is_archived"] as Int? ?? 0) != 0,
                    updatedAt: row["preference_updated_at"] ?? row["updated_at"]
                ),
                photo: photo,
                draft: draft,
                members: membersByDialog[dialogId] ?? [],
                messages: messagesByDialog[dialogId] ?? []
            )
        }
        return StagedBootstrapSnapshot(dialogs: dialogs, profiles: profiles)
    }

    private func mergeBootstrapDialog(
        _ db: Database,
        accountId: String,
        dialog: BootstrapDialog,
        pruneSnapshotWindow: Bool
    ) throws {
        guard try !Self.isDialogRevoked(db, dialogId: dialog.dialogId) else { return }
        let existingReadRows = try Row.fetchAll(
            db,
            sql: "SELECT account_id, last_read_msg_id FROM dialog_members WHERE dialog_id = ?",
            arguments: [dialog.dialogId]
        )
        let existingReads = Dictionary(uniqueKeysWithValues: existingReadRows.map { row in
            (row["account_id"] as String, row["last_read_msg_id"] as Int64)
        })

        try db.execute(
            sql: """
            INSERT INTO dialogs (
              dialog_id, type, title, last_msg_id, updated_at, revision, photo_media_json,
              member_count, self_role, notification_mode, access_state
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, COALESCE(?, 'all'), 'active')
            ON CONFLICT(dialog_id) DO UPDATE SET
              type = excluded.type,
              title = excluded.title,
              revision = CASE
                WHEN excluded.revision >= dialogs.revision THEN excluded.revision
                ELSE dialogs.revision
              END,
              photo_media_json = CASE
                WHEN excluded.revision >= dialogs.revision THEN excluded.photo_media_json
                ELSE dialogs.photo_media_json
              END,
              member_count = CASE
                WHEN excluded.revision >= dialogs.revision THEN excluded.member_count
                ELSE dialogs.member_count
              END,
              self_role = COALESCE(excluded.self_role, dialogs.self_role),
              notification_mode = COALESCE(excluded.notification_mode, dialogs.notification_mode),
              access_state = 'active',
              last_msg_id = MAX(
                excluded.last_msg_id,
                COALESCE((SELECT MAX(msg_id) FROM messages WHERE dialog_id = ?), 0)
              ),
              updated_at = MAX(dialogs.updated_at, excluded.updated_at)
            """,
            arguments: [
                dialog.dialogId, dialog.type, dialog.title,
                dialog.lastMsgId, dialog.updatedAt, dialog.revision ?? 0,
                dialog.photo.flatMap { try? JSONEncoder().encode($0) }
                    .flatMap { String(data: $0, encoding: .utf8) },
                dialog.memberCount ?? dialog.members.count,
                dialog.selfRole,
                dialog.notificationMode,
                dialog.dialogId,
            ]
        )
        try ensureDialogSummary(db, dialogId: dialog.dialogId)
        try upsertDialogPreferences(
            db,
            preferences: dialog.preferences ?? CloudDialogPreferences(
                dialogId: dialog.dialogId,
                pinned: false,
                pinnedAt: nil,
                muted: dialog.notificationMode == "muted",
                archived: false,
                updatedAt: dialog.updatedAt
            ),
            accountId: accountId,
            clientMutationId: nil
        )

        if let draft = dialog.draft {
            let pending = try String.fetchOne(
                db,
                sql: """
                SELECT operation_id FROM pending_draft_mutations
                WHERE account_id = ? AND dialog_id = ?
                """,
                arguments: [accountId, dialog.dialogId]
            )
            try applyCloudDraft(
                db,
                draft: draft,
                accountId: accountId,
                preserveLocalOverlay: pending != nil
            )
        }

        if pruneSnapshotWindow {
            try pruneSnapshotMessageWindow(db, dialog: dialog)
        }

        try db.execute(
            sql: "DELETE FROM dialog_unread_summaries WHERE dialog_id = ?",
            arguments: [dialog.dialogId]
        )
        try db.execute(
            sql: "DELETE FROM dialog_members WHERE dialog_id = ?",
            arguments: [dialog.dialogId]
        )
        for member in dialog.members {
            try db.execute(
                sql: """
                INSERT INTO dialog_members (
                  dialog_id, account_id, role, last_read_msg_id, joined_at, is_active, revision
                )
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    dialog.dialogId, member.accountId, member.role,
                    max(member.lastReadMsgId, existingReads[member.accountId] ?? 0),
                    member.joinedAt,
                    member.isActive ?? true,
                    dialog.revision ?? 0,
                ]
            )
        }

        for message in dialog.messages {
            let existingVersion = try Int.fetchOne(
                db,
                sql: "SELECT edit_version FROM messages WHERE dialog_id = ? AND msg_id = ?",
                arguments: [dialog.dialogId, message.msgId]
            )
            if let existingVersion, message.editVersion < existingVersion { continue }
            if let existingClientId = try String.fetchOne(
                db,
                sql: "SELECT client_msg_id FROM messages WHERE dialog_id = ? AND msg_id = ?",
                arguments: [dialog.dialogId, message.msgId]
            ), existingClientId != message.clientMsgId {
                try deleteCloudMessage(
                    db,
                    dialogId: dialog.dialogId,
                    msgId: message.msgId,
                    localId: nil
                )
            }
            try upsertMessage(db, message: message, localState: "sent", refreshSummaries: false)
        }

        try mergeBootstrapHistoryState(db, dialog: dialog)
        try refreshDialogSummary(db, dialogId: dialog.dialogId)
        try refreshAllUnreadSummaries(db, dialogId: dialog.dialogId)
        if let unreadCount = dialog.unreadCount {
            try setUnreadSummary(
                db,
                dialogId: dialog.dialogId,
                accountId: accountId,
                unreadCount: unreadCount,
                isExact: true
            )
        }
    }

    private func pruneSnapshotMessageWindow(_ db: Database, dialog: BootstrapDialog) throws {
        let stagedMessageIds = Set(dialog.messages.map(\.msgId))
        let lowerBound: Int64
        if let oldest = stagedMessageIds.min() {
            lowerBound = oldest
        } else if dialog.lastMsgId == 0 {
            lowerBound = 0
        } else {
            // A non-empty dialog can legitimately have no preview messages when a server applies a
            // stricter page-size cap. Without a lower bound, retaining history is safer than guessing.
            return
        }

        let pendingTextClientIds = try String.fetchAll(
            db,
            sql: "SELECT client_msg_id FROM pending_outbox WHERE dialog_id = ?",
            arguments: [dialog.dialogId]
        )
        let pendingMediaClientIds = try String.fetchAll(
            db,
            sql: "SELECT client_msg_id FROM media_transfers WHERE dialog_id = ?",
            arguments: [dialog.dialogId]
        )
        let pendingClientIds = Set(pendingTextClientIds + pendingMediaClientIds)
        let pendingMutationIds = Set(try Int64.fetchAll(
            db,
            sql: "SELECT msg_id FROM pending_message_mutations WHERE dialog_id = ?",
            arguments: [dialog.dialogId]
        ))
        let candidates = try Row.fetchAll(
            db,
            sql: """
            SELECT local_id, msg_id, client_msg_id, local_state
            FROM messages
            WHERE dialog_id = ? AND msg_id BETWEEN ? AND ?
            """,
            arguments: [dialog.dialogId, lowerBound, dialog.lastMsgId]
        )
        for row in candidates {
            let msgId: Int64 = row["msg_id"]
            let clientMsgId: String = row["client_msg_id"]
            let localState: String = row["local_state"]
            guard
                !stagedMessageIds.contains(msgId),
                localState == "sent",
                !pendingClientIds.contains(clientMsgId),
                !pendingMutationIds.contains(msgId)
            else { continue }
            try deleteCloudMessage(
                db,
                dialogId: dialog.dialogId,
                msgId: msgId,
                localId: row["local_id"]
            )
        }
    }

    private func deleteCloudMessage(
        _ db: Database,
        dialogId: String,
        msgId: Int64,
        localId: String?
    ) throws {
        if let localId {
            try db.execute(
                sql: "DELETE FROM message_media WHERE local_id = ?",
                arguments: [localId]
            )
        } else {
            try db.execute(
                sql: "DELETE FROM message_media WHERE dialog_id = ? AND msg_id = ?",
                arguments: [dialogId, msgId]
            )
        }
        try db.execute(
            sql: "DELETE FROM message_reactions WHERE dialog_id = ? AND msg_id = ?",
            arguments: [dialogId, msgId]
        )
        try db.execute(
            sql: "DELETE FROM messages WHERE dialog_id = ? AND msg_id = ?",
            arguments: [dialogId, msgId]
        )
    }

    private func mergeBootstrapHistoryState(_ db: Database, dialog: BootstrapDialog) throws {
        let existing = try Row.fetchOne(
            db,
            sql: "SELECT * FROM dialog_history_state WHERE dialog_id = ?",
            arguments: [dialog.dialogId]
        ).map(Self.historyState(from:))
        let snapshotOldest = dialog.messages.map(\.msgId).min()
        let snapshotComplete = dialog.lastMsgId == 0 || snapshotOldest == 1
        let historyComplete = (existing?.historyComplete ?? false) || snapshotComplete
        let nextBeforeMsgId: Int64?
        if historyComplete {
            nextBeforeMsgId = nil
        } else {
            // `/v1/history` uses an exclusive before cursor. Beginning at the snapshot ceiling + 1
            // gives a resumable, server-defined boundary; preview duplicates are harmless upserts.
            let snapshotCursor = dialog.lastMsgId < Int64.max ? dialog.lastMsgId + 1 : dialog.lastMsgId
            nextBeforeMsgId = [existing?.nextBeforeMsgId, snapshotCursor].compactMap { $0 }.min()
        }
        try upsertHistoryState(
            db,
            state: DialogHistoryState(
                dialogId: dialog.dialogId,
                ceilingMsgId: max(existing?.ceilingMsgId ?? 0, dialog.lastMsgId),
                nextBeforeMsgId: nextBeforeMsgId,
                historyComplete: historyComplete,
                retryCount: existing?.retryCount ?? 0,
                nextRetryAt: existing?.nextRetryAt
            )
        )
    }

    private func pruneDialogsMissingFromBootstrap(
        _ db: Database,
        accountId: String,
        stagedDialogIds: Set<String>
    ) throws {
        let publishedDialogIds = try String.fetchAll(
            db,
            sql: "SELECT dialog_id FROM bootstrap_baseline_dialogs WHERE account_id = ?",
            arguments: [accountId]
        )
        for dialogId in publishedDialogIds where !stagedDialogIds.contains(dialogId) {
            let hasPendingWork = try Bool.fetchOne(
                db,
                sql: """
                SELECT
                  EXISTS(SELECT 1 FROM pending_outbox WHERE dialog_id = ?) OR
                  EXISTS(SELECT 1 FROM pending_message_mutations WHERE dialog_id = ?) OR
                  EXISTS(SELECT 1 FROM media_transfers WHERE dialog_id = ?) OR
                  EXISTS(SELECT 1 FROM pending_draft_mutations WHERE dialog_id = ?) OR
                  EXISTS(SELECT 1 FROM pending_media_group_sends WHERE dialog_id = ?) OR
                  EXISTS(
                    SELECT 1 FROM messages
                    WHERE dialog_id = ? AND (msg_id IS NULL OR local_state != 'sent')
                  )
                """,
                arguments: [
                    dialogId, dialogId, dialogId, dialogId, dialogId, dialogId,
                ]
            ) ?? false
            guard !hasPendingWork else { continue }

            // Hydrated messages, history cursors, and semantic viewport anchors intentionally stay
            // on disk. Only snapshot-owned list metadata is pruned, so an active timeline remains
            // readable and a later server reappearance can reuse its already hydrated history.
            try db.execute(
                sql: "DELETE FROM dialog_members WHERE dialog_id = ?",
                arguments: [dialogId]
            )
            try db.execute(
                sql: "DELETE FROM dialog_unread_summaries WHERE dialog_id = ?",
                arguments: [dialogId]
            )
            try db.execute(
                sql: "DELETE FROM dialog_summaries WHERE dialog_id = ?",
                arguments: [dialogId]
            )
            try db.execute(
                sql: "DELETE FROM dialogs WHERE dialog_id = ?",
                arguments: [dialogId]
            )
        }
    }

    func upsertHistoryState(_ db: Database, state: DialogHistoryState) throws {
        try db.execute(
            sql: """
            INSERT INTO dialog_history_state (
              dialog_id, ceiling_msg_id, next_before_msg_id, history_complete,
              retry_count, next_retry_at, updated_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(dialog_id) DO UPDATE SET
              ceiling_msg_id = MAX(dialog_history_state.ceiling_msg_id, excluded.ceiling_msg_id),
              next_before_msg_id = excluded.next_before_msg_id,
              history_complete = excluded.history_complete,
              retry_count = excluded.retry_count,
              next_retry_at = excluded.next_retry_at,
              updated_at = excluded.updated_at
            """,
            arguments: [
                state.dialogId, state.ceilingMsgId, state.nextBeforeMsgId, state.historyComplete,
                state.retryCount, state.nextRetryAt, state.updatedAt
            ]
        )
    }
}
