import Foundation
import Observation
import UIKit

extension CloudAppModel {
    func retryPendingMediaGroups() async {
        guard let localStore else { return }
        do {
            await reconcileMediaGroupCleanups(localStore: localStore)
            guard capabilities.contains(.mediaGroups) else { return }
            for group in try await localStore.pendingMediaGroupSendsReady() {
                try Task.checkCancellation()
                guard await processMediaGroupSend(group) else { break }
            }
        } catch is CancellationError {
            return
        } catch {
            status = "Grouped send retry failed: \(error.localizedDescription)"
        }
    }

    @discardableResult
    func processMediaGroupSend(_ group: PendingMediaGroupSend) async -> Bool {
        guard !mediaGroupSendsInFlight.contains(group.clientGroupId) else { return false }
        guard
            capabilities.contains(.mediaGroups),
            let token = storedSession?.session.token,
            let accountId = storedSession?.session.accountId,
            accountId == group.accountId,
            let localStore
        else { return false }
        mediaGroupSendsInFlight.insert(group.clientGroupId)
        defer { mediaGroupSendsInFlight.remove(group.clientGroupId) }
        do {
            if let operationId = group.draftConsumeOperationId {
                guard capabilities.contains(.cloudDrafts) else {
                    await refreshServerCapabilities()
                    return false
                }
                let result = await draftSyncCoordinator.flushDependency(operationId: operationId)
                guard await acceptDraftFlushResult(result) else {
                    scheduleOutboxRetry(after: 2)
                    return false
                }
            }
            let response = try await api.sendMediaGroup(
                dialogId: group.dialogId,
                clientGroupId: group.clientGroupId,
                items: group.payload.items.map {
                    MediaGroupItemRequest(clientMsgId: $0.clientMsgId, mediaId: $0.mediaId)
                },
                caption: group.payload.caption,
                replyToMsgId: group.payload.replyToMsgId,
                mentions: group.payload.mentions,
                draftConsumeOperationId: capabilities.contains(.cloudDrafts)
                    ? group.draftConsumeOperationId
                    : nil,
                silent: group.payload.silent,
                token: token
            )
            try await localStore.completeMediaGroupSend(
                response,
                senderAccountId: accountId,
                attemptedOperationId: group.draftConsumeOperationId
            )
            await reconcileMediaGroupCleanups(localStore: localStore)
            if activeDialogId == group.dialogId { await loadLocalLines(dialogId: group.dialogId) }
            await refreshDialogs()
            scheduleSync()
            status = response.duplicate ? "Grouped send confirmed" : "Sent"
            return true
        } catch is CancellationError {
            return false
        } catch {
            if let apiError = error as? CloudAPIError, apiError.code == "invalid_reply_target" {
                if (try? await localStore.restoreMediaGroupAsDraftWithoutReply(group)) != nil {
                    _ = await draftSyncCoordinator.flush(dialogId: group.dialogId)
                    if activeDialogId == group.dialogId {
                        await loadLocalLines(dialogId: group.dialogId)
                    }
                    await refreshDialogs()
                    presentNotice(
                        "Original message unavailable",
                        message: "The reply was removed. Every attachment is still in your draft."
                    )
                }
                return true
            }
            let disposition = cloudOperationFailureDisposition(
                error,
                serverAdvertisesFeature: capabilities.contains(.mediaGroups)
            )
            switch disposition {
            case let .transient(retryAfter):
                let delay = retryAfter ?? retryDelay(forRetryCount: group.retryCount + 1)
                try? await localStore.markMediaGroupSendFailed(
                    clientGroupId: group.clientGroupId,
                    error: error.localizedDescription,
                    retryAfter: delay,
                    terminal: false
                )
                publishTransportFailure(error)
                scheduleOutboxRetry(after: delay)
            case .authenticationRequired:
                try? await localStore.markMediaGroupSendFailed(
                    clientGroupId: group.clientGroupId,
                    error: "Sign in required",
                    retryAfter: 30,
                    terminal: false
                )
            case .unsupportedServer:
                await refreshServerCapabilities()
                return false
            case .permanent:
                try? await localStore.markMediaGroupSendFailed(
                    clientGroupId: group.clientGroupId,
                    error: error.localizedDescription,
                    retryAfter: nil,
                    terminal: true
                )
                presentNotice("Grouped message was not sent", message: error.localizedDescription)
            }
            if activeDialogId == group.dialogId { await loadLocalLines(dialogId: group.dialogId) }
            await refreshDialogs()
            return false
        }
    }

