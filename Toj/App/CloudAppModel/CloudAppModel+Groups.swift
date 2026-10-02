import Foundation
import Observation
import UIKit

extension CloudAppModel {
    func createGroup(title: String, memberIds: [String], photoData: Data? = nil) async -> String? {
        guard capabilities.contains(.groups),
              let accountId = storedSession?.session.accountId,
              let localStore
        else { return nil }
        let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedMembers = Array(Set(memberIds.filter { $0 != accountId })).sorted()
        guard !normalizedTitle.isEmpty, normalizedTitle.count <= 128,
              normalizedTitle.lengthOfBytes(using: .utf8) <= 256,
              !normalizedMembers.isEmpty, normalizedMembers.count <= 199 else {
            presentNotice(
                "Group could not be created",
                message: "Choose at least one member and a group name up to 128 characters."
            )
            return nil
        }

        let groupId = UUID().uuidString.lowercased()
        do {
            let preparedPhoto: PreparedMediaUpload?
            if let photoData {
                guard let photo = SafeMediaImageDecoder.preparePhotoUpload(photoData) else {
                    presentNotice(
                        "Group photo could not be used",
                        message: "Choose a valid photo and try again."
                    )
                    return nil
                }
                preparedPhoto = try await mediaEngine.prepare(
                    data: photo.data,
                    kind: "photo",
                    contentType: photo.contentType,
                    fileName: "group-photo.\(photo.filenameExtension)",
                    width: photo.pixelWidth,
                    height: photo.pixelHeight,
                    thumbnail: photo.thumbnail
                )
            } else {
                preparedPhoto = nil
            }
            _ = try await localStore.createPendingGroup(
                groupId: groupId,
                title: normalizedTitle,
                memberIds: normalizedMembers,
                creatorAccountId: accountId,
                localPhotoReference: preparedPhoto?.encryptedSourcePath
            )
            if let preparedPhoto {
                try await localStore.insertMediaTransfer(
                    prepared: preparedPhoto,
                    dialogId: groupId,
                    clientMsgId: "group-photo:\(preparedPhoto.transferId)",
                    caption: "",
                    replyToMsgId: nil,
                    purpose: "group_photo"
                )
            }
            await refreshDialogs()
            scheduleOutboxRetry()
            return groupId
        } catch {
            presentNotice("Group could not be saved", message: error.localizedDescription)
            return nil
        }
    }

    func updateGroupPhoto(dialogId: String, data: Data) async -> Bool {
        guard let localStore else { return false }
        do {
            guard let photo = SafeMediaImageDecoder.preparePhotoUpload(data) else {
                throw CloudAppModelError.invalidMedia
            }
            let prepared = try await mediaEngine.prepare(
                data: photo.data,
                kind: "photo",
                contentType: photo.contentType,
                fileName: "group-photo.\(photo.filenameExtension)",
                width: photo.pixelWidth,
                height: photo.pixelHeight,
                thumbnail: photo.thumbnail
            )
            try await localStore.insertMediaTransfer(
                prepared: prepared,
                dialogId: dialogId,
                clientMsgId: "group-photo:\(prepared.transferId)",
                caption: "",
                replyToMsgId: nil,
                purpose: "group_photo"
            )
            scheduleOutboxRetry()
            return true
        } catch {
            presentNotice("Group photo was not changed", message: error.localizedDescription)
            return false
        }
    }

    func retryGroupCreation(dialogId: String) async {
        guard let localStore else { return }
        try? await localStore.retryFailedGroupCreation(groupId: dialogId)
        await refreshDialogs()
        scheduleOutboxRetry()
    }

    func loadGroupProfile(dialogId: String) async {
        guard capabilities.contains(.groups),
              let token = storedSession?.session.token,
              let localStore else { return }
        do {
            let envelope = try await api.group(id: dialogId, token: token)
            groupPermissionsByDialog[dialogId] = GroupPermissions(
                membersCanSend: envelope.group.membersCanSend ?? true,
                membersCanAddMembers: envelope.group.membersCanAddMembers ?? false,
                membersCanEditInfo: envelope.group.membersCanEditInfo ?? false
            )
            try await localStore.applyGroupEnvelope(envelope)
            var cursor: String?
            var collected: [CloudGroupMember] = []
            var profiles: [String: CloudProfile] = Dictionary(
                uniqueKeysWithValues: envelope.profiles.map { ($0.accountId, $0) }
            )
            repeat {
                let page = try await api.groupMembers(
                    id: dialogId,
                    cursor: cursor,
                    token: token
                )
                try await localStore.applyGroupMembersPage(page, generation: envelope.group.revision.description)
                collected.append(contentsOf: page.members)
                for profile in page.profiles { profiles[profile.accountId] = profile }
                cursor = page.hasMore ? page.nextCursor : nil
            } while cursor != nil
            groupMembersByDialog[dialogId] = collected.map { member in
                GroupMember(
                    accountId: member.accountId,
                    displayName: profiles[member.accountId]?.displayName ?? shortDialogId(member.accountId),
                    photo: profiles[member.accountId]?.photo,
                    role: member.role,
                    isActive: member.isActive
                )
            }
            await refreshDialogs()
        } catch {
            presentNotice("Group details unavailable", message: error.localizedDescription)
        }
    }

