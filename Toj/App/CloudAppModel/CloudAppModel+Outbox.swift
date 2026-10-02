import Foundation
import Observation
import UIKit

extension CloudAppModel {
    func markReadIfNeeded(dialogId: String, messages: [LocalMessage]) async {
        guard let accountId = storedSession?.session.accountId, let localStore else { return }
        guard dialogs.first(where: { $0.id == dialogId })?.type != "saved" else { return }
        guard let maxMsgId = messages.compactMap(\.msgId).max() else { return }

        do {
            let current = try await localStore.maxReadMsgId(dialogId: dialogId, accountId: accountId)
            guard maxMsgId > current else { return }
            try await localStore.queueReadReceipt(
                dialogId: dialogId,
                accountId: accountId,
                maxReadMsgId: maxMsgId
            )
            await refreshDialogs()
            scheduleReadReceiptRetry()
        } catch {
            status = "Could not save read position"
        }
    }

    func scheduleReadReceiptRetry() {
        guard readReceiptRetryTask == nil else {
            // A receipt can be queued after the active drain captured its database snapshot. Keep
            // the task alive for another pass so that receipt cannot be stranded until relaunch.
            readReceiptDrainRequested = true
            return
        }
        readReceiptDrainRequested = true
        readReceiptRetryTask = Task { [weak self] in
            guard let self else { return }
            repeat {
                self.readReceiptDrainRequested = false
                await self.retryPendingReadReceipts()
                if !self.readReceiptDrainRequested,
                   let localStore = self.localStore,
                   let remaining = try? await localStore.pendingReadReceiptsReady(limit: 1),
                   !remaining.isEmpty {
                    self.readReceiptDrainRequested = true
                }
            } while !Task.isCancelled && self.readReceiptDrainRequested
            self.readReceiptRetryTask = nil
        }
    }

    func retryPendingReadReceipts() async {
        guard let token = storedSession?.session.token,
              let accountId = storedSession?.session.accountId,
              let localStore else { return }
        let receipts: [PendingReadReceipt]
        do {
            receipts = try await localStore.pendingReadReceiptsReady()
        } catch {
            return
        }

        for receipt in receipts where receipt.accountId == accountId {
            if Task.isCancelled || storedSession?.session.token != token { return }
            do {
                let response = try await api.markRead(
                    dialogId: receipt.dialogId,
                    maxReadMsgId: receipt.maxReadMsgId,
                    token: token
                )
                try await localStore.markRead(
                    dialogId: response.dialogId,
                    accountId: accountId,
                    maxReadMsgId: response.maxReadMsgId,
                    exactUnreadCount: response.unreadCount
                )
                if response.maxReadMsgId >= receipt.maxReadMsgId {
                    try await localStore.completeReadReceipt(
                        dialogId: receipt.dialogId,
                        accountId: accountId,
                        acknowledgedMsgId: response.maxReadMsgId
                    )
                } else {
                    try await localStore.failReadReceipt(
                        dialogId: receipt.dialogId,
                    accountId: accountId,
                    retryAfter: 5,
                    error: "partial acknowledgement",
                    attemptedMsgId: receipt.maxReadMsgId
                )
                }
            } catch is CancellationError {
                return
            } catch {
                if case .authenticationRequired = cloudFailureDisposition(error) { return }
                let retryAfter: TimeInterval
                if case let .transient(serverRetry) = cloudFailureDisposition(error) {
                    retryAfter = serverRetry ?? retryDelay(forRetryCount: receipt.retryCount + 1)
                } else {
                    retryAfter = retryDelay(forRetryCount: receipt.retryCount + 1)
                }
                try? await localStore.failReadReceipt(
                    dialogId: receipt.dialogId,
                    accountId: accountId,
                    retryAfter: retryAfter,
                    error: error.localizedDescription,
                    attemptedMsgId: receipt.maxReadMsgId
                )
                BackgroundRuntimeCoordinator.shared.scheduleAppRefresh(
                    earliestBeginDate: Date(timeIntervalSinceNow: retryAfter)
                )
            }
        }
    }

