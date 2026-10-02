import Foundation
import Observation
import UIKit

extension CloudAppModel {
    func sendMedia(
        data: Data, kind: String, contentType: String, fileName: String?,
        durationMs: Int64? = nil, width: Int? = nil, height: Int? = nil,
        thumbnail: Data? = nil
    ) async {
        composerMediaTask?.cancel()
        await composerMediaTask?.value
        guard !sessionTeardownActive, let dialogId = activeDialogId else { return }
        let operationId = UUID()
        composerMediaOperationId = operationId
        // Establish dialog ownership before the task can enter mediaEngine.prepare.
        composerMediaDialogId = dialogId
        let task = Task { [weak self] in
            guard let self else { return }
            await self.performMediaSend(
                dialogId: dialogId,
                data: data, kind: kind, contentType: contentType, fileName: fileName,
                durationMs: durationMs, width: width, height: height, thumbnail: thumbnail
            )
        }
        composerMediaTask = task
        await task.value
        if composerMediaOperationId == operationId {
            composerMediaTask = nil
            composerMediaOperationId = nil
            composerMediaDialogId = nil
            activeComposerTransferId = nil
        }
    }

    /// Copies picker bytes into the protected encrypted media store before returning. Uploading is
    /// then detached from the picker lifecycle and capped at two concurrent draft transfers.
    func stageDraftMedia(
        data: Data,
        kind: String,
        contentType: String,
        fileName: String?,
        durationMs: Int64? = nil,
        width: Int? = nil,
        height: Int? = nil,
        thumbnail: Data? = nil
    ) async throws {
        guard
            !sessionTearingDown,
            let dialogId = activeDialogId,
            let accountId = storedSession?.session.accountId,
            let localStore
        else { throw CloudAppModelError.localStoreUnavailable }
        let epoch = sessionEpoch
        let mediaEngine = self.mediaEngine
        let groupsEnabled = capabilities.contains(.mediaGroups)
        let transfer = try await draftSyncCoordinator.withDialogStaging(dialogId: dialogId) {
            let existing = try await localStore.loadDraft(accountId: accountId, dialogId: dialogId)
            let position = existing?.attachments.count ?? 0
            guard position < 10 else { throw CloudAppModelError.tooManyDraftAttachments }
            guard position == 0 || groupsEnabled else {
                throw CloudAppModelError.mediaGroupsUnavailable
            }
            let prepared = try await mediaEngine.prepare(
                data: data,
                kind: kind,
                contentType: contentType,
                fileName: fileName,
                durationMs: durationMs,
                width: width,
                height: height,
                thumbnail: thumbnail
            )
            let attachmentId = UUID().uuidString.lowercased()
            var staged = false
            do {
                try Task.checkCancellation()
                _ = try await localStore.stageDraftAttachment(
                    prepared: prepared,
                    accountId: accountId,
                    dialogId: dialogId,
                    attachmentId: attachmentId,
                    position: position
                )
                staged = true
                try Task.checkCancellation()
                guard let transfer = try await localStore.mediaTransfer(id: prepared.transferId)
                else { throw CloudAppModelError.localStoreUnavailable }
                return transfer
            } catch {
                if staged {
                    _ = try? await localStore.removeDraftAttachment(
                        accountId: accountId,
                        dialogId: dialogId,
                        attachmentId: attachmentId
                    )
                }
                await mediaEngine.discardPrepared(prepared)
                throw error
            }
        }
        guard !sessionTearingDown, sessionEpoch == epoch else {
            throw CancellationError()
        }
        Task { [weak self] in
            guard let self, !self.sessionTearingDown, self.sessionEpoch == epoch else { return }
            await self.runMediaTransfer(transfer)
        }
        _ = await draftSyncCoordinator.flush(dialogId: dialogId)
    }

