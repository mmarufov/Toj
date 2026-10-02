import Foundation
import GRDB
import os
import Security

extension CloudLocalStore {
    static func pendingDraftMutation(from row: Row) -> PendingDraftMutation? {
        guard
            let json: String = row["payload_json"],
            let data = json.data(using: .utf8),
            let payload = try? JSONDecoder().decode(StoredDraftMutationPayload.self, from: data)
        else { return nil }
        return PendingDraftMutation(
            accountId: row["account_id"],
            dialogId: row["dialog_id"],
            operationId: row["operation_id"],
            localGeneration: row["local_generation"],
            state: payload.state,
            text: payload.text,
            replyToMsgId: payload.replyToMsgId,
            mentions: payload.mentions,
            attachments: payload.attachments,
            retryCount: row["retry_count"],
            nextRetryAt: row["next_retry_at"],
            lastError: row["last_error"],
            terminal: (row["terminal"] as Int) != 0
        )
    }

    static func pendingMediaGroupSend(from row: Row) -> PendingMediaGroupSend? {
        guard
            let json: String = row["payload_json"],
            let data = json.data(using: .utf8),
            let payload = try? JSONDecoder().decode(PendingMediaGroupPayload.self, from: data)
        else { return nil }
        return PendingMediaGroupSend(
            clientGroupId: row["client_group_id"],
            accountId: row["account_id"],
            dialogId: row["dialog_id"],
            payload: payload,
            draftConsumeOperationId: row["draft_consume_operation_id"],
            retryCount: row["retry_count"],
            nextRetryAt: row["next_retry_at"],
            lastError: row["last_error"],
            terminal: (row["terminal"] as Int) != 0
        )
    }

    func upsertMessage(
        _ db: Database,
        message: CloudMessage,
        localState: String,
        refreshSummaries: Bool = true
    ) throws {
        let previousLocalId = try String.fetchOne(
            db,
            sql: "SELECT local_id FROM messages WHERE client_msg_id = ?",
            arguments: [message.clientMsgId]
        )
        try db.execute(
            sql: """
            INSERT INTO messages (
              local_id, dialog_id, msg_id, client_msg_id, sender_account_id, kind, text,
              reply_to_msg_id, forwarded_from_account_id, forwarded_from_dialog_id,
              forwarded_from_msg_id, is_forwarded, edit_version, state, server_ts, local_state,
              mentions_json, media_json, service_type, service_data_json,
              media_group_id, media_group_index, media_group_count, link_preview_json
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(client_msg_id) DO UPDATE SET
              local_id = excluded.local_id,
              dialog_id = excluded.dialog_id,
              msg_id = excluded.msg_id,
              sender_account_id = excluded.sender_account_id,
              kind = excluded.kind,
              text = excluded.text,
              reply_to_msg_id = excluded.reply_to_msg_id,
              forwarded_from_account_id = excluded.forwarded_from_account_id,
              forwarded_from_dialog_id = excluded.forwarded_from_dialog_id,
              forwarded_from_msg_id = excluded.forwarded_from_msg_id,
              is_forwarded = excluded.is_forwarded,
              mentions_json = excluded.mentions_json,
              media_json = excluded.media_json,
              service_type = excluded.service_type,
              service_data_json = excluded.service_data_json,
              media_group_id = excluded.media_group_id,
              media_group_index = excluded.media_group_index,
              media_group_count = excluded.media_group_count,
              link_preview_json = excluded.link_preview_json,
              edit_version = excluded.edit_version,
              state = excluded.state,
              server_ts = excluded.server_ts,
              local_state = excluded.local_state
            """,
            arguments: [
                message.id,
                message.dialogId,
                message.msgId,
                message.clientMsgId,
                message.senderAccountId,
                message.kind,
                message.text,
                message.replyToMsgId,
                message.forwardedFromAccountId,
                message.forwardedFromDialogId,
                message.forwardedFromMsgId,
                message.isForwarded,
                message.editVersion,
                message.state,
                message.serverTs,
                localState,
                message.mentions.isEmpty
                    ? "[]"
                    : String(data: try JSONEncoder().encode(message.mentions), encoding: .utf8) ?? "[]",
                message.media.flatMap { try? JSONEncoder().encode($0) }.flatMap { String(data: $0, encoding: .utf8) },
                message.serviceType,
                message.serviceData.flatMap { try? JSONEncoder().encode($0) }.flatMap { String(data: $0, encoding: .utf8) },
                message.mediaGroupId,
                message.mediaGroupIndex,
                message.mediaGroupCount,
                message.linkPreview.flatMap { try? JSONEncoder().encode($0) }
                    .flatMap { String(data: $0, encoding: .utf8) }
            ]
        )
        if let previousLocalId, previousLocalId != message.id {
            try db.execute(sql: "DELETE FROM message_media WHERE local_id = ?", arguments: [previousLocalId])
        }
        if let media = message.media {
            try Self.upsertMessageMedia(
                db,
                localId: message.id,
                dialogId: message.dialogId,
                msgId: message.msgId,
                media: media
            )
        } else {
            try db.execute(sql: "DELETE FROM message_media WHERE local_id = ?", arguments: [message.id])
        }
        try db.execute(
            sql: "DELETE FROM message_reactions WHERE dialog_id = ? AND msg_id = ?",
            arguments: [message.dialogId, message.msgId]
        )
        for reaction in message.reactions {
            try db.execute(
                sql: """
                INSERT INTO message_reactions (dialog_id, msg_id, account_id, emoji)
                VALUES (?, ?, ?, ?)
                """,
                arguments: [message.dialogId, message.msgId, reaction.accountId, reaction.emoji]
            )
        }
        try db.execute(
            sql: "DELETE FROM message_mentions WHERE dialog_id = ? AND msg_id = ?",
            arguments: [message.dialogId, message.msgId]
        )
        for mention in message.mentions {
            try db.execute(
                sql: """
                INSERT INTO message_mentions (dialog_id, msg_id, account_id, entity_offset, length)
                VALUES (?, ?, ?, ?, ?)
                """,
                arguments: [
                    message.dialogId, message.msgId, mention.accountId, mention.offset, mention.length
                ]
            )
        }
        if refreshSummaries {
            try refreshDialogSummary(db, dialogId: message.dialogId)
            try refreshAllUnreadSummaries(db, dialogId: message.dialogId)
        }
    }