    private func reconcileMediaGroupCleanups(localStore: CloudLocalStore) async {
        let cleanups = (try? await localStore.pendingMediaGroupCleanups()) ?? []
        for cleanup in cleanups {
            if Task.isCancelled { return }
            let transfers = (try? await localStore.mediaTransfers(ids: cleanup.transferIds)) ?? []
            for transfer in transfers {
                let promoted = await mediaEngine.finishUpload(transfer, localStore: localStore)
                if !promoted { await mediaEngine.discardTransfer(transfer) }
            }
            try? await localStore.finalizeMediaGroupCleanup(cleanup)
        }
    }

    func retryMediaTransfers() async {
        guard let localStore else { return }
        do {
            for transfer in try await localStore.mediaTransfersReady(
                includeCloudDraftDependencies: capabilities.contains(.cloudDrafts)
            ) {
                try Task.checkCancellation()
                await runMediaTransfer(transfer)
                if outboxDrainHalted { return }
            }
        } catch is CancellationError {
            return
        } catch {
            status = "Media retry failed: \(error.localizedDescription)"
        }
    }

    func runMediaTransfer(_ transfer: MediaTransferRecord) async {
        if let existing = mediaTransferTasks[transfer.transferId] {
            await existing.value
            return
        }
        let task = Task { [weak self] in
            guard let self else { return }
            await self.processMediaTransfer(transfer)
        }
        mediaTransferTasks[transfer.transferId] = task
        mediaTransferDialogIds[transfer.transferId] = transfer.dialogId
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        mediaTransferTasks.removeValue(forKey: transfer.transferId)
        mediaTransferDialogIds.removeValue(forKey: transfer.transferId)
    }