    private func retryPendingProfilePhotoCommit() async {
        guard capabilities.contains(.profilePhotos) else { return }
        await handleProfilePhotoCommitResult(await profilePhotoSyncCoordinator.commitReady())
    }

    func handleProfilePhotoCommitResult(_ result: ProfilePhotoCommitResult) async {
        switch result {
        case .idle, .cancelled:
            return
        case let .committed(profile):
            guard let session = storedSession?.session,
                  session.accountId == profile.accountId else { return }
            let generation = accountSessionGeneration
            let expectedStore = localStore
            let token = session.token
            await acceptCanonicalProfile(
                profile,
                accountId: session.accountId,
                deviceId: session.deviceId,
                token: token,
                generation: generation,
                store: expectedStore
            )
            guard generation == accountSessionGeneration,
                  storedSession?.session == session,
                  Self.store(expectedStore, matches: localStore),
                  await profilePhotoSyncCoordinator.pending() == nil
            else { return }
            profilePhotoSyncState = .synced
            status = "Profile photo updated everywhere"
            scheduleSync()
        case let .superseded(profile):
            // The response is still canonical server state, but a newer local intent owns the
            // optimistic overlay and its pending status.
            guard let session = storedSession?.session,
                  session.accountId == profile.accountId else { return }
            let generation = accountSessionGeneration
            let expectedStore = localStore
            await acceptCanonicalProfile(
                profile,
                accountId: session.accountId,
                deviceId: session.deviceId,
                token: session.token,
                generation: generation,
                store: expectedStore
            )
            guard generation == accountSessionGeneration,
                  storedSession?.session == session,
                  Self.store(expectedStore, matches: localStore) else { return }
            scheduleOutboxRetry()
        case let .retrying(message, delay):
            profilePhotoSyncState = .failed(message)
            scheduleOutboxRetry(after: delay)
            BackgroundRuntimeCoordinator.shared.scheduleAppRefresh(
                earliestBeginDate: Date(timeIntervalSinceNow: delay)
            )
        case let .failed(message):
            profilePhotoSyncState = .failed(message)
        case .conflict:
            profilePhotoSyncState = .conflict
        }
    }

    func retryPendingOutbox() async {
        guard !retryInFlight else { return }
        guard let context = currentAccountOperationContext() else { return }
        let token = context.token
        let localStore = context.store

        retryInFlight = true
        outboxDrainHalted = false
        defer { retryInFlight = false }

        do {
            await productivitySyncCoordinator.bind(context)
            let preCreateReport = await productivitySyncCoordinator.drain(api: api)
            await publishProductivityDrainReport(preCreateReport, context: context)
            guard isCurrentAccountOperation(context) else { return }
            await retryPendingScheduledCreates(context: context)
            guard !outboxDrainHalted, isCurrentAccountOperation(context) else { return }
            // A successful replay can turn an uncertain local create into a canonical schedule.
            // Drain again so its queued cancellation wins immediately in the same retry pass.
            let postCreateReport = await productivitySyncCoordinator.drain(api: api)
            await publishProductivityDrainReport(postCreateReport, context: context)
            guard isCurrentAccountOperation(context) else { return }
            await retryPendingProfilePhotoCommit()
            guard !outboxDrainHalted, isCurrentAccountOperation(context) else { return }
            await retryPendingGroupCreations(token: token, localStore: localStore)
            guard !outboxDrainHalted else { return }
            await retryPendingGroupMutations()
            guard !outboxDrainHalted else { return }
            await retryPendingDialogPreferences()
            guard !outboxDrainHalted else { return }
            let items = try await localStore.pendingOutboxReady(
                includeCloudDraftDependencies: capabilities.contains(.cloudDrafts)
            )
            for item in items {
                try Task.checkCancellation()
                if item.draftConsumeOperationId != nil {
                    let result = await draftSyncCoordinator.flush(
                        dialogId: item.dialogId,
                        force: true
                    )
                    guard await acceptDraftFlushResult(result) else {
                        return
                    }
                }
                try await localStore.markRetrying(clientMsgId: item.clientMsgId)
                if activeDialogId == item.dialogId {
                    await loadLocalLines(dialogId: item.dialogId)
                }
                await refreshDialogs()

                do {
                    try await sendOutboxItem(item, token: token)
                } catch {
                    if let apiError = error as? CloudAPIError,
                       apiError.code == "invalid_reply_target",
                       await recoverTextSendAfterInvalidReply(clientMsgId: item.clientMsgId) {
                        continue
                    }
                    let disposition = cloudOperationFailureDisposition(
                        error, serverAdvertisesFeature: capabilities.contains(.replies)
                    )
                    if case let .transient(retryAfter) = disposition {
                        let delay = retryAfter ?? retryDelay(forRetryCount: item.retryCount + 1)
                        try? await localStore.markFailed(clientMsgId: item.clientMsgId, retryAfter: delay)
                        publishTransportFailure(error)
                        return
                    } else if case .authenticationRequired = disposition {
                        try? await localStore.markFailed(
                            clientMsgId: item.clientMsgId,
                            retryAfter: 30
                        )
                        return
                    } else {
                        try? await localStore.markFailed(clientMsgId: item.clientMsgId, terminal: true)
                        presentNotice("Message was not sent", message: error.localizedDescription)
                    }
                    if activeDialogId == item.dialogId {
                        await loadLocalLines(dialogId: item.dialogId)
                    }
                    await refreshDialogs()
                }
            }
        } catch {
            status = "Outbox retry failed: \(error.localizedDescription)"
            return
        }
        await retryMediaTransfers()
        guard !outboxDrainHalted else { return }
        await retryPendingMediaGroups()
    }