    static func message(from row: Row, reactions: [CloudReaction]) -> LocalMessage {
        LocalMessage(
            localId: row["local_id"],
            dialogId: row["dialog_id"],
            msgId: row["msg_id"],
            clientMsgId: row["client_msg_id"],
            senderAccountId: row["sender_account_id"],
            senderDisplayName: row["sender_display_name"],
            kind: row["kind"],
            text: row["text"],
            replyToMsgId: row["reply_to_msg_id"],
            forwardedFromAccountId: row["forwarded_from_account_id"],
            forwardedFromDialogId: row["forwarded_from_dialog_id"],
            forwardedFromMsgId: row["forwarded_from_msg_id"],
            isForwarded: row["is_forwarded"],
            reactions: reactions,
            mentions: (row["mentions_json"] as String?)
                .flatMap { $0.data(using: .utf8) }
                .flatMap { try? JSONDecoder().decode([CloudMention].self, from: $0) } ?? [],
            media: (row["media_json"] as String?).flatMap { $0.data(using: .utf8) }.flatMap { try? JSONDecoder().decode(CloudMedia.self, from: $0) },
            mediaGroupId: row["media_group_id"],
            mediaGroupIndex: row["media_group_index"],
            mediaGroupCount: row["media_group_count"],
            serviceType: row["service_type"],
            serviceData: (row["service_data_json"] as String?)
                .flatMap { $0.data(using: .utf8) }
                .flatMap { try? JSONDecoder().decode(CloudServiceData.self, from: $0) },
            linkPreview: (row["link_preview_json"] as String?)
                .flatMap { $0.data(using: .utf8) }
                .flatMap { try? JSONDecoder().decode(CloudLinkPreview.self, from: $0) },
            editVersion: row["edit_version"],
            state: row["state"],
            serverTs: row["server_ts"],
            localState: row["local_state"]
        )
    }

    static func mediaTransfer(from row: Row) -> MediaTransferRecord {
        MediaTransferRecord(
            transferId: row["transfer_id"], dialogId: row["dialog_id"],
            clientMsgId: row["client_msg_id"], caption: row["caption"],
            replyToMsgId: row["reply_to_msg_id"], purpose: row["purpose"],
            draftOperationId: row["draft_operation_id"],
            mentions: (row["mentions_json"] as String?)
                .flatMap { $0.data(using: .utf8) }
                .flatMap { try? JSONDecoder().decode([CloudMention].self, from: $0) } ?? [],
            silent: (row["silent"] as Int? ?? 0) != 0,
            kind: row["kind"],
            contentType: row["content_type"], fileName: row["file_name"],
            byteSize: row["byte_size"], sha256: row["sha256"], durationMs: row["duration_ms"],
            width: row["width"], height: row["height"],
            encryptedSourcePath: row["encrypted_source_path"],
            encryptedThumbnailPath: row["encrypted_thumbnail_path"], mediaId: row["media_id"],
            uploadOffset: row["upload_offset"], state: row["state"],
            retryCount: row["retry_count"], nextRetryAt: row["next_retry_at"],
            lastError: row["last_error"], terminal: (row["terminal"] as Int) != 0
        )
    }