    private func processMediaTransfer(_ initial: MediaTransferRecord) async {
        guard !mediaTransfersInFlight.contains(initial.transferId) else { return }
        guard
            let token = storedSession?.session.token,
            let accountId = storedSession?.session.accountId,
            let localStore
        else { return }
        let generation = savedMessagesSessionGeneration
        guard isCurrentSavedMessagesSession(
            accountId: accountId,
            token: token,
            store: localStore,
            generation: generation
        ), (try? await localStore.isDialogAccessRevoked(dialogId: initial.dialogId)) == false
        else { return }
        mediaTransfersInFlight.insert(initial.transferId)
        defer { mediaTransfersInFlight.remove(initial.transferId) }
        do {
            try Task.checkCancellation()
            let mediaId: String
            var draftReadyCommitted = false
            if initial.state == "ready_to_send", let existing = initial.mediaId {
                mediaId = existing
            } else {
                let useMultipartV2 = capabilities.contains(.multipartMedia)
                let upload: @Sendable () async throws -> String = { [weak self] in
                    guard let self else { throw CancellationError() }
                    return try await self.mediaEngine.upload(
                        transfer: initial, token: token, localStore: localStore,
                        useMultipartV2: useMultipartV2,
                        progress: { [weak self] progress in
                            if initial.purpose == "draft" {
                                try? await localStore.updateDraftAttachment(
                                    transferId: initial.transferId,
                                    mediaId: nil,
                                    state: "uploading",
                                    progress: progress,
                                    error: nil
                                )
                            } else {
                                await MainActor.run {
                                    guard let self else { return }
                                    if let index = self.lines.firstIndex(
                                        where: { $0.clientMsgId == initial.clientMsgId }
                                    ) {
                                        self.lines[index].transferProgress = progress
                                        self.lines[index].transferStage =
                                            progress >= 0.97 ? .finalizing : .uploading
                                    }
                                    if self.activeDialogId == initial.dialogId {
                                        self.composerMode = .uploading(
                                            Self.demoAttachment(
                                                kind: initial.kind,
                                                fileName: initial.fileName,
                                                byteSize: initial.byteSize,
                                                durationMs: initial.durationMs
                                            ),
                                            progress: progress
                                        )
                                    }
                                }
                            }
                        }
                    )
                }
                if initial.purpose == "draft" {
                    mediaId = try await draftSyncCoordinator.withAttachmentUploadPermit(upload)
                } else {
                    mediaId = try await upload()
                }
                if initial.purpose == "draft" {
                    // This single SQLCipher transaction marks both the transfer and attachment
                    // ready and rewrites the coalesced draft mutation. There is no crash boundary
                    // where a reopened transfer is ready while its draft chip remains uploading.
                    try await localStore.updateDraftAttachment(
                        transferId: initial.transferId,
                        mediaId: mediaId,
                        state: "ready",
                        progress: 1,
                        error: nil
                    )
                    draftReadyCommitted = true
                } else {
                    try await localStore.updateMediaTransfer(
                        transferId: initial.transferId, mediaId: mediaId,
                        uploadOffset: initial.byteSize, state: "ready_to_send", error: nil
                    )
                }
            }
            guard let ready = try await localStore.mediaTransfer(id: initial.transferId) else {
                throw CloudAppModelError.localStoreUnavailable
            }
            if ready.purpose == "profile_photo" {
                try await profilePhotoSyncCoordinator.markUploaded(
                    transferId: ready.transferId,
                    mediaId: mediaId
                )
                await handleProfilePhotoCommitResult(
                    await profilePhotoSyncCoordinator.commitReady()
                )
                return
            }
            if ready.purpose == "draft" {
                if !draftReadyCommitted {
                    // Repairs a row persisted by an older build at the former two-transaction
                    // boundary, while using the same atomic operation for all new completions.
                    try await localStore.updateDraftAttachment(
                        transferId: ready.transferId,
                        mediaId: mediaId,
                        state: "ready",
                        progress: 1,
                        error: nil
                    )
                }
                _ = await draftSyncCoordinator.flush(dialogId: ready.dialogId)
                status = "Attachment ready"
                return
            }
            if ready.purpose == "group_send" {
                scheduleOutboxRetry()
                return
            }
            if ready.purpose == "group_photo" {
                let envelope = try await api.updateGroup(
                    id: ready.dialogId,
                    photoMediaId: mediaId,
                    clientMutationId: ready.transferId,
                    token: token
                )
                try Task.checkCancellation()
                guard
                    isCurrentSavedMessagesSession(
                        accountId: accountId,
                        token: token,
                        store: localStore,
                        generation: generation
                    ),
                    (try? await localStore.isDialogAccessRevoked(
                        dialogId: ready.dialogId
                    )) == false
                else { throw CancellationError() }
                try await localStore.applyGroupEnvelope(envelope)
                let promotedToCache = await mediaEngine.finishUpload(ready, localStore: localStore)
                try await localStore.completeMediaTransfer(transferId: ready.transferId)
                if !promotedToCache {
                    await mediaEngine.discardTransfer(ready)
                }
                await refreshDialogs()
                if activeDialogId == ready.dialogId {
                    await loadGroupProfile(dialogId: ready.dialogId)
                }
                scheduleSync()
                status = "Group photo updated"
                return
            }
            if let operationId = ready.draftOperationId {
                guard capabilities.contains(.cloudDrafts) else {
                    await refreshServerCapabilities()
                    return
                }
                let result = await draftSyncCoordinator.flushDependency(operationId: operationId)
                guard await acceptDraftFlushResult(result) else {
                    scheduleOutboxRetry(after: 2)
                    return
                }
            }
            try await localStore.insertSendingMedia(ready, senderAccountId: accountId)
            if activeDialogId == ready.dialogId { await loadLocalLines(dialogId: ready.dialogId) }
            try Task.checkCancellation()
            guard
                isCurrentSavedMessagesSession(
                    accountId: accountId,
                    token: token,
                    store: localStore,
                    generation: generation
                ),
                (try? await localStore.isDialogAccessRevoked(dialogId: ready.dialogId)) == false
            else { throw CancellationError() }
            // Once the idempotent send request begins it is the commit point. Hide the upload cancel
            // control so the UI never promises cancellation after the server may have committed.
            if activeComposerTransferId == ready.transferId {
                activeComposerTransferId = nil
                if case .uploading = composerMode { composerMode = .text }
            }
            let response = try await api.sendMediaMessage(
                dialogId: ready.dialogId, clientMsgId: ready.clientMsgId,
                body: ready.caption, mediaId: mediaId, replyToMsgId: ready.replyToMsgId,
                mentions: ready.mentions,
                draftConsumeOperationId: capabilities.contains(.cloudDrafts)
                    ? ready.draftOperationId
                    : nil,
                silent: ready.silent,
                token: token
            )
            try Task.checkCancellation()
            guard
                isCurrentSavedMessagesSession(
                    accountId: accountId,
                    token: token,
                    store: localStore,
                    generation: generation
                ),
                (try? await localStore.isDialogAccessRevoked(dialogId: ready.dialogId)) == false
            else { throw CancellationError() }
            try await localStore.markSent(response, senderAccountId: accountId)
            let promotedToCache = await mediaEngine.finishUpload(ready, localStore: localStore)
            try await localStore.completeMediaTransfer(transferId: ready.transferId)
            if !promotedToCache {
                await mediaEngine.discardTransfer(ready)
            }
            if activeDialogId == ready.dialogId, case .uploading = composerMode { composerMode = .text }
            if activeDialogId == ready.dialogId { await loadLocalLines(dialogId: ready.dialogId) }
            await refreshDialogs()
            scheduleSync()
            status = "Sent"
        } catch is CancellationError {
            let current = (try? await localStore.mediaTransfer(id: initial.transferId)) ?? initial
            await cancelMediaTransfer(current, token: token)
            if activeDialogId == initial.dialogId, case .uploading = composerMode { composerMode = .text }
        } catch {
            guard isCurrentSavedMessagesSession(
                accountId: accountId,
                token: token,
                store: localStore,
                generation: generation
            ), (try? await localStore.isDialogAccessRevoked(dialogId: initial.dialogId)) == false
            else { return }
            let current = try? await localStore.mediaTransfer(id: initial.transferId)
            if activeDialogId == initial.dialogId, case .uploading = composerMode { composerMode = .text }
            if initial.purpose == "profile_photo" {
                let disposition = cloudOperationFailureDisposition(
                    error,
                    serverAdvertisesFeature: capabilities.contains(.profilePhotos)
                )
                switch disposition {
                case let .transient(retryAfter):
                    let delay = retryAfter ?? retryDelay(forRetryCount: initial.retryCount + 1)
                    try? await localStore.updateMediaTransfer(
                        transferId: initial.transferId,
                        mediaId: current?.mediaId,
                        uploadOffset: current?.uploadOffset ?? initial.uploadOffset,
                        state: current?.mediaId == nil ? "pending" : "uploading",
                        error: error.localizedDescription,
                        retryAfter: delay
                    )
                    guard let mutation = try? await localStore.pendingProfilePhotoMutation(
                        accountId: accountId
                    ), mutation.transferId == initial.transferId else { return }
                    let failed = try? await localStore.failProfilePhotoUpload(
                        accountId: accountId,
                        clientMutationId: mutation.clientMutationId,
                        error: error.localizedDescription,
                        retryAfter: delay
                    )
                    guard failed == true else { return }
                    profilePhotoSyncState = .failed(error.localizedDescription)
                    scheduleOutboxRetry(after: delay)
                case .authenticationRequired:
                    return
                case .unsupportedServer:
                    await refreshServerCapabilities()
                    profilePhotoSyncState = .localOnly
                case .permanent:
                    try? await localStore.markMediaTerminal(
                        clientMsgId: initial.clientMsgId,
                        error: error.localizedDescription
                    )
                    guard let mutation = try? await localStore.pendingProfilePhotoMutation(
                        accountId: accountId
                    ), mutation.transferId == initial.transferId else { return }
                    let failed = try? await localStore.failProfilePhotoMutation(
                        accountId: accountId,
                        clientMutationId: mutation.clientMutationId,
                        error: error.localizedDescription,
                        retryAfter: nil,
                        terminal: true
                    )
                    guard failed == true else { return }
                    profilePhotoSyncState = .failed(error.localizedDescription)
                }
                return
            }
            if let apiError = error as? CloudAPIError,
               apiError.code == "invalid_reply_target",
               let current,
               current.draftOperationId != nil,
               (try? await localStore.restoreSingleMediaAsDraftWithoutReply(
                   current,
                   accountId: accountId
               )) != nil {
                _ = await draftSyncCoordinator.flush(dialogId: current.dialogId)
                if activeDialogId == current.dialogId {
                    await loadLocalLines(dialogId: current.dialogId)
                }
                await refreshDialogs()
                presentNotice(
                    "Original message unavailable",
                    message: "The reply was removed. Your attachment and caption are still in your draft."
                )
                return
            }
            if initial.purpose == "draft" {
                let disposition = cloudOperationFailureDisposition(
                    error,
                    serverAdvertisesFeature: capabilities.contains(.media)
                )
                switch disposition {
                case let .transient(retryAfter):
                    outboxDrainHalted = true
                    let delay = retryAfter ?? retryDelay(forRetryCount: initial.retryCount + 1)
                    try? await localStore.updateDraftAttachment(
                        transferId: initial.transferId,
                        mediaId: current?.mediaId,
                        state: "failed",
                        progress: current.map {
                            Double($0.uploadOffset) / Double(max(1, $0.byteSize))
                        } ?? 0,
                        error: error.localizedDescription,
                        retryAfter: delay
                    )
                    scheduleOutboxRetry(after: delay)
                case .authenticationRequired:
                    outboxDrainHalted = true
                    try? await localStore.updateDraftAttachment(
                        transferId: initial.transferId,
                        mediaId: current?.mediaId,
                        state: "failed",
                        progress: current.map {
                            Double($0.uploadOffset) / Double(max(1, $0.byteSize))
                        } ?? 0,
                        error: "Sign in required",
                        retryAfter: 30
                    )
                case .unsupportedServer:
                    outboxDrainHalted = true
                    await refreshServerCapabilities()
                    scheduleOutboxRetry(after: 30)
                case .permanent:
                    try? await localStore.updateDraftAttachment(
                        transferId: initial.transferId,
                        mediaId: current?.mediaId,
                        state: "terminal",
                        progress: 0,
                        error: error.localizedDescription
                    )
                }
                status = "Draft attachment upload failed: \(error.localizedDescription)"
                return
            }
            switch cloudOperationFailureDisposition(
                error, serverAdvertisesFeature: capabilities.contains(.media)
            ) {
            case let .transient(retryAfter):
                outboxDrainHalted = true
                let delay = retryAfter ?? retryDelay(forRetryCount: initial.retryCount + 1)
                try? await localStore.updateMediaTransfer(
                    transferId: initial.transferId, mediaId: current?.mediaId,
                    uploadOffset: current?.uploadOffset ?? initial.uploadOffset,
                    state: current?.mediaId == nil ? "pending" : "uploading",
                    error: error.localizedDescription, retryAfter: delay
                )
                publishTransportFailure(error)
                status = "Attachment queued for retry"
                scheduleOutboxRetry(after: delay)
            case .unsupportedServer:
                outboxDrainHalted = true
                await refreshServerCapabilities()
                scheduleOutboxRetry(after: 30)
            case .authenticationRequired:
                outboxDrainHalted = true
                try? await localStore.updateMediaTransfer(
                    transferId: initial.transferId,
                    mediaId: current?.mediaId,
                    uploadOffset: current?.uploadOffset ?? initial.uploadOffset,
                    state: current?.mediaId == nil ? "pending" : "ready_to_send",
                    error: "Sign in required",
                    retryAfter: 30
                )
            case .permanent:
                try? await localStore.markMediaTerminal(
                    clientMsgId: initial.clientMsgId, error: error.localizedDescription
                )
                presentNotice("Attachment was not sent", message: error.localizedDescription)
            }
            if activeDialogId == initial.dialogId { await loadLocalLines(dialogId: initial.dialogId) }
            await refreshDialogs()
        }
    }

