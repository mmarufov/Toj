import Foundation
import Observation
import UIKit

extension CloudAppModel {
    func refreshCloudProductivity() async {
        guard let context = currentAccountOperationContext() else { return }
        await productivitySyncCoordinator.bind(context)
        if let cachedFolders = try? await context.store.effectiveChatFolderSnapshot(
            accountId: context.accountId
        ), isCurrentAccountOperation(context) {
            chatFolders = cachedFolders.folders.sorted { $0.position < $1.position }
            chatFolderCollectionRevision = cachedFolders.collectionRevision
        }
        if let cachedSchedules = try? await context.store.scheduledDeliveries(
            accountId: context.accountId
        ), isCurrentAccountOperation(context) {
            scheduledDeliveries = cachedSchedules.sorted { $0.deliverAt < $1.deliverAt }
        }
        if capabilities.contains(.chatFolders),
           let snapshot = try? await productivitySyncCoordinator.refreshFolders(api: api),
           isCurrentAccountOperation(context) {
            chatFolders = snapshot.folders.sorted { $0.position < $1.position }
            chatFolderCollectionRevision = snapshot.collectionRevision
        }
        if capabilities.contains(.scheduledDelivery) {
            _ = try? await productivitySyncCoordinator.refreshScheduledDeliveries(api: api)
            if isCurrentAccountOperation(context),
               let merged = try? await context.store.scheduledDeliveries(
                accountId: context.accountId
               ), isCurrentAccountOperation(context) {
                scheduledDeliveries = merged.sorted { $0.deliverAt < $1.deliverAt }
            }
        }
        guard isCurrentAccountOperation(context) else { return }
        let report = await productivitySyncCoordinator.drain(api: api)
        await publishProductivityDrainReport(report, context: context)
    }

    func dialog(_ dialog: Dialog, isIncludedIn folder: CloudChatFolder) -> Bool {
        let explicit = folder.rules.first { $0.dialogId == dialog.id }?.rule
        if explicit == "exclude" { return false }
        if explicit == "include" { return true }
        guard !dialog.isArchived || !folder.excludeArchived else { return false }
        if folder.excludeRead && dialog.unreadCount == 0 { return false }
        if folder.excludeMuted && dialog.isMuted { return false }
        return switch dialog.type {
        case "direct": folder.includeDirect
        case "group": folder.includeGroups
        case "saved": folder.includeSaved
        default: false
        }
    }

    func createChatFolder(
        title: String,
        icon: String = "folder",
        includeDirect: Bool = true,
        includeGroups: Bool = true,
        includeSaved: Bool = false,
        excludeRead: Bool = false,
        excludeMuted: Bool = false,
        excludeArchived: Bool = true,
        rules: [CloudChatFolderRule] = []
    ) async throws {
        guard let context = currentAccountOperationContext(), capabilities.contains(.chatFolders) else {
            throw CloudAPIError(status: 404, message: "Chat folders are unavailable", retryAfter: nil)
        }
        let now = ISO8601DateFormatter().string(from: Date())
        let folder = CloudChatFolder(
            folderId: UUID().uuidString.lowercased(),
            title: title,
            icon: Self.semanticFolderIcon(icon),
            position: chatFolders.count,
            includeDirect: includeDirect,
            includeGroups: includeGroups,
            includeSaved: includeSaved,
            excludeRead: excludeRead,
            excludeMuted: excludeMuted,
            excludeArchived: excludeArchived,
            revision: 0,
            rules: rules,
            createdAt: now,
            updatedAt: now
        )
        await productivitySyncCoordinator.bind(context)
        guard isCurrentAccountOperation(context) else { return }
        let result: CloudChatFolderSnapshot
        do {
            result = try await productivitySyncCoordinator.stageChatFolderMutation(
                CloudFolderMutationIntent(
                    operation: .create,
                    folderId: folder.folderId,
                    folder: folder,
                    beforeFolderId: nil,
                    afterFolderId: nil
                )
            )
        } catch CloudProductivityRefreshError.sessionChanged { return }
        guard isCurrentAccountOperation(context) else { return }
        chatFolders = result.folders.sorted { $0.position < $1.position }
        chatFolderCollectionRevision = result.collectionRevision
        status = "Folder saved locally"
        scheduleOutboxRetry()
    }