    static func messageMutation(from row: Row) -> PendingMessageMutation {
        PendingMessageMutation(
            clientMutationId: row["client_mutation_id"], operation: row["operation"],
            dialogId: row["dialog_id"], msgId: row["msg_id"], body: row["body"],
            expectedEditVersion: row["expected_edit_version"], emoji: row["emoji"],
            retryCount: row["retry_count"], nextRetryAt: row["next_retry_at"],
            lastError: row["last_error"]
        )
    }

    static func pendingGroupCreation(from row: Row) -> PendingGroupCreation? {
        guard
            let json: String = row["member_ids_json"],
            let data = json.data(using: .utf8),
            let memberIds = try? JSONDecoder().decode([String].self, from: data)
        else { return nil }
        return PendingGroupCreation(
            groupId: row["group_id"],
            title: row["title"],
            memberIds: memberIds,
            localPhotoReference: row["local_photo_reference"],
            state: row["state"],
            retryCount: row["retry_count"],
            nextRetryAt: row["next_retry_at"],
            lastError: row["last_error"],
            terminal: (row["terminal"] as Int) != 0
        )
    }

    static func pendingGroupMutation(from row: Row) -> PendingGroupMutation {
        PendingGroupMutation(
            clientMutationId: row["client_mutation_id"],
            dialogId: row["dialog_id"],
            operation: row["operation"],
            payloadJSON: row["payload_json"],
            retryCount: row["retry_count"],
            nextRetryAt: row["next_retry_at"],
            lastError: row["last_error"],
            terminal: (row["terminal"] as Int) != 0,
            localOrder: row["local_order"],
            attemptedAt: row["attempted_at"]
        )
    }

    static func pendingDialogPreference(
        from row: Row
    ) -> PendingDialogPreferenceMutation {
        PendingDialogPreferenceMutation(
            accountId: row["account_id"],
            dialogId: row["dialog_id"],
            field: DialogPreferenceField(rawValue: row["field"]) ?? .muted,
            desiredValue: (row["desired_value"] as Int) != 0,
            clientMutationId: row["client_mutation_id"],
            retryCount: row["retry_count"],
            nextRetryAt: row["next_retry_at"],
            acknowledgedPts: row["acknowledged_pts"],
            lastError: row["last_error"],
            localOrder: row["local_order"],
            attemptedAt: row["attempted_at"],
            dormant: (row["dormant"] as Int) != 0
        )
    }

    static func dialog(from row: Row) -> LocalDialog {
        LocalDialog(
            dialogId: row["dialog_id"],
            type: row["type"],
            title: row["title"],
            photo: (row["photo_media_json"] as String?)
                .flatMap { $0.data(using: .utf8) }
                .flatMap { try? JSONDecoder().decode(CloudMedia.self, from: $0) },
            lastMsgId: row["last_msg_id"],
            updatedAt: row["updated_at"],
            lastText: row["last_text"],
            lastKind: row["last_kind"],
            lastState: row["last_state"],
            lastSenderAccountId: row["last_sender_account_id"],
            lastLocalState: row["last_local_state"],
            lastServerTs: row["last_server_ts"],
            unreadCount: row["unread_count"],
            mentionCount: row["mention_count"],
            peerAccountId: row["peer_account_id"],
            peerBio: row["peer_bio"],
            peerBirthday: row["peer_birthday"],
            peerColorIndex: row["peer_color_index"],
            revision: row["revision"],
            memberCount: row["member_count"],
            selfRole: row["self_role"],
            notificationMode: row["notification_mode"],
            accessState: row["access_state"],
            draftText: row["draft_text"],
            draftAttachmentCount: row["draft_attachment_count"],
            hasDraftReply: (row["has_draft_reply"] as Int) != 0,
            isPinned: (row["is_pinned"] as Int) != 0,
            pinnedAt: row["pinned_at"],
            isMuted: (row["is_muted"] as Int) != 0,
            isArchived: (row["is_archived"] as Int) != 0
        )
    }

    static func pendingOutboxItem(from row: Row) -> PendingOutboxItem {
        PendingOutboxItem(
            clientMsgId: row["client_msg_id"],
            dialogId: row["dialog_id"],
            body: row["body"],
            replyToMsgId: row["reply_to_msg_id"],
            forwardedFromDialogId: row["forwarded_from_dialog_id"],
            forwardedFromMsgId: row["forwarded_from_msg_id"],
            mentions: (row["mentions_json"] as String?)
                .flatMap { $0.data(using: .utf8) }
                .flatMap { try? JSONDecoder().decode([CloudMention].self, from: $0) } ?? [],
            draftConsumeOperationId: row["draft_consume_operation_id"],
            silent: (row["silent"] as Int? ?? 0) != 0,
            retryCount: row["retry_count"],
            nextRetryAt: row["next_retry_at"]
        )
    }
}