    func cancelMediaTransfer(_ transfer: MediaTransferRecord, token: String) async {
        await mediaEngine.cancelUpload(transfer, token: token)
        try? await localStore?.cancelMediaTransfer(
            transferId: transfer.transferId, clientMsgId: transfer.clientMsgId
        )
        lines.removeAll { $0.clientMsgId == transfer.clientMsgId }
        if activeDialogId == transfer.dialogId { await loadLocalLines(dialogId: transfer.dialogId) }
        await refreshDialogs()
    }

    func recoverTextSendAfterInvalidReply(clientMsgId: String) async -> Bool {
        guard
            let accountId = storedSession?.session.accountId,
            let localStore,
            let outcome = try? await localStore.recoverTextSendAfterInvalidReply(
                clientMsgId: clientMsgId,
                accountId: accountId
            )
        else { return false }
        let dialogId: String
        let message: String
        switch outcome {
        case let .restoredDraft(restoredDialogId):
            dialogId = restoredDialogId
            _ = await draftSyncCoordinator.flush(dialogId: dialogId)
            message = "The reply was removed. Your draft is still here—review it and try again."
        case let .keptFailedMessage(failedDialogId):
            dialogId = failedDialogId
            message = "The reply was removed. Your newer draft was kept, and the failed message is ready to retry."
        }
        if activeDialogId == dialogId {
            await loadLocalLines(dialogId: dialogId)
        }
        await refreshDialogs()
        presentNotice("Original message unavailable", message: message)
        return true
    }