    func updateChatFolder(
        _ folder: CloudChatFolder,
        title: String,
        icon: String,
        includeDirect: Bool,
        includeGroups: Bool,
        includeSaved: Bool,
        excludeRead: Bool,
        excludeMuted: Bool,
        excludeArchived: Bool,
        rules: [CloudChatFolderRule]
    ) async throws {
        guard let context = currentAccountOperationContext() else { return }
        let desired = CloudChatFolder(
            folderId: folder.folderId,
            title: title,
            icon: Self.semanticFolderIcon(icon),
            position: folder.position,
            includeDirect: includeDirect,
            includeGroups: includeGroups,
            includeSaved: includeSaved,
            excludeRead: excludeRead,
            excludeMuted: excludeMuted,
            excludeArchived: excludeArchived,
            revision: folder.revision,
            rules: rules,
            createdAt: folder.createdAt,
            updatedAt: ISO8601DateFormatter().string(from: Date())
        )
        await productivitySyncCoordinator.bind(context)
        guard isCurrentAccountOperation(context) else { return }
        let result: CloudChatFolderSnapshot
        do {
            result = try await productivitySyncCoordinator.stageChatFolderMutation(
                CloudFolderMutationIntent(
                    operation: .update,
                    folderId: folder.folderId,
                    folder: desired,
                    beforeFolderId: nil,
                    afterFolderId: nil
                )
            )
        } catch CloudProductivityRefreshError.sessionChanged { return }
        guard isCurrentAccountOperation(context) else { return }
        chatFolders = result.folders.sorted { $0.position < $1.position }
        chatFolderCollectionRevision = result.collectionRevision
        status = "Folder saved locally"
        scheduleOutboxRetry()
    }

    func deleteChatFolder(_ folder: CloudChatFolder) async throws {
        guard let context = currentAccountOperationContext() else { return }
        await productivitySyncCoordinator.bind(context)
        guard isCurrentAccountOperation(context) else { return }
        let result: CloudChatFolderSnapshot
        do {
            result = try await productivitySyncCoordinator.stageChatFolderMutation(
                CloudFolderMutationIntent(
                    operation: .delete,
                    folderId: folder.folderId,
                    folder: nil,
                    beforeFolderId: nil,
                    afterFolderId: nil
                )
            )
        } catch CloudProductivityRefreshError.sessionChanged { return }
        guard isCurrentAccountOperation(context) else { return }
        chatFolders = result.folders.sorted { $0.position < $1.position }
        chatFolderCollectionRevision = result.collectionRevision
        status = "Folder removed locally"
        scheduleOutboxRetry()
    }

    func moveChatFolder(
        _ folder: CloudChatFolder,
        before: CloudChatFolder? = nil,
        after: CloudChatFolder? = nil
    ) async throws {
        guard let context = currentAccountOperationContext() else { return }
        var desiredOrder = chatFolders.map(\.folderId)
        desiredOrder.removeAll { $0 == folder.folderId }
        if let before,
           let index = desiredOrder.firstIndex(of: before.folderId) {
            desiredOrder.insert(folder.folderId, at: index)
        } else if let after,
                  let index = desiredOrder.firstIndex(of: after.folderId) {
            desiredOrder.insert(folder.folderId, at: index + 1)
        }
        await productivitySyncCoordinator.bind(context)
        guard isCurrentAccountOperation(context) else { return }
        let result: CloudChatFolderSnapshot
        do {
            result = try await productivitySyncCoordinator.stageChatFolderMutation(
                CloudFolderMutationIntent(
                    operation: .move,
                    folderId: folder.folderId,
                    folder: nil,
                    beforeFolderId: before?.folderId,
                    afterFolderId: after?.folderId,
                    desiredOrder: desiredOrder
                )
            )
        } catch CloudProductivityRefreshError.sessionChanged { return }
        guard isCurrentAccountOperation(context) else { return }
        chatFolders = result.folders.sorted { $0.position < $1.position }
        chatFolderCollectionRevision = result.collectionRevision
        status = "Folder order saved locally"
        scheduleOutboxRetry()
    }