    func groupCallParticipantName(accountId: String, dialogId: String) -> String {
        if accountId == storedSession?.session.accountId {
            return displayName.isEmpty ? String(localized: "You") : displayName
        }
        return groupMembersByDialog[dialogId]?
            .first(where: { $0.accountId == accountId })?
            .displayName ?? shortDialogId(accountId)
    }

    func groupMemberPhoto(accountId: String, dialogId: String) -> CloudMedia? {
        groupMembersByDialog[dialogId]?.first(where: { $0.accountId == accountId })?.photo
    }

    func updateGroupTitle(dialogId: String, title: String) async -> Bool {
        let normalized = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty, normalized.count <= 128,
              normalized.lengthOfBytes(using: .utf8) <= 256 else { return false }
        return await submitGroupMutation(
            dialogId: dialogId,
            operation: "update_title",
            payload: GroupMutationPayload(title: normalized)
        )
    }

    func setGroupMuted(dialogId: String, muted: Bool) {
        guard !isSessionTeardownInProgress else { return }
        if capabilities.contains(.chatOrganization) {
            launchDialogPreferenceMutation(
                dialogId: dialogId,
                field: .muted,
                desiredValue: muted
            )
        } else if capabilities.contains(.groups) {
            launchLegacyGroupMute(dialogId: dialogId, muted: muted)
        }
    }

    func updateGroupPermissions(dialogId: String, permissions: GroupPermissions) async -> Bool {
        guard let token = storedSession?.session.token else { return false }
        do {
            let envelope = try await api.updateGroupPermissions(
                id: dialogId,
                membersCanSend: permissions.membersCanSend,
                membersCanAddMembers: permissions.membersCanAddMembers,
                membersCanEditInfo: permissions.membersCanEditInfo,
                clientMutationId: UUID().uuidString.lowercased(),
                token: token
            )
            try await localStore?.applyGroupEnvelope(envelope)
            groupPermissionsByDialog[dialogId] = GroupPermissions(
                membersCanSend: envelope.group.membersCanSend ?? permissions.membersCanSend,
                membersCanAddMembers: envelope.group.membersCanAddMembers ?? permissions.membersCanAddMembers,
                membersCanEditInfo: envelope.group.membersCanEditInfo ?? permissions.membersCanEditInfo
            )
            await refreshDialogs()
            return true
        } catch {
            presentNotice("Permissions were not changed", message: error.localizedDescription)
            return false
        }
    }

    func addGroupMembers(dialogId: String, accountIds: [String]) async -> Bool {
        let normalized = Array(Set(accountIds)).sorted()
        guard !normalized.isEmpty else { return false }
        return await submitGroupMutation(
            dialogId: dialogId,
            operation: "add_members",
            payload: GroupMutationPayload(memberIds: normalized)
        )
    }

    func removeGroupMember(dialogId: String, accountId: String) async -> Bool {
        await submitGroupMutation(
            dialogId: dialogId,
            operation: "remove_member",
            payload: GroupMutationPayload(accountId: accountId)
        )
    }

    func changeGroupMemberRole(
        dialogId: String,
        accountId: String,
        role: String
    ) async -> Bool {
        return await submitGroupMutation(
            dialogId: dialogId,
            operation: "change_role",
            payload: GroupMutationPayload(accountId: accountId, role: role)
        )
    }

    func transferGroupOwnership(dialogId: String, accountId: String) async -> Bool {
        await submitGroupMutation(
            dialogId: dialogId,
            operation: "transfer_owner",
            payload: GroupMutationPayload(accountId: accountId)
        )
    }

    func leaveGroup(dialogId: String) async -> Bool {
        await submitGroupMutation(
            dialogId: dialogId,
            operation: "leave",
            payload: GroupMutationPayload()
        )
    }

    func submitGroupMutation(
        dialogId: String,
        operation: String,
        payload: GroupMutationPayload
    ) async -> Bool {
        if operation == "notifications", isSessionTeardownInProgress { return false }
        guard
            capabilities.contains(.groups),
            let localStore,
            let accountId = storedSession?.session.accountId
        else { return false }
        let generation = accountSessionGeneration
        do {
            let mutationId = UUID().uuidString.lowercased()
            let payloadJSON = String(
                data: try JSONEncoder().encode(payload),
                encoding: .utf8
            ) ?? "{}"
            try await localStore.enqueueGroupMutation(
                dialogId: dialogId,
                operation: operation,
                payloadJSON: payloadJSON,
                clientMutationId: mutationId,
                accountId: accountId
            )
            guard
                !Task.isCancelled,
                generation == accountSessionGeneration,
                storedSession?.session.accountId == accountId
            else { return false }
            await retryPendingGroupMutations()
            guard
                !Task.isCancelled,
                generation == accountSessionGeneration,
                storedSession?.session.accountId == accountId
            else { return false }
            scheduleOutboxRetry()
            return true
        } catch {
            presentNotice("Group change could not be saved", message: error.localizedDescription)
            return false
        }
    }
}