    func cancelMediaTransfers(forRevokedDialogs dialogIds: Set<String>) async {
        guard let localStore else { return }
        for dialogId in dialogIds.sorted() {
            let transfers = (try? await localStore.mediaTransfers(dialogId: dialogId)) ?? []
            for transfer in transfers {
                if let activeTask = mediaTransferTasks[transfer.transferId] {
                    activeTask.cancel()
                    await activeTask.value
                } else if let token = storedSession?.session.token {
                    await cancelMediaTransfer(transfer, token: token)
                } else {
                    try? await localStore.cancelMediaTransfer(
                        transferId: transfer.transferId,
                        clientMsgId: transfer.clientMsgId
                    )
                    await mediaEngine.discardTransfer(transfer)
                }
            }
        }
    }

    static func demoAttachment(
        kind: String, fileName: String?, byteSize: Int64, durationMs: Int64?
    ) -> DemoAttachment {
        let duration = durationMs.map {
            let seconds = max(0, $0 / 1_000)
            return String(format: "%lld:%02lld", seconds / 60, seconds % 60)
        } ?? ""
        switch kind {
        case "photo": return .photo(name: fileName ?? String(localized: "Photo"))
        case "video": return .video(name: fileName ?? String(localized: "Video"), duration: duration)
        case "voice": return .voice(duration: duration.isEmpty ? "0:00" : duration)
        default: return .file(
            name: fileName ?? String(localized: "File"),
            size: ByteCountFormatter.string(fromByteCount: byteSize, countStyle: .file)
        )
        }
    }
}