    func cancelScheduledDelivery(_ delivery: CloudScheduledDelivery) async throws {
        guard let context = currentAccountOperationContext() else { return }
        await productivitySyncCoordinator.bind(context)
        guard isCurrentAccountOperation(context) else { return }
        if delivery.revision == 0 {
            let effective: [CloudScheduledDelivery]?
            do {
                effective = try await productivitySyncCoordinator
                    .discardUnattemptedScheduledCreate(scheduleId: delivery.scheduleId)
            } catch CloudProductivityRefreshError.sessionChanged { return }
            if let effective {
                guard isCurrentAccountOperation(context) else { return }
                scheduledDeliveries = effective.sorted { $0.deliverAt < $1.deliverAt }
                return
            }
        }
        let merged: [CloudScheduledDelivery]
        do {
            merged = try await productivitySyncCoordinator.stageScheduledDeliveryMutation(
                CloudScheduledMutationIntent(
                    operation: .cancel,
                    scheduleId: delivery.scheduleId,
                    deliverAt: nil
                )
            )
        } catch CloudProductivityRefreshError.sessionChanged { return }
        guard isCurrentAccountOperation(context) else { return }
        scheduledDeliveries = merged.sorted { $0.deliverAt < $1.deliverAt }
        status = "Cancellation saved locally — it may still send until confirmed"
        scheduleOutboxRetry()
    }

    func rescheduleDelivery(_ delivery: CloudScheduledDelivery, to date: Date) async throws {
        guard let context = currentAccountOperationContext() else { return }
        await productivitySyncCoordinator.bind(context)
        guard isCurrentAccountOperation(context) else { return }
        let merged: [CloudScheduledDelivery]
        do {
            merged = try await productivitySyncCoordinator.stageScheduledDeliveryMutation(
                CloudScheduledMutationIntent(
                    operation: .reschedule,
                    scheduleId: delivery.scheduleId,
                    deliverAt: ISO8601DateFormatter().string(from: date)
                )
            )
        } catch CloudProductivityRefreshError.sessionChanged { return }
        guard isCurrentAccountOperation(context) else { return }
        scheduledDeliveries = merged.sorted { $0.deliverAt < $1.deliverAt }
        status = "New delivery time saved locally"
        scheduleOutboxRetry()
    }

    private static func semanticFolderIcon(_ icon: String) -> String {
        switch icon {
        case "person.2": "personal"
        case "message.badge": "unread"
        case "briefcase": "work"
        case "star": "favorite"
        default: icon
        }
    }

    func sendStagedDraft(silent: Bool) async {
        guard
            let dialogId = activeDialogId,
            let accountId = storedSession?.session.accountId,
            let localStore
        else { return }
        await draftPersistenceTasks[dialogId]?.value
        guard let draft = try? await localStore.loadDraft(accountId: accountId, dialogId: dialogId),
              draft.state == "active",
              !draft.attachments.isEmpty else { return }
        guard draftSendsInFlightByDialog[dialogId] == nil else { return }
        draftSendsInFlightByDialog[dialogId] = draft.operationId
        defer {
            if draftSendsInFlightByDialog[dialogId] == draft.operationId {
                draftSendsInFlightByDialog[dialogId] = nil
            }
        }
        guard draft.attachments.allSatisfy({ $0.state == "ready" && $0.mediaId != nil }) else {
            presentNotice(
                "Attachments are still preparing",
                message: "Wait for every attachment to finish, or remove the failed item."
            )
            return
        }
        if draft.attachments.count > 1, !capabilities.contains(.mediaGroups) {
            presentNotice(
                "Grouped sending is unavailable",
                message: "Your draft is saved. It will not be split into separate messages."
            )
            return
        }
        openingTimelineAnchor = .bottom
        timelineTopVisibleMsgId = nil
        timelineIsAtBottom = true
        suppressDraftPersistence = true
        self.draft = ""
        suppressDraftPersistence = false
        composerMode = .text

        do {
            if draft.attachments.count == 1 {
                let transfer = try await localStore.consumeDraftAsSingleMedia(
                    accountId: accountId,
                    dialogId: dialogId,
                    operationId: draft.operationId,
                    silent: silent
                )
                await loadLocalLines(dialogId: dialogId)
                await refreshDialogs()
                Task { [weak self] in await self?.runMediaTransfer(transfer) }
                scheduleOutboxRetry()
            } else {
                let group = try await localStore.consumeDraftAsMediaGroup(
                    accountId: accountId,
                    dialogId: dialogId,
                    operationId: draft.operationId,
                    silent: silent
                )
                await loadLocalLines(dialogId: dialogId)
                await refreshDialogs()
                Task { [weak self] in await self?.processMediaGroupSend(group) }
                scheduleOutboxRetry()
            }
        } catch {
            suppressDraftPersistence = true
            self.draft = draft.text
            suppressDraftPersistence = false
            status = "Local send failed: \(error.localizedDescription)"
            presentNotice("Could not queue attachments", message: error.localizedDescription)
        }
    }