    func publishProductivityDrainReport(
        _ report: CloudProductivityDrainReport,
        context: AccountOperationContext
    ) async {
        guard isCurrentAccountOperation(context) else { return }
        if report.foldersChanged,
           let snapshot = try? await context.store.effectiveChatFolderSnapshot(
            accountId: context.accountId
           ), isCurrentAccountOperation(context) {
            chatFolders = snapshot.folders.sorted { $0.position < $1.position }
            chatFolderCollectionRevision = snapshot.collectionRevision
        }
        if report.schedulesChanged,
           let deliveries = try? await context.store.scheduledDeliveries(
            accountId: context.accountId
           ), isCurrentAccountOperation(context) {
            scheduledDeliveries = deliveries.sorted { $0.deliverAt < $1.deliverAt }
        }
        if pendingProductivityTerminalNotice == nil,
           let failure = report.terminalErrors.first,
           isCurrentAccountOperation(context) {
            let notice = Notice(
                title: "A saved change could not be synced",
                message: failure.message
            )
            pendingProductivityTerminalNotice = (notice.id, failure)
            operationNotice = notice
        } else if pendingProductivityTerminalNotice == nil,
                  operationNotice == nil,
                  let message = report.errors.first,
                  isCurrentAccountOperation(context) {
            presentNotice("A saved change could not be synced", message: message)
        }
    }