    func removeDraftAttachment(_ attachment: LocalDraftAttachment) {
        guard
            let dialogId = activeDialogId,
            let accountId = storedSession?.session.accountId,
            let localStore
        else { return }
        Task { [weak self] in
            guard let self else { return }
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
                if let transfer, let token = storedSession?.session.token {
                    await mediaEngine.cancelUpload(transfer, token: token)
                    await mediaEngine.discardTransfer(transfer)
                } else if let transfer {
                    await mediaEngine.discardTransfer(transfer)
                }
            }
            _ = await draftSyncCoordinator.flush(dialogId: dialogId)
        }
    }

    func moveDraftAttachment(_ attachmentId: String, by offset: Int) {
        guard
            let dialogId = activeDialogId,
            let accountId = storedSession?.session.accountId,
            let localStore,
            let draft = currentDraft
        else { return }
        var ids = draft.attachments.sorted { $0.position < $1.position }.map(\.attachmentId)
        guard let oldIndex = ids.firstIndex(of: attachmentId) else { return }
        let newIndex = max(0, min(ids.count - 1, oldIndex + offset))
        guard newIndex != oldIndex else { return }
        let moving = ids.remove(at: oldIndex)
        ids.insert(moving, at: newIndex)
        Task { [weak self] in
            guard let self else { return }
            try? await localStore.reorderDraftAttachments(
                accountId: accountId,
                dialogId: dialogId,
                attachmentIds: ids
            )
            _ = await draftSyncCoordinator.flush(dialogId: dialogId)
        }
    }

    func moveDraftAttachment(_ attachmentId: String, before targetId: String) {
        guard
            attachmentId != targetId,
            let dialogId = activeDialogId,
            let accountId = storedSession?.session.accountId,
            let localStore,
            let draft = currentDraft
        else { return }
        var ids = draft.attachments.sorted { $0.position < $1.position }.map(\.attachmentId)
        guard let movingIndex = ids.firstIndex(of: attachmentId) else { return }
        let moving = ids.remove(at: movingIndex)
        guard let targetIndex = ids.firstIndex(of: targetId) else { return }
        ids.insert(moving, at: targetIndex)
        Task { [weak self] in
            guard let self else { return }
            try? await localStore.reorderDraftAttachments(
                accountId: accountId,
                dialogId: dialogId,
                attachmentIds: ids
            )
            _ = await draftSyncCoordinator.flush(dialogId: dialogId)
        }
    }

    func retryDraftAttachment(_ attachment: LocalDraftAttachment) {
        guard let transferId = attachment.transferId, let localStore else { return }
        Task { [weak self] in
            guard let self,
                  let transfer = try? await localStore.retryDraftAttachment(transferId: transferId)
            else { return }
            await runMediaTransfer(transfer)
        }
    }

    private func performMediaSend(
        dialogId: String,
        data: Data, kind: String, contentType: String, fileName: String?,
        durationMs: Int64?, width: Int?, height: Int?, thumbnail: Data?
    ) async {
        guard
            !sessionTeardownActive,
            let accountId = storedSession?.session.accountId,
            let localStore
        else { return }
        openingTimelineAnchor = .bottom
        timelineTopVisibleMsgId = nil
        timelineIsAtBottom = true
        // Voice recording is a transient buffer layered over the cloud draft. It never consumes
        // or reuses the draft text as a caption.
        let caption = kind == "voice"
            ? ""
            : draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let replyToMsgId: Int64?
        if case let .replying(messageId, _) = composerMode {
            replyToMsgId = lines.first(where: { $0.id == messageId })?.msgId
        } else { replyToMsgId = nil }
        let clientMsgId = UUID().uuidString.lowercased()
        let presentation = Self.demoAttachment(
            kind: kind, fileName: fileName, byteSize: Int64(data.count), durationMs: durationMs
        )
        var unpersistedPreparation: PreparedMediaUpload?
        var persistedTransfer: MediaTransferRecord?
        var transferPersisted = false
        do {
            composerMode = .uploading(presentation, progress: 0)
            let prepared = try await mediaEngine.prepare(
                data: data, kind: kind, contentType: contentType, fileName: fileName,
                durationMs: durationMs, width: width, height: height, thumbnail: thumbnail
            )
            unpersistedPreparation = prepared
            try await localStore.insertMediaTransfer(
                prepared: prepared, dialogId: dialogId, clientMsgId: clientMsgId,
                caption: caption, replyToMsgId: replyToMsgId
            )
            transferPersisted = true
            unpersistedPreparation = nil
            guard let transfer = try await localStore.mediaTransfer(id: prepared.transferId) else {
                throw CloudAppModelError.localStoreUnavailable
            }
            persistedTransfer = transfer
            activeComposerTransferId = transfer.transferId
            try await localStore.insertSendingMedia(transfer, senderAccountId: accountId)
            lines.append(Line(
                id: "transfer:\(prepared.transferId)", dialogId: dialogId, msgId: nil,
                clientMsgId: clientMsgId, senderAccountId: accountId, text: caption,
                mine: true, delivery: .sending, timestamp: nil,
                media: transfer.media, transferProgress: 0, transferStage: .preparing
            ))
            await runMediaTransfer(transfer)
        } catch is CancellationError {
            if let unpersistedPreparation { await mediaEngine.discardPrepared(unpersistedPreparation) }
            if let persistedTransfer, let token = storedSession?.session.token {
                await cancelMediaTransfer(persistedTransfer, token: token)
            }
            composerMode = .text
        } catch {
            if let unpersistedPreparation { await mediaEngine.discardPrepared(unpersistedPreparation) }
            if transferPersisted { scheduleOutboxRetry() }
            composerMode = .text
            status = "Media send failed: \(error.localizedDescription)"
            presentNotice("Could not prepare attachment", message: error.localizedDescription)
        }
    }

    func beginVoiceRecording() async {
        #if DEBUG
        if isDemoMode { beginDemoRecording(); return }
        #endif
        do {
            transientVoiceComposerMode = composerMode
            try await voiceRecorder.start()
            composerMode = .recording(elapsedSeconds: 0)
            recordingTask?.cancel()
            recordingTask = Task { [weak self] in
                while let self, !Task.isCancelled, self.voiceRecorder.isRecording {
                    self.composerMode = .recording(elapsedSeconds: self.voiceRecorder.elapsedSeconds)
                    try? await Task.sleep(for: .milliseconds(250))
                }
            }
        } catch {
            status = error.localizedDescription
            restoreVoiceDraftComposer()
            let denied = (error as? VoiceRecorderError) == .permissionDenied
            presentNotice(
                denied ? "Microphone access is off" : "Could not record",
                message: error.localizedDescription,
                opensSettings: denied
            )
        }
    }

    func finishVoiceRecording() async {
        #if DEBUG
        if isDemoMode { finishDemoRecording(); return }
        #endif
        recordingTask?.cancel()
        recordingTask = nil
        do {
            let result = try await voiceRecorder.finish()
            composerMode = transientVoiceComposerMode ?? .text
            await sendMedia(
                data: result.data, kind: "voice", contentType: "audio/mp4",
                fileName: "Voice message.m4a", durationMs: result.durationMs
            )
            restoreVoiceDraftComposer()
        } catch VoiceRecorderError.tooShort {
            status = "Recording canceled"
            restoreVoiceDraftComposer()
        } catch {
            status = error.localizedDescription
            restoreVoiceDraftComposer()
            presentNotice("Voice message was not sent", message: error.localizedDescription)
        }
    }

    func cancelVoiceRecording() {
        recordingTask?.cancel()
        recordingTask = nil
        voiceRecorder.cancel()
        restoreVoiceDraftComposer()
    }

    func restoreVoiceDraftComposer() {
        composerMode = transientVoiceComposerMode ?? .text
        transientVoiceComposerMode = nil
    }

    func thumbnailData(for media: CloudMedia) async -> Data? {
        #if DEBUG
        if isDemoMode { return demoMediaBytes(for: media, thumbnail: true) }
        #endif
        guard let token = storedSession?.session.token,
              await restoreMediaAccessIfAuthorized(mediaId: media.id) != nil
        else { return nil }
        let state = await mediaEngine.mediaDownloadState(mediaId: media.id, expectedSize: media.byteSize)
        LocalFirstMetrics.cacheResult(hit: state?.hasThumbnail == true, thumbnail: true)
        return try? await mediaEngine.thumbnail(
            media: media,
            token: token,
            localStore: localStore
        )
    }

    func restoreMediaAccessIfAuthorized(
        mediaId: String,
        dialogId: String? = nil
    ) async -> MediaPresentationAuthorization? {
        guard !sessionTeardownActive, let localStore else { return nil }
        guard let authorization = try? await localStore.mediaPresentationAuthorization(
            mediaId: mediaId,
            dialogId: dialogId
        ) else { return nil }
        #if DEBUG
        await mediaAccessRestoreAuthorizationGate?()
        #endif
        let lease: MediaAccessRestoreLease
        do {
            lease = try await mediaEngine.restoreAuthorizedAccess(mediaId: mediaId)
        } catch {
            return nil
        }
        #if DEBUG
        await mediaAccessPostRestoreValidationGate?()
        #endif
        if !sessionTeardownActive,
           (try? await localStore.validatesMediaPresentationAuthorization(
            authorization
           )) == true {
            MediaPresentationCache.shared.restore(mediaIds: [mediaId])
            return authorization
        }

        // The exact dialog authorization was stale. Keep the global fence open only when a
        // separately revalidated SQLCipher reference proves that another dialog (or a newer group
        // grant) currently owns this media. Otherwise roll back this exact unfencing generation;
        // rollback fences first and removes any bytes written during the brief unfenced window.
        if !sessionTeardownActive,
           let currentAuthorization = try? await localStore.mediaPresentationAuthorization(
            mediaId: mediaId
           ),
           (try? await localStore.validatesMediaPresentationAuthorization(
            currentAuthorization
           )) == true {
            MediaPresentationCache.shared.restore(mediaIds: [mediaId])
            return nil
        }
        _ = await rollbackUnauthorizedMediaPresentation(lease, mediaId: mediaId)
        return nil
    }

    @discardableResult
    func rollbackUnauthorizedMediaPresentation(
        _ lease: MediaAccessRestoreLease,
        mediaId: String
    ) async -> Bool {
        guard (try? await mediaEngine.rollbackUnauthorizedAccess(lease)) == true else {
            return false
        }
        MediaPresentationCache.shared.revoke(mediaIds: [mediaId])
        return true
    }

    func presentationImage(
        for media: CloudMedia,
        variant requestedVariant: MediaPresentationVariant
    ) async -> UIImage? {
        let interval = LocalFirstMetrics.begin("Media ready")
        defer { LocalFirstMetrics.end("Media ready", interval) }
        let variant: MediaPresentationVariant = media.kind == "video"
            && requestedVariant == .bubble720 ? .videoPoster : requestedVariant
        let key = MediaPresentationKey(mediaId: media.id, variant: variant)
        #if DEBUG
        if isDemoMode {
            let demoData = demoMediaBytes(for: media, thumbnail: variant != .screen2048)
            return await MediaPresentationCache.shared.image(for: key) {
                guard let data = demoData else { return nil }
                return await Task.detached(priority: .userInitiated) {
                    SafeMediaImageDecoder.decode(data, maxPixelSize: variant.maximumPixelSize)
                }.value
            }
        }
        #endif

        guard await restoreMediaAccessIfAuthorized(mediaId: media.id) != nil else {
            return nil
        }
        let engine = mediaEngine
        let store = localStore
        let token = storedSession?.session.token
        return await MediaPresentationCache.shared.image(for: key) {
            let durable = await engine.representation(
                media: media,
                variant: variant,
                localStore: store
            )
            let source: Data?
            if let durable {
                LocalFirstMetrics.presentationCacheTier("encrypted-representation")
                source = durable
            } else {
                guard let token else { return nil }
                switch variant {
                case .bubble720, .videoPoster:
                    if media.hasThumbnail {
                        source = try? await engine.thumbnail(
                            media: media,
                            token: token,
                            localStore: store
                        )
                    } else {
                        let state = await engine.mediaDownloadState(
                            mediaId: media.id,
                            expectedSize: media.byteSize
                        )
                        guard state?.isComplete == true else { return nil }
                        source = try? await engine.data(
                            media: media,
                            token: token,
                            localStore: store,
                            priority: .automatic
                        )
                    }
                case .screen2048:
                    source = try? await engine.data(
                        media: media,
                        token: token,
                        localStore: store,
                        priority: .userInitiated
                    )
                }
            }
            guard let source else { return nil }
            let decoded = await Task.detached(priority: .userInitiated) {
                SafeMediaImageDecoder.decode(source, maxPixelSize: variant.maximumPixelSize)
            }.value
            guard let decoded else { return nil }
            if durable == nil {
                let representation = await Task.detached(priority: .utility) {
                    decoded.image.jpegData(compressionQuality: variant == .screen2048 ? 0.9 : 0.82)
                }.value
                if let representation {
                    await engine.storeRepresentation(
                        representation,
                        media: media,
                        variant: variant,
                        localStore: store
                    )
                }
            }
            return decoded
        }
    }

    func mediaAvailability(
        for media: CloudMedia,
        variant: MediaPresentationVariant
    ) async -> MediaAvailability {
        guard await restoreMediaAccessIfAuthorized(mediaId: media.id) != nil else {
            return .failed
        }
        let key = MediaPresentationKey(mediaId: media.id, variant: variant)
        if MediaPresentationCache.shared.contains(key) { return .decoded }
        if await mediaEngine.representation(media: media, variant: variant, localStore: localStore) != nil {
            return .localRepresentation
        }
        guard let state = await mediaEngine.mediaDownloadState(
            mediaId: media.id,
            expectedSize: media.byteSize
        ) else { return .remote }
        if state.isComplete { return .localComplete }
        if state.cachedBytes > 0 {
            return .partial(progress: min(1, Double(state.cachedBytes) / Double(max(1, media.byteSize))))
        }
        if state.hasThumbnail { return .localRepresentation }
        return .remote
    }

    func mediaData(
        for media: CloudMedia,
        progress: @escaping @Sendable (Double) async -> Void = { _ in }
    ) async throws -> Data {
        #if DEBUG
        if isDemoMode {
            // Staged progress so the viewer's download ring is demonstrable.
            await progress(0.4)
            try? await Task.sleep(for: .milliseconds(220))
            await progress(0.85)
            try? await Task.sleep(for: .milliseconds(180))
            await progress(1)
            return demoMediaBytes(for: media, thumbnail: false) ?? Data()
        }
        #endif
        guard let token = storedSession?.session.token,
              await restoreMediaAccessIfAuthorized(mediaId: media.id) != nil
        else {
            throw CloudAPIError(status: 401, message: "Sign in required", retryAfter: nil)
        }
        let state = await mediaEngine.mediaDownloadState(mediaId: media.id, expectedSize: media.byteSize)
        LocalFirstMetrics.cacheResult(hit: state?.isComplete == true, thumbnail: false)
        return try await mediaEngine.data(
            media: media,
            token: token,
            localStore: localStore,
            priority: .userInitiated,
            progress: progress
        )
    }

    /// A streaming asset that plays this media progressively (chunk-by-chunk) instead of requiring a
    /// full download first. Returns `nil` until there is a session token. Retain the owner while playing.
    func streamingVideoAsset(for media: CloudMedia) async -> StreamingMediaAsset? {
        guard await restoreMediaAccessIfAuthorized(mediaId: media.id) != nil else {
            return nil
        }
        if let prepared = MediaPresentationCache.shared.takePreparedVideoAsset(mediaId: media.id) {
            return prepared
        }
        guard let token = storedSession?.session.token else { return nil }
        return mediaEngine.makeStreamingAsset(
            media: media,
            token: token,
            localStore: localStore
        )
    }

    func prewarmStreamingVideoAssetIfLocal(for media: CloudMedia) async {
        guard media.kind == "video",
              await restoreMediaAccessIfAuthorized(mediaId: media.id) != nil,
              !MediaPresentationCache.shared.hasPreparedVideoAsset(mediaId: media.id),
              let token = storedSession?.session.token,
              await mediaEngine.mediaDownloadState(
                mediaId: media.id,
                expectedSize: media.byteSize
              )?.isComplete == true else { return }
        let asset = mediaEngine.makeStreamingAsset(
            media: media,
            token: token,
            localStore: localStore,
            startsAccessImmediately: false
        )
        MediaPresentationCache.shared.storePreparedVideoAsset(asset, mediaId: media.id)
    }

    @discardableResult
    func transferTemporaryMediaURL(
        data: Data,
        fileExtension: String?,
        mediaId: String,
        dialogId: String,
        transferOwnership: @escaping @MainActor @Sendable (URL) -> Bool
    ) async throws -> Bool {
        let accountId = storedSession?.session.accountId
        let token = storedSession?.session.token
        let generation = savedMessagesSessionGeneration
        let store = localStore
        let presentationGeneration = dialogPresentationGenerations[dialogId, default: 0]
        #if DEBUG
        let permitsDemoMedia = isDemoMode
        #else
        let permitsDemoMedia = false
        #endif
        guard !sessionTeardownActive,
              permitsDemoMedia || (accountId != nil && token != nil && store != nil)
        else {
            throw CloudLocalStoreAccessError.revoked
        }
        let authorization: MediaPresentationAuthorization?
        #if DEBUG
        if permitsDemoMedia {
            authorization = nil
        } else {
            authorization = try await store?.mediaPresentationAuthorization(
                mediaId: mediaId,
                dialogId: dialogId
            )
        }
        #else
        authorization = try await store?.mediaPresentationAuthorization(
            mediaId: mediaId,
            dialogId: dialogId
        )
        #endif
        guard permitsDemoMedia || authorization != nil else {
            throw CloudLocalStoreAccessError.revoked
        }
        return try await mediaEngine.temporaryPreview(
            data: data,
            fileExtension: fileExtension
        ) { [weak self, store] url in
            guard !Task.isCancelled else { return false }
            #if DEBUG
            await self?.temporaryPreviewAuthorizationGate?(url)
            #endif
            if !permitsDemoMedia {
                guard let store, let authorization,
                      (try? await store.validatesMediaPresentationAuthorization(
                        authorization
                      )) == true
                else { return false }
            }
            return await MainActor.run {
                guard let self,
                      !Task.isCancelled,
                      !self.sessionTeardownActive,
                      self.savedMessagesSessionGeneration == generation,
                      self.storedSession?.session.accountId == accountId,
                      self.storedSession?.session.token == token,
                      self.localStore === store || permitsDemoMedia,
                      self.dialogPresentationGenerations[dialogId, default: 0]
                        == presentationGeneration
                else { return false }
                self.temporaryPreviewURLsByDialog[dialogId, default: []].insert(url)
                let transferred = transferOwnership(url)
                if !transferred {
                    self.temporaryPreviewURLsByDialog[dialogId]?.remove(url)
                    if self.temporaryPreviewURLsByDialog[dialogId]?.isEmpty == true {
                        self.temporaryPreviewURLsByDialog[dialogId] = nil
                    }
                }
                return transferred
            }
        }
    }

    func removeTemporaryMediaURL(_ url: URL) async {
        for dialogId in Array(temporaryPreviewURLsByDialog.keys) {
            temporaryPreviewURLsByDialog[dialogId]?.remove(url)
            if temporaryPreviewURLsByDialog[dialogId]?.isEmpty == true {
                temporaryPreviewURLsByDialog[dialogId] = nil
            }
        }
        await mediaEngine.removeTemporaryPreview(url)
    }
}