    func scheduleStagedDraft(deliverAt: Date, silent: Bool) async {
        guard capabilities.contains(.scheduledDelivery) else {
            presentNotice(
                "Scheduled sending is unavailable",
                message: "Your attachment draft is still saved on this device."
            )
            return
        }
        guard deliverAt >= Date().addingTimeInterval(60) else {
            presentNotice("Choose a later time", message: "Scheduled delivery must be at least one minute away.")
            return
        }
        guard let dialogId = activeDialogId,
              let context = currentAccountOperationContext() else { return }
        let localStore = context.store
        await draftPersistenceTasks[dialogId]?.value
        guard isCurrentAccountOperation(context), activeDialogId == dialogId else { return }
        guard let stored = try? await localStore.loadDraft(
            accountId: context.accountId,
            dialogId: dialogId
        ), isCurrentAccountOperation(context), activeDialogId == dialogId,
           stored.state == "active", !stored.attachments.isEmpty else { return }
        let attachments = stored.attachments.sorted { $0.position < $1.position }
        guard attachments.allSatisfy({
            $0.state == "ready" && $0.mediaId != nil && $0.media != nil
        }) else {
            presentNotice(
                "Attachments are still preparing",
                message: "Wait for every attachment to finish before scheduling."
            )
            return
        }
        if attachments.count > 1,
           attachments.contains(where: { $0.media?.kind == "voice" }) {
            presentNotice(
                "Voice messages cannot be grouped",
                message: "Schedule the voice message by itself."
            )
            return
        }
        let items = attachments.enumerated().map { index, attachment in
            let body = index == 0 ? stored.text : ""
            return CloudScheduledItem(
                clientMsgId: UUID().uuidString.lowercased(),
                kind: attachment.media!.kind,
                body: body,
                replyToMsgId: index == 0 ? stored.replyToMsgId : nil,
                mediaId: attachment.mediaId,
                mentions: index == 0 ? stored.mentions : [],
                linkPreviewCandidate: index == 0 && capabilities.contains(.linkPreviews)
                    ? CloudLinkPreviewCandidate.first(in: body)
                    : nil
            )
        }
        let request = CloudScheduledCreateRequest(
            scheduleId: UUID().uuidString.lowercased(),
            clientMutationId: UUID().uuidString.lowercased(),
            dialogId: dialogId,
            deliverAt: ISO8601DateFormatter().string(from: deliverAt),
            silent: silent,
            reminder: dialogs.first(where: { $0.id == dialogId })?.type == "saved",
            items: items
        )
        do {
            await productivitySyncCoordinator.bind(context)
            guard isCurrentAccountOperation(context) else { return }
            let local = try await productivitySyncCoordinator.stageScheduledCreate(
                request,
                draftOperationId: stored.operationId
            )
            guard isCurrentAccountOperation(context), activeDialogId == dialogId else { return }
            suppressDraftPersistence = true
            draft = ""
            suppressDraftPersistence = false
            composerMode = .text
            scheduledDeliveries.removeAll { $0.scheduleId == local.scheduleId }
            scheduledDeliveries.append(local)
            scheduledDeliveries.sort { $0.deliverAt < $1.deliverAt }
            status = String(localized: "Waiting for connection — not scheduled yet")
            scheduleOutboxRetry()
        } catch {
            guard isCurrentAccountOperation(context) else { return }
            presentNotice("Attachments were not scheduled", message: error.localizedDescription)
        }
    }

    func clearDraftAfterScheduledAcknowledgement(
        dialogId: String,
        operationId: String?,
        accountId: String,
        localStore: CloudLocalStore
    ) async {
        guard let operationId,
              let current = try? await localStore.loadDraft(accountId: accountId, dialogId: dialogId),
              current.operationId == operationId else { return }
        for attachment in current.attachments {
            let transfer: MediaTransferRecord?
            if let transferId = attachment.transferId {
                transfer = try? await localStore.mediaTransfer(id: transferId)
            } else {
                transfer = nil
            }
            if let transferId = try? await localStore.removeDraftAttachment(
                accountId: accountId,
                dialogId: dialogId,
                attachmentId: attachment.attachmentId
            ) {
                mediaTransferTasks[transferId]?.cancel()
            }
            if let transfer { await mediaEngine.discardTransfer(transfer) }
        }
        _ = try? await draftSyncCoordinator.mutate(
            dialogId: dialogId,
            text: "",
            replyToMsgId: nil,
            replyPreview: nil,
            mentions: [],
            reason: .attachmentChanged
        )
    }
}