    private func retryPendingScheduledCreates(
        context: AccountOperationContext
    ) async {
        guard capabilities.contains(.scheduledDelivery),
              isCurrentAccountOperation(context) else { return }
        let accountId = context.accountId
        let token = context.token
        let localStore = context.store
        let pending: [PendingScheduledCreate]
        do {
            pending = try await localStore.pendingScheduledCreatesReady(accountId: accountId)
            guard isCurrentAccountOperation(context) else { return }
        } catch {
            guard isCurrentAccountOperation(context) else { return }
            status = "Scheduled messages paused: \(error.localizedDescription)"
            return
        }
        for item in pending {
            guard !Task.isCancelled,
                  isCurrentAccountOperation(context) else { return }
            let wasPreviouslyAttempted = item.attemptedAt != nil
            do {
                // Persist this before the HTTP commit point. A later local cancel may discard only
                // creates that are known never to have reached the network.
                try await localStore.markScheduledCreateAttempted(
                    scheduleId: item.request.scheduleId,
                    accountId: accountId
                )
                guard isCurrentAccountOperation(context) else { return }
                let response = try await api.createScheduledDelivery(
                    persistedBody: item.requestData,
                    token: token
                )
                guard isCurrentAccountOperation(context) else { return }
                try await localStore.acknowledgeScheduledCreate(response, accountId: accountId)
                guard isCurrentAccountOperation(context) else { return }
                await clearDraftAfterScheduledAcknowledgement(
                    dialogId: item.request.dialogId,
                    operationId: item.draftOperationId,
                    accountId: accountId,
                    localStore: localStore
                )
                guard isCurrentAccountOperation(context) else { return }
                scheduledDeliveries.removeAll {
                    $0.scheduleId == response.scheduledDelivery.scheduleId
                }
                scheduledDeliveries.append(response.scheduledDelivery)
                scheduledDeliveries.sort { $0.deliverAt < $1.deliverAt }
                status = String(localized: "Message scheduled on server")
            } catch is CancellationError {
                return
            } catch {
                guard isCurrentAccountOperation(context) else { return }
                let disposition = cloudOperationFailureDisposition(
                    error,
                    serverAdvertisesFeature: capabilities.contains(.scheduledDelivery)
                )
                switch disposition {
                case let .transient(retryAfter):
                    outboxDrainHalted = true
                    let delay = retryAfter ?? retryDelay(forRetryCount: item.retryCount + 1)
                    try? await localStore.deferScheduledCreate(
                        scheduleId: item.request.scheduleId,
                        accountId: accountId,
                        after: delay,
                        error: error.localizedDescription
                    )
                    guard isCurrentAccountOperation(context) else { return }
                    status = String(localized: "Waiting for connection — not scheduled yet")
                    publishTransportFailure(error)
                case .authenticationRequired:
                    outboxDrainHalted = true
                    try? await localStore.deferScheduledCreate(
                        scheduleId: item.request.scheduleId,
                        accountId: accountId,
                        after: 30,
                        error: "Sign in required"
                    )
                    guard isCurrentAccountOperation(context) else { return }
                case .unsupportedServer:
                    // A mixed-version node or disabled route cannot prove that an earlier attempt
                    // did not commit. Keep replaying the original bytes so cancellation can resolve
                    // the accepted schedule instead of orphaning it.
                    outboxDrainHalted = true
                    try? await localStore.deferScheduledCreate(
                        scheduleId: item.request.scheduleId,
                        accountId: accountId,
                        after: 300,
                        error: error.localizedDescription
                    )
                    guard isCurrentAccountOperation(context) else { return }
                    status = String(localized: "Scheduled-message sync is waiting for server support")
                case .permanent:
                    if cloudScheduledCreateCanTerminalizePermanentFailure(
                        wasPreviouslyAttempted: wasPreviouslyAttempted
                    ) {
                        try? await localStore.deferScheduledCreate(
                            scheduleId: item.request.scheduleId,
                            accountId: accountId,
                            after: 0,
                            error: error.localizedDescription,
                            terminal: true
                        )
                        guard isCurrentAccountOperation(context) else { return }
                        presentNotice(
                            "Message was not scheduled",
                            message: "The saved draft was kept. \(error.localizedDescription)"
                        )
                    } else {
                        outboxDrainHalted = true
                        try? await localStore.deferScheduledCreate(
                            scheduleId: item.request.scheduleId,
                            accountId: accountId,
                            after: 300,
                            error: error.localizedDescription
                        )
                        guard isCurrentAccountOperation(context) else { return }
                        status = String(
                            localized: "Scheduled-message sync is waiting for server reconciliation"
                        )
                    }
                }
                if outboxDrainHalted { return }
            }
        }
    }

    private func retryPendingGroupCreations(token: String, localStore: CloudLocalStore) async {
        guard capabilities.contains(.groups) else { return }
        let creations: [PendingGroupCreation]
        do {
            creations = try await localStore.pendingGroupCreationsReady()
        } catch {
            status = "Group retry paused: \(error.localizedDescription)"
            return
        }

        for creation in creations {
            if Task.isCancelled || storedSession?.session.token != token { return }
            do {
                try await localStore.markGroupCreating(groupId: creation.groupId)
                let envelope = try await api.createGroup(
                    id: creation.groupId,
                    title: creation.title,
                    memberIds: creation.memberIds,
                    token: token
                )
                try await localStore.applyGroupEnvelope(envelope)
                if activeDialogId == creation.groupId {
                    await loadLocalLines(dialogId: creation.groupId)
                }
                await refreshDialogs()
                scheduleSync()
            } catch is CancellationError {
                return
            } catch {
                let disposition = cloudOperationFailureDisposition(
                    error,
                    serverAdvertisesFeature: capabilities.contains(.groups)
                )
                switch disposition {
                case let .transient(retryAfter):
                    outboxDrainHalted = true
                    let delay = retryAfter ?? retryDelay(forRetryCount: creation.retryCount + 1)
                    try? await localStore.retryGroupCreation(
                        groupId: creation.groupId,
                        after: delay,
                        error: error.localizedDescription
                    )
                    publishTransportFailure(error)
                case .authenticationRequired:
                    outboxDrainHalted = true
                    try? await localStore.retryGroupCreation(
                        groupId: creation.groupId,
                        after: 30,
                        error: "Sign in required"
                    )
                case .unsupportedServer, .permanent:
                    try? await localStore.failGroupCreation(
                        groupId: creation.groupId,
                        error: error.localizedDescription
                    )
                    presentNotice(
                        "Group was not created",
                        message: "Your draft is saved. Open it and choose Retry when you are ready."
                    )
                }
                await refreshDialogs()
                if outboxDrainHalted { return }
            }
        }
    }

    func retryPendingGroupMutations() async {
        guard capabilities.contains(.groups),
              !isSessionTeardownInProgress,
              let accountId = storedSession?.session.accountId,
              let token = storedSession?.session.token,
              let localStore else { return }
        let generation = accountSessionGeneration
        let mutations: [PendingGroupMutation]
        do {
            mutations = try await localStore.pendingGroupMutationsReady()
        } catch {
            status = "Group changes paused: \(error.localizedDescription)"
            return
        }
        for mutation in mutations {
            if Task.isCancelled
                || isSessionTeardownInProgress
                || accountSessionGeneration != generation
                || storedSession?.session.accountId != accountId
                || storedSession?.session.token != token {
                return
            }
            do {
                guard
                    let data = mutation.payloadJSON.data(using: .utf8),
                    let payload = try? JSONDecoder().decode(GroupMutationPayload.self, from: data)
                else { throw CloudAppModelError.invalidGroupMutation }
                try await localStore.markGroupMutationAttempted(
                    clientMutationId: mutation.clientMutationId
                )
                guard
                    !Task.isCancelled,
                    !isSessionTeardownInProgress,
                    accountSessionGeneration == generation,
                    storedSession?.session.accountId == accountId,
                    storedSession?.session.token == token
                else { return }
                let envelope: CloudGroupEnvelope?
                switch mutation.operation {
                case "update_title":
                    guard let title = payload.title else { throw CloudAppModelError.invalidGroupMutation }
                    envelope = try await api.updateGroup(
                        id: mutation.dialogId,
                        title: title,
                        clientMutationId: mutation.clientMutationId,
                        token: token
                    )
                case "notifications":
                    guard let mode = payload.mode else { throw CloudAppModelError.invalidGroupMutation }
                    envelope = try await api.updateGroupNotifications(
                        id: mutation.dialogId,
                        mode: mode,
                        clientMutationId: mutation.clientMutationId,
                        token: token
                    )
                case "add_members":
                    guard let memberIds = payload.memberIds else {
                        throw CloudAppModelError.invalidGroupMutation
                    }
                    envelope = try await api.addGroupMembers(
                        id: mutation.dialogId,
                        memberIds: memberIds,
                        clientMutationId: mutation.clientMutationId,
                        token: token
                    )
                case "remove_member":
                    guard let accountId = payload.accountId else {
                        throw CloudAppModelError.invalidGroupMutation
                    }
                    envelope = try await api.removeGroupMember(
                        groupId: mutation.dialogId,
                        accountId: accountId,
                        clientMutationId: mutation.clientMutationId,
                        token: token
                    )
                case "change_role":
                    guard let accountId = payload.accountId, let role = payload.role else {
                        throw CloudAppModelError.invalidGroupMutation
                    }
                    envelope = try await api.changeGroupMemberRole(
                        groupId: mutation.dialogId,
                        accountId: accountId,
                        role: role,
                        clientMutationId: mutation.clientMutationId,
                        token: token
                    )
                case "transfer_owner":
                    guard let accountId = payload.accountId else {
                        throw CloudAppModelError.invalidGroupMutation
                    }
                    envelope = try await api.transferGroupOwner(
                        id: mutation.dialogId,
                        accountId: accountId,
                        clientMutationId: mutation.clientMutationId,
                        token: token
                    )
                case "leave":
                    _ = try await api.leaveGroup(
                        id: mutation.dialogId,
                        successorAccountId: payload.successorAccountId,
                        clientMutationId: mutation.clientMutationId,
                        token: token
                    )
                    envelope = nil
                default:
                    throw CloudAppModelError.invalidGroupMutation
                }
                guard
                    !Task.isCancelled,
                    !isSessionTeardownInProgress,
                    accountSessionGeneration == generation,
                    storedSession?.session.accountId == accountId,
                    storedSession?.session.token == token
                else { return }
                if let envelope {
                    try await localStore.applyGroupEnvelope(envelope)
                }
                try await localStore.completeGroupMutation(
                    clientMutationId: mutation.clientMutationId
                )
                if mutation.operation == "leave", activeDialogId == mutation.dialogId {
                    activeDialogId = nil
                    lines = []
                }
                await refreshDialogs()
                scheduleSync()
            } catch is CancellationError {
                return
            } catch {
                guard
                    !Task.isCancelled,
                    !isSessionTeardownInProgress,
                    accountSessionGeneration == generation,
                    storedSession?.session.accountId == accountId,
                    storedSession?.session.token == token
                else { return }
                if let apiError = error as? CloudAPIError, apiError.status == 410 {
                    try? await localStore.revokeGroupAccess(
                        dialogId: mutation.dialogId,
                        reason: "You no longer have access to this group."
                    )
                    await cancelMediaTransfers(forRevokedDialogs: [mutation.dialogId])
                }
                let disposition = cloudOperationFailureDisposition(
                    error,
                    serverAdvertisesFeature: capabilities.contains(.groups)
                )
                switch disposition {
                case let .transient(retryAfter):
                    outboxDrainHalted = true
                    let delay = retryAfter ?? retryDelay(forRetryCount: mutation.retryCount + 1)
                    try? await localStore.failGroupMutation(
                        clientMutationId: mutation.clientMutationId,
                        retryAfter: delay,
                        error: error.localizedDescription,
                        terminal: false
                    )
                    publishTransportFailure(error)
                    await refreshDialogs()
                    return
                case .authenticationRequired:
                    outboxDrainHalted = true
                    try? await localStore.failGroupMutation(
                        clientMutationId: mutation.clientMutationId,
                        retryAfter: 30,
                        error: "Sign in required",
                        terminal: false
                    )
                    await refreshDialogs()
                    return
                case .unsupportedServer, .permanent:
                    try? await localStore.failGroupMutation(
                        clientMutationId: mutation.clientMutationId,
                        retryAfter: nil,
                        error: error.localizedDescription,
                        terminal: true
                    )
                    presentNotice("Group change failed", message: error.localizedDescription)
                }
                await refreshDialogs()
                if outboxDrainHalted { return }
            }
        }
    }

    func sendOutboxItem(_ item: PendingOutboxItem, token: String) async throws {
        let response: SendMessageResponse
        if let sourceDialogId = item.forwardedFromDialogId, let sourceMsgId = item.forwardedFromMsgId {
            response = try await api.forwardMessage(
                dialogId: item.dialogId,
                clientMsgId: item.clientMsgId,
                sourceDialogId: sourceDialogId,
                sourceMsgId: sourceMsgId,
                token: token
            )
        } else {
            response = try await api.sendMessage(
                dialogId: item.dialogId,
                clientMsgId: item.clientMsgId,
                body: item.body,
                replyToMsgId: item.replyToMsgId,
                mentions: item.mentions,
                draftConsumeOperationId: capabilities.contains(.cloudDrafts)
                    ? item.draftConsumeOperationId
                    : nil,
                silent: item.silent,
                token: token
            )
        }

        if let localStore, let accountId = storedSession?.session.accountId {
            try await localStore.markSent(response, senderAccountId: accountId)
            if activeDialogId == response.dialogId {
                await loadLocalLines(dialogId: response.dialogId)
            }
            await refreshDialogs()
        } else if let index = lines.firstIndex(where: { $0.clientMsgId == item.clientMsgId }) {
            lines[index].dialogId = response.dialogId
            lines[index].msgId = response.msgId
            lines[index].delivery = .sent
        }

        status = response.duplicate ? "Send confirmed" : "Sent"
        scheduleSync()
    }

    func nextOutboxRetryDelay() async -> TimeInterval? {
        guard let localStore else { return nil }
        let groupDelay = try? await localStore.nextPendingGroupCreationDelay()
        let textDelay = try? await localStore.nextPendingOutboxDelay(
            includeCloudDraftDependencies: capabilities.contains(.cloudDrafts)
        )
        let mediaDelay = try? await localStore.nextMediaTransferDelay(
            includeCloudDraftDependencies: capabilities.contains(.cloudDrafts)
        )
        let mediaGroupDelay = capabilities.contains(.mediaGroups)
            ? try? await localStore.nextMediaGroupSendDelay()
            : nil
        let mutationDelay = try? await localStore.nextMessageMutationDelay()
        let groupMutationDelay = try? await localStore.nextPendingGroupMutationDelay()
        let scheduledCreateDelay: TimeInterval?
        let productivityDelay: TimeInterval?
        if let accountId = storedSession?.session.accountId {
            if capabilities.contains(.scheduledDelivery) {
                let storedDelay = try? await localStore.nextScheduledCreateRetryDelay(
                    accountId: accountId
                )
                scheduledCreateDelay = cloudScheduledCreateRetryDelay(
                    storedDelay,
                    serverAdvertisesFeature: true
                )
            } else {
                // Dormant durable creates are reactivated by the next capability refresh. They must
                // not schedule a zero-delay outbox loop while the route is intentionally absent.
                scheduledCreateDelay = cloudScheduledCreateRetryDelay(
                    nil,
                    serverAdvertisesFeature: false
                )
            }
            productivityDelay = try? await localStore.nextProductivityMutationRetryDelay(
                accountId: accountId
            )
        } else {
            scheduledCreateDelay = nil
            productivityDelay = nil
        }
        var preferenceDelay: TimeInterval?
        if capabilities.contains(.chatOrganization),
           let accountId = storedSession?.session.accountId {
            preferenceDelay = try? await localStore.nextDialogPreferenceRetryDelay(
                accountId: accountId
            )
            if preferenceDelay == 0,
               await dialogPreferencesCoordinator.hasActiveDrain {
                // A rapid coalesced toggle can become ready while the prior HTTP request is still
                // in flight. Avoid a zero-delay retry loop; the active drain will pick it up.
                preferenceDelay = 1
            }
        } else {
            preferenceDelay = nil
        }
        return [
            groupDelay, groupMutationDelay, preferenceDelay,
            scheduledCreateDelay, productivityDelay,
            textDelay, mediaDelay, mediaGroupDelay, mutationDelay,
        ].compactMap { $0 }.min()
    }

    func retryDelay(forRetryCount retryCount: Int) -> TimeInterval {
        min(30, pow(2, Double(max(0, retryCount - 1))))
    }

    func upsert(_ message: CloudMessage) {
        if message.state == "deleted_for_all" {
            lines.removeAll {
                $0.clientMsgId == message.clientMsgId
                    || ($0.dialogId == message.dialogId && $0.msgId == message.msgId)
            }
            return
        }
        let mine = message.senderAccountId == storedSession?.session.accountId
        if let index = lines.firstIndex(where: { $0.clientMsgId == message.clientMsgId }) {
            lines[index].dialogId = message.dialogId
            lines[index].msgId = message.msgId
            lines[index].senderAccountId = message.senderAccountId
            lines[index].senderDisplayName = nil
            lines[index].kind = message.kind
            lines[index].serviceType = message.serviceType
            lines[index].serviceData = message.serviceData
            lines[index].text = message.text
            lines[index].replyToMsgId = message.replyToMsgId
            lines[index].reactions = Self.reactionBadges(message.reactions)
            lines[index].myReaction = message.reactions.first(where: { $0.accountId == storedSession?.session.accountId })?.emoji
            lines[index].forwardedFromAccountId = message.forwardedFromAccountId
            lines[index].forwardedFromDialogId = message.forwardedFromDialogId
            lines[index].forwardedFromMsgId = message.forwardedFromMsgId
            lines[index].isForwarded = message.isForwarded
            lines[index].editVersion = message.editVersion
            lines[index].isEdited = message.editVersion > 0 && message.state == "visible"
            lines[index].isDeleted = message.state == "deleted_for_all"
            lines[index].media = message.media
            lines[index].mediaGroupId = message.mediaGroupId
            lines[index].mediaGroupIndex = message.mediaGroupIndex
            lines[index].mediaGroupCount = message.mediaGroupCount
            lines[index].mine = mine
            lines[index].delivery = .sent
            lines[index].timestamp = message.serverTs
            return
        }
        lines.append(Line(
            id: message.id,
            dialogId: message.dialogId,
            msgId: message.msgId,
            clientMsgId: message.clientMsgId,
            senderAccountId: message.senderAccountId,
            text: message.text,
            kind: message.kind,
            serviceType: message.serviceType,
            serviceData: message.serviceData,
            mine: mine,
            delivery: .sent,
            timestamp: message.serverTs,
            replyToMsgId: message.replyToMsgId,
            reactions: Self.reactionBadges(message.reactions),
            myReaction: message.reactions.first(where: { $0.accountId == storedSession?.session.accountId })?.emoji,
            forwardedFromAccountId: message.forwardedFromAccountId,
            forwardedFromDialogId: message.forwardedFromDialogId,
            forwardedFromMsgId: message.forwardedFromMsgId,
            isForwarded: message.isForwarded,
            editVersion: message.editVersion,
            isEdited: message.editVersion > 0 && message.state == "visible",
            isDeleted: message.state == "deleted_for_all",
            media: message.media,
            mediaGroupId: message.mediaGroupId,
            mediaGroupIndex: message.mediaGroupIndex,
            mediaGroupCount: message.mediaGroupCount
        ))
        lines.sort {
            switch ($0.msgId, $1.msgId) {
            case let (lhs?, rhs?): return lhs < rhs
            case (.some, nil): return true
            case (nil, .some): return false
            case (nil, nil): return $0.id < $1.id
            }
        }
    }

    func edit(_ line: Line, text: String) async {
        guard
            let localStore,
            let dialogId = line.dialogId,
            let msgId = line.msgId
        else { return }
        let targetKey = "\(dialogId):\(msgId)"
        guard mutationTargetsBeingQueued.insert(targetKey).inserted else { return }
        defer { mutationTargetsBeingQueued.remove(targetKey) }
        do {
            let mutationId = UUID().uuidString.lowercased()
            try await localStore.enqueueMessageMutation(
                clientMutationId: mutationId,
                operation: "edit",
                dialogId: dialogId,
                msgId: msgId,
                body: text,
                expectedEditVersion: line.editVersion
            )
            restoreUnderlyingDraftComposer()
            await loadLocalLines(dialogId: dialogId)
            await processMessageMutation(PendingMessageMutation(
                clientMutationId: mutationId, operation: "edit", dialogId: dialogId,
                msgId: msgId, body: text, expectedEditVersion: line.editVersion,
                emoji: nil, retryCount: 0, nextRetryAt: nil, lastError: nil
            ))
        } catch {
            status = "Edit failed: \(error.localizedDescription)"
            presentNotice("Could not edit message", message: error.localizedDescription)
        }
    }
}
