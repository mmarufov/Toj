import Foundation
import Observation
import UIKit

extension CloudAppModel {
    func signOut() async {
        #if DEBUG
        if isDemoMode {
            leaveDemoMode()
            return
        }
        #endif
        beginSessionTeardown()
        let sessionToken = storedSession?.session.token
        if let sessionToken {
            // Save before clearing the active session. If the app is killed or offline, the next
            // launch still has enough information to revoke the server session.
            try? await tokenStore.savePendingRevocationToken(
                sessionToken,
                localReplicaAccountId: storedSession?.session.accountId
            )
        }
        await clearLocalSession(finalStatus: "Signed out")
        if let sessionToken {
            Task { [weak self] in await self?.revokeSignedOutToken(sessionToken) }
        }
    }

    func pendingDestructiveLogoutItemCount() async -> Int {
        (try? await localStore?.pendingDestructiveLogoutItemCount()) ?? 0
    }

    func revokeSignedOutToken(_ token: String) async {
        do {
            _ = try await api.revokeSession(token: token)
            try await tokenStore.clearPendingRevocationToken(ifMatches: token)
        } catch {
            if revocationIsTerminal(error) {
                try? await tokenStore.clearPendingRevocationToken(ifMatches: token)
            }
        }
    }

    private func revocationIsTerminal(_ error: Error) -> Bool {
        guard let apiError = error as? CloudAPIError else { return false }
        return apiError.status == 401 || apiError.status == 404
    }

    func loadDevices() async {
        #if DEBUG
        if isDemoMode {
            devices = [
                CloudDevice(
                    id: "demo-device",
                    platform: "ios",
                    deviceName: UIDevice.current.name,
                    createdAt: Self.demoTimestamp(minutesAgo: 1_440),
                    lastSeenAt: Self.demoTimestamp(minutesAgo: 0),
                    current: true
                )
            ]
            return
        }
        #endif
        guard let token = storedSession?.session.token, !loadingDevices else { return }
        loadingDevices = true
        defer { loadingDevices = false }
        do {
            devices = try await api.listDevices(token: token)
            status = "Devices updated"
        } catch {
            status = "Could not load devices: \(error.localizedDescription)"
        }
    }

    func revokeDevice(_ device: CloudDevice) async {
        guard !device.current, let token = storedSession?.session.token else { return }
        do {
            _ = try await api.revokeDevice(id: device.id, token: token)
            devices.removeAll { $0.id == device.id }
            status = "Device signed out"
        } catch {
            status = "Could not revoke device: \(error.localizedDescription)"
        }
    }

    func loadTwoFactorStatus() async {
        guard let token = storedSession?.session.token else { return }
        do {
            let response = try await api.twoFactorStatus(token: token)
            twoFactorEnabled = response.enabled
            twoFactorRecoveryCodesRemaining = response.recoveryCodesRemaining
        } catch let error as CloudAPIError where error.status == 404 {
            twoFactorEnabled = false
            twoFactorRecoveryCodesRemaining = 0
        } catch {
            status = "Could not load two-step verification: \(error.localizedDescription)"
        }
    }

    func acknowledgeRecoveryCodes() {
        recoveredTwoFactorCodes = []
    }

    func requestSecurityChangeCode() async -> Bool {
        guard let token = storedSession?.session.token, !securityChangeInFlight else { return false }
        securityChangeInFlight = true
        defer { securityChangeInFlight = false }
        do {
            let response = try await api.startSecurityStepUp(token: token)
            securityCode = response.code ?? ""
            status = "Security code requested"
            return true
        } catch {
            status = "Could not request security code: \(error.localizedDescription)"
            return false
        }
    }

    func verifySecurityChangeCode() async -> Bool {
        guard let token = storedSession?.session.token,
              securityCode.filter(\.isNumber).count == 6,
              !securityChangeInFlight
        else { return false }
        securityChangeInFlight = true
        defer { securityChangeInFlight = false }
        do {
            let response = try await api.checkSecurityStepUp(
                code: securityCode.filter(\.isNumber),
                token: token
            )
            securityStepUpToken = response.stepUpToken
            return true
        } catch {
            status = "Security verification failed: \(error.localizedDescription)"
            return false
        }
    }

    func saveTwoFactor(password: String, currentCredential: String?) async -> Bool {
        guard let saved = storedSession,
              let stepUpToken = securityStepUpToken,
              !securityChangeInFlight
        else { return false }
        securityChangeInFlight = true
        defer { securityChangeInFlight = false }
        do {
            let response = try await api.configureTwoFactor(
                stepUpToken: stepUpToken,
                password: password,
                currentCredential: currentCredential,
                token: saved.session.token
            )
            let sessionInstalled = await applySecuritySession(
                response.session,
                replacing: saved
            )
            recoveredTwoFactorCodes = response.recoveryCodes ?? []
            twoFactorEnabled = true
            twoFactorRecoveryCodesRemaining = recoveredTwoFactorCodes.count
            securityStepUpToken = nil
            securityCode = ""
            status = sessionInstalled
                ? "Two-step verification updated"
                : "Two-step verification updated. Sign in again to resume your saved chats."
            return true
        } catch {
            status = "Could not update two-step verification: \(error.localizedDescription)"
            return false
        }
    }

    func disableTwoFactor(currentCredential: String) async -> Bool {
        guard let saved = storedSession,
              let stepUpToken = securityStepUpToken,
              !securityChangeInFlight
        else { return false }
        securityChangeInFlight = true
        defer { securityChangeInFlight = false }
        do {
            let response = try await api.disableTwoFactor(
                stepUpToken: stepUpToken,
                currentCredential: currentCredential,
                token: saved.session.token
            )
            let sessionInstalled = await applySecuritySession(
                response.session,
                replacing: saved
            )
            twoFactorEnabled = false
            twoFactorRecoveryCodesRemaining = 0
            recoveredTwoFactorCodes = []
            securityStepUpToken = nil
            securityCode = ""
            status = sessionInstalled
                ? "Two-step verification disabled"
                : "Two-step verification disabled. Sign in again to resume your saved chats."
            return true
        } catch {
            status = "Could not disable two-step verification: \(error.localizedDescription)"
            return false
        }
    }

    func regenerateTwoFactorRecoveryCodes(currentCredential: String) async -> Bool {
        guard let saved = storedSession,
              let stepUpToken = securityStepUpToken,
              !securityChangeInFlight
        else { return false }
        securityChangeInFlight = true
        defer { securityChangeInFlight = false }
        do {
            let response = try await api.regenerateTwoFactorRecoveryCodes(
                stepUpToken: stepUpToken,
                currentCredential: currentCredential,
                token: saved.session.token
            )
            let sessionInstalled = await applySecuritySession(
                response.session,
                replacing: saved
            )
            recoveredTwoFactorCodes = response.recoveryCodes ?? []
            twoFactorRecoveryCodesRemaining = recoveredTwoFactorCodes.count
            securityStepUpToken = nil
            securityCode = ""
            status = sessionInstalled
                ? "Recovery codes replaced"
                : "Recovery codes replaced. Sign in again to resume your saved chats."
            return true
        } catch {
            status = "Could not replace recovery codes: \(error.localizedDescription)"
            return false
        }
    }

    func applySecuritySession(
        _ session: CloudSession,
        replacing saved: StoredCloudSession
    ) async -> Bool {
        guard canInstallReissuedSession(replacing: saved) else {
            await abandonReissuedSession(
                session.token,
                preservingLocalReplicaFor: saved.session.accountId
            )
            return false
        }
        let replacement = StoredCloudSession(
            session: session,
            phone: saved.phone,
            displayName: saved.displayName
        )
        do {
            try await tokenStore.save(replacement)
        } catch {
            // The server already committed the security change and superseded `saved`. Establish
            // the replica-authentication fence before remote cleanup can consume its own marker.
            try? await tokenStore.savePendingReauthentication(
                accountId: saved.session.accountId
            )
            await abandonReissuedSession(
                session.token,
                preservingLocalReplicaFor: saved.session.accountId
            )
            await pauseForExpiredSession(saved)
            return false
        }
        // Saving crosses an actor boundary. Logout, remote revocation, or account replacement may
        // have won while Keychain was writing; remove only this response and never resurrect it.
        guard canInstallReissuedSession(replacing: saved) else {
            try? await tokenStore.clearSession(ifTokenMatches: session.token)
            await abandonReissuedSession(
                session.token,
                preservingLocalReplicaFor: saved.session.accountId
            )
            return false
        }
        installAuthenticatedSession(replacement)
        await startHints(token: session.token)
        return true
    }

    private func canInstallReissuedSession(replacing saved: StoredCloudSession) -> Bool {
        !sessionTeardownActive
            && sessionClearBarrier == nil
            && storedSession?.session.accountId == saved.session.accountId
            && storedSession?.session.deviceId == saved.session.deviceId
            && storedSession?.session.token == saved.session.token
    }

    private func abandonReissuedSession(
        _ token: String,
        preservingLocalReplicaFor accountId: String
    ) async {
        do {
            try await tokenStore.savePendingRevocationToken(
                token,
                eraseLocalReplicaOnLaunch: false,
                localReplicaAccountId: accountId
            )
        } catch {
            // Keychain is already unavailable. A direct best-effort revoke is the only remaining
            // safe cleanup path; the replacement is never installed in memory.
            _ = try? await api.revokeSession(token: token)
            return
        }
        await revokeSignedOutToken(token)
    }

    func requestAccountDeletionCode() async -> Bool {
        #if DEBUG
        if isDemoMode {
            accountDeletionRequested = true
            accountDeletionCode = "123456"
            status = "Deletion code requested"
            return true
        }
        #endif
        guard let token = storedSession?.session.token, !accountDeletionInFlight else { return false }
        accountDeletionInFlight = true
        defer { accountDeletionInFlight = false }
        do {
            let response = try await api.startAccountDeletion(token: token)
            accountDeletionRequested = true
            accountDeletionCode = response.code ?? ""
            status = "Deletion code requested"
            return true
        } catch {
            status = "Could not request deletion code: \(error.localizedDescription)"
            return false
        }
    }

    func cancelAccountDeletion() {
        guard !accountDeletionInFlight else { return }
        accountDeletionRequested = false
        accountDeletionCode = ""
    }

    func deleteAccount() async -> Bool {
        #if DEBUG
        if isDemoMode {
            leaveDemoMode()
            return true
        }
        #endif
        guard let saved = storedSession, !accountDeletionInFlight else { return false }
        let digits = accountDeletionCode.filter(\.isNumber)
        guard digits.count == 6 else {
            status = "Enter the 6-digit deletion code"
            return false
        }
        accountDeletionInFlight = true
        defer { accountDeletionInFlight = false }
        // Persist intent before the network call. If the app is killed after the server commits,
        // launch will not restore a now-invalid session or leave the local replica visible.
        try? await tokenStore.savePendingRevocationToken(
            saved.session.token,
            localReplicaAccountId: saved.session.accountId
        )
        do {
            _ = try await api.deleteAccount(code: digits, token: saved.session.token)
            await clearLocalSession(finalStatus: "Account deleted")
            try? await tokenStore.clearPendingRevocationToken(ifMatches: saved.session.token)
            return true
        } catch {
            if let apiError = error as? CloudAPIError {
                if apiError.status == 401 || apiError.status == 403 {
                    await clearLocalSession(finalStatus: "Session ended")
                    try? await tokenStore.clearPendingRevocationToken(ifMatches: saved.session.token)
                    return true
                }
                // The server definitely rejected this request before deletion completed.
                try? await tokenStore.clearPendingRevocationToken(ifMatches: saved.session.token)
            }
            status = "Could not confirm account deletion: \(error.localizedDescription)"
            return false
        }
    }

    @discardableResult
    func clearLocalSession(finalStatus: String) async -> Bool {
        if sessionClearBarrier != nil {
            return await withCheckedContinuation { continuation in
                sessionClearBarrier?.waiters.append(continuation)
            }
        }
        // This flag changes synchronously before the first suspension point. User actions cannot
        // enqueue new Saved/forward SQL while teardown is waiting on older work.
        sessionTeardownActive = true
        let id = UUID()
        sessionClearBarrier = SessionClearBarrier(id: id, waiters: [])
        let succeeded = await performClearLocalSession(finalStatus: finalStatus)
        if sessionClearBarrier?.id == id {
            let waiters = sessionClearBarrier?.waiters ?? []
            sessionClearBarrier = nil
            waiters.forEach { $0.resume(returning: succeeded) }
        }
        return succeeded
    }

    private func performClearLocalSession(finalStatus: String) async -> Bool {
        beginSessionTeardown()
        await SessionCredentialCoordinator.shared.clear()
        // Both session fences are entered before teardown's first suspension point. Draft/media
        // work validates the epoch; preference work validates the account generation.
        isSessionTeardownInProgress = true
        accountSessionGeneration &+= 1
        // Prevent an old ensure from publishing while its exact task is cancelled and awaited.
        savedMessagesSessionGeneration &+= 1
        savedMessagesCapabilityState = .unknown
        // Capture must be fenced before teardown reaches any unrelated actor or disk await.
        await groupCallCoordinator.unbind()
        let savedOperations = Array(trackedSavedOperations.values)
        trackedSavedOperations.removeAll()
        savedOperations.forEach { $0.cancel() }
        // Saved setup owns a nested, coalesced provisioning task inside the service actor. Reset
        // that exact task before awaiting the user-facing wrapper; otherwise an unstructured
        // network task that ignores parent cancellation could keep teardown waiting forever.
        await savedMessagesService.reset()
        await accessPurgeCoordinator.reset()
        await presenceCoordinator.reset(clearCacheValues: true)
        for operation in savedOperations { await operation.wait() }
        let accountId = storedSession?.session.accountId ?? expiredSessionAccountId
        await draftSyncCoordinator.suspendRetries()
        await profilePhotoSyncCoordinator.configure(store: nil, session: nil, enabled: false)
        var cleanupFailures: [String] = []
        do {
            try await tokenStore.savePendingLocalErasure(accountId: accountId)
        } catch {
            cleanupFailures.append(error.localizedDescription)
        }

        let composerTask = composerMediaTask
        let transferTasks = Array(mediaTransferTasks.values)
        let pendingDraftPersistenceTasks = Array(draftPersistenceTasks.values)
        let preferenceTasks = Array(preferenceMutationTasks.values)
        let pendingProfileSaveTasks = Array(profileSaveTasks.values)
        profileSaveTasks.removeAll()
        let pendingRetryTask = retryTask
        let terminalAcknowledgementTask = productivityTerminalAcknowledgementTask?.task
        productivityTerminalAcknowledgementTask = nil
        pendingProductivityTerminalNotice = nil
        // Fence find-in-chat publication immediately, then join its detached FTS child with the
        // rest of the SQLCipher readers before the replica is cleared or destroyed.
        inChatSearchGeneration &+= 1
        let pendingInChatSearchTask = inChatSearchTask
        inChatSearchTask = nil
        inChatSearch = nil
        focusedSearchMsgId = nil
        let backgroundTasks: [Task<Void, Never>] = [
            hintTask, networkObservationTask, memoryPressureTask,
            pendingRetryTask, resendTask, recordingTask,
            composerTask, profileSyncTask,
            profilePhotoMigrationTask,
            postSignInTask, postSyncWorkTask, historyHydrationTask, dialogObservationTask,
            openingAnchorHydrationTask,
            timelineObservationTask, draftObservationTask,
            viewportPersistenceTask, mediaDownloadTask,
            readReceiptRetryTask, replicaIntegrityTask, pendingInChatSearchTask,
            terminalAcknowledgementTask, credentialRefreshLoopTask,
        ].compactMap { $0 }
        backgroundTasks.forEach { $0.cancel() }
        transferTasks.forEach { $0.cancel() }
        preferenceTasks.forEach { $0.cancel() }
        pendingProfileSaveTasks.forEach { $0.cancel() }
        await dialogPreferencesCoordinator.cancelAndWait()
        await productivitySyncCoordinator.cancelAndWait()
        voiceRecorder.cancel()
        await hintSocket?.stop()
        hintSocket = nil
        await replicaSyncCoordinator.stop()
        await mediaPrefetchScheduler.stop()
        mediaSchedulerForegrounded = false
        await BackgroundRuntimeCoordinator.shared.removeWorkHandlersAndWait()
        // Search owns detached observation/drain work against SQLCipher. Quiesce and release that
        // exact account/store generation before either clearing rows or destroying the replica.
        await searchCoordinator?.cancelAndWait()
        searchCoordinator = nil
        for task in backgroundTasks { await task.value }
        for task in transferTasks { await task.value }
        for task in preferenceTasks { await task.value }
        for task in pendingProfileSaveTasks { _ = await task.value }
        // Draft mutations are intentionally not cancelled: every captured composer generation
        // reaches SQLCipher before logout destroys the account replica.
        for task in pendingDraftPersistenceTasks { await task.value }
        await draftSyncCoordinator.cancelAndWait()
        hintTask = nil
        networkObservationTask = nil
        memoryPressureTask = nil
        retryTask = nil
        resendTask = nil
        recordingTask = nil
        composerMediaTask = nil
        profileSyncTask = nil
        profilePhotoMigrationTask = nil
        postSignInTask = nil
        postSyncWorkTask = nil
        historyHydrationTask = nil
        openingAnchorHydrationTask = nil
        dialogObservationTask = nil
        timelineObservationTask = nil
        draftObservationTask = nil
        draftPersistenceTasks.removeAll()
        draftPersistenceGenerations.removeAll()
        minimumObservedDraftGenerations.removeAll()
        viewportPersistenceTask = nil
        mediaDownloadTask = nil
        readReceiptRetryTask = nil
        replicaIntegrityTask = nil
        credentialRefreshLoopTask = nil
        composerMediaOperationId = nil
        composerMediaDialogId = nil
        activeComposerTransferId = nil
        mediaTransferTasks.removeAll()
        mediaTransferDialogIds.removeAll()
        temporaryPreviewURLsByDialog.removeAll()
        dialogPresentationGenerations.removeAll()
        preferenceMutationTasks.removeAll()
        mediaTransfersInFlight.removeAll()
        mediaGroupSendsInFlight.removeAll()
        draftSendsInFlightByDialog.removeAll()
        messageMutationsInFlight.removeAll()
        mutationTargetsBeingQueued.removeAll()
        syncInFlight = false
        syncAgain = false
        appliedSyncBatches = 0
        lastForegroundSyncFailure = nil
        lastSuccessfulServerContact = nil
        retryInFlight = false

        await mediaEngine.destroyLocalStateForLogout()
        MediaPresentationCache.shared.resetForSession()
        backgroundMediaRuntimePrepared = false
        mediaCacheBytes = 0

        do {
            try await tokenStore.clearAllProfiles()
        } catch {
            cleanupFailures.append(error.localizedDescription)
        }

        if opensDefaultLocalStore {
            // Both references must be released before removing WAL/SHM and the SQLCipher key.
            localStore = nil
            do {
                try await localStoreBootstrapper.destroyDefaultMediaState()
            } catch {
                cleanupFailures.append(error.localizedDescription)
            }
            do {
                try await localStoreBootstrapper.destroyDefaultStore()
            } catch {
                cleanupFailures.append(error.localizedDescription)
            }
        } else if let accountId {
            do {
                try await localStore?.clearAccount(accountId: accountId)
            } catch {
                cleanupFailures.append(error.localizedDescription)
            }
        }

        do {
            try await tokenStore.clear()
        } catch {
            cleanupFailures.append(error.localizedDescription)
        }
        if cleanupFailures.isEmpty {
            do {
                // A queued token can outlive successful local cleanup while the device is offline.
                // Downgrade it to remote-only before clearing the crash marker so a later login is
                // never erased merely because that old server revocation still needs retrying.
                try await tokenStore.markPendingRevocationLocalErasureCompleted(
                    accountId: accountId
                )
                try await tokenStore.clearPendingReauthentication()
                try await tokenStore.clearPendingLocalErasure()
            } catch {
                cleanupFailures.append(error.localizedDescription)
            }
        }
        storedSession = nil
        expiredSessionAccountId = nil
        activeDialogId = nil
        dialogs = []
        chatFolders = []
        chatFolderCollectionRevision = 0
        scheduledDeliveries = []
        savedMessagesDialogId = nil
        savedMessagesSetupInFlight = false
        savedMessagesSetupFailure = nil
        lines = []
        loadedLocalMessages = []
        pendingVisibleReadMessages = []
        openingTimelineAnchor = .bottom
        timelineTopVisibleMsgId = nil
        timelineIsAtBottom = true
        timelineBeforeCount = 40
        timelineAfterCount = 79
        canLoadEarlier = false
        loadingEarlier = false
        canLoadLater = false
        loadingLater = false
        historyHasMoreByDialog = [:]
        timelineForwardCursorByDialog = [:]
        timelineHasMoreForwardByDialog = [:]
        currentDraft = nil
        draftMentionsByDialog = [:]
        transientUnderlyingDraftText = nil
        transientUnderlyingComposerMode = nil
        transientVoiceComposerMode = nil
        cachedLinesByDialog = [:]
        cachedLocalMessagesByDialog = [:]
        cachedLineDialogOrder = []
        cachedConversationCostByDialog = [:]
        devices = []
        loadingDevices = false
        uploadedPushRegistration = nil
        uploadedVoIPPushRegistration = nil
        uploadedGroupCallCapabilityRegistration = nil
        callCoordinator.unbind()
        pts = 0
        phone = "+992 "
        displayName = ""
        peerPhone = ""
        draft = ""
        requestedCode = false
        authRequestInFlight = false
        authVerifyInFlight = false
        resendSeconds = 0
        code = ""
        accountDeletionRequested = false
        accountDeletionInFlight = false
        accountDeletionCode = ""
        profileDetails = .empty
        profileSaveInFlight = false
        profilePhotoSyncState = .localOnly
        profilePhotoDisplayData = nil
        canonicalProfilePhoto = nil
        profilePhotoRevision = 0
        composerMode = .text
        operationNotice = nil
        pendingProductivityTerminalNotice = nil
        #if DEBUG
        demoLinesByDialog = [:]
        #endif
        launchPhase = .signedOut
        conversationOpenState = .loadingLocal
        setReplicaSyncState(.offline)
        status = cleanupFailures.isEmpty
            ? finalStatus
            : "Signed out; local cleanup needs another attempt"
        return cleanupFailures.isEmpty
    }

    /// Changes the session epoch synchronously, before logout's first suspension point. Every
    /// subsequently resumed operation must still match this epoch before touching store or UI.
    private func beginSessionTeardown() {
        guard !sessionTearingDown else { return }
        sessionTearingDown = true
        sessionEpoch &+= 1
        draftObservationTask?.cancel()
        timelineObservationTask?.cancel()
        dialogObservationTask?.cancel()
        composerMediaTask?.cancel()
        for task in mediaTransferTasks.values { task.cancel() }
        retryTask?.cancel()
        postSyncWorkTask?.cancel()
    }

    func afterSignIn() async {
        guard
            let token = storedSession?.session.token,
            let accountId = storedSession?.session.accountId
        else { return }
        do {
            guard let restoredStore = try await ensureLocalStore() else {
                throw CloudAppModelError.localStoreUnavailable
            }
            try await drainAccessPurges(
                store: restoredStore,
                accountId: accountId,
                token: token,
                generation: savedMessagesSessionGeneration
            )
            let launchSnapshot = try await restoredStore.loadLaunchSnapshot(accountId: accountId)
            await draftSyncCoordinator.configure(
                store: restoredStore,
                session: storedSession?.session,
                cloudEnabled: negotiatedCapabilities.contains(.cloudDrafts)
            )
            await profilePhotoSyncCoordinator.configure(
                store: restoredStore,
                session: storedSession?.session,
                enabled: negotiatedCapabilities.contains(.profilePhotos)
            )

            // Publish the complete cached launch state in one main-actor turn.
            pts = launchSnapshot.pts
            acceptObservedDialogs(launchSnapshot.dialogs)
            activeDialogId = nil
            lines = []
            canLoadEarlier = false
            launchPhase = .localReady
            status = "Ready"
            startDialogObservation(accountId: accountId)
            startNetworkObservation()
            startMemoryPressureObservation()
            EncryptedProfilePhotoStore.beginAuthenticatedSession()
            profilePhotoMigrationTask?.cancel()
            profilePhotoMigrationTask = Task.detached(priority: .utility) {
                guard !Task.isCancelled else { return }
                _ = EncryptedProfilePhotoStore.migrateLegacySynchronously(accountId: accountId)
            }
        } catch {
            pts = 0
            status = "Local store unavailable: \(error.localizedDescription)"
            setReplicaSyncState(.localFailure)
            launchPhase = .recoveringStore
            return
        }
        if let session = storedSession?.session {
            callCoordinator.configure(api: api, session: session) { [weak self] dialogId, _ in
                self?.dialogTitle(dialogId) ?? String(localized: "Toj caller")
            }
            groupCallCoordinator.configure(
                api: api,
                session: session,
                screenSharingNegotiated: { [weak self] in
                    self?.negotiatedCapabilities.contains(.screenSharing) == true
                }
            ) { [weak self] accountId, dialogId in
                self?.groupCallParticipantName(accountId: accountId, dialogId: dialogId)
                    ?? String(accountId.prefix(8))
            }
        }
        await refreshMediaCacheUsage()
        // Bind search at local-ready time, not only when the UI happens to open the Search tab.
        // This makes the local capability truthful and lets the existing background runtime service
        // queue and maintenance work even when the user never visits search.
        await refreshSearchCoordinator()
        installBackgroundWorkHandlers()
        if let localStore {
            startReplicaIntegrityVerification(store: localStore, accountId: accountId)
            _ = try? await localStore.drainPendingPurges()
        }
        scheduleOutboxRetry()
    }

    func drainAccessPurges(
        store: CloudLocalStore,
        accountId: String,
        token: String,
        generation: UInt64
    ) async throws {
        let scope = AccessPurgeScope(
            accountId: accountId,
            token: token,
            generation: generation,
            store: store
        )
        _ = try await accessPurgeCoordinator.drain(
            scope: scope,
            store: store,
            mediaEngine: mediaEngine,
            isCurrent: { [weak self, store] in
                guard let self else { return false }
                return !self.sessionTeardownActive
                    && self.savedMessagesSessionGeneration == generation
                    && self.storedSession?.session.accountId == accountId
                    && self.storedSession?.session.token == token
                    && self.localStore === store
            },
            invalidatePresentation: { [weak self] job in
                guard let self else { return }
                await self.invalidatePresentationForAccessPurge(job)
            }
        )
        if mediaSchedulerForegrounded {
            await mediaPrefetchScheduler.update(
                networkClass: ReplicaNetworkMonitor.shared.snapshot().networkClass,
                foregrounded: true
            )
        }
    }

    func invalidatePresentationForAccessPurge(_ job: AccessPurgeJob) async {
        let dialogId = job.dialogId
        dialogPresentationGenerations[dialogId, default: 0] &+= 1
        let temporaryURLs = temporaryPreviewURLsByDialog.removeValue(forKey: dialogId) ?? []
        for url in temporaryURLs {
            await mediaEngine.removeTemporaryPreview(url)
        }
        // Shared media remains valid in a forwarded copy. Only globally orphaned media receives a
        // process-wide presentation tombstone.
        MediaPresentationCache.shared.revoke(mediaIds: job.purgeMediaIds)

        let transferIds = Set(mediaTransferDialogIds.compactMap { transferId, taskDialogId in
            taskDialogId == dialogId ? transferId : nil
        })
        let cancellableTasks = transferIds.compactMap { mediaTransferTasks[$0] }
        cancellableTasks.forEach { $0.cancel() }
        let cancelsActiveConversationWork = activeDialogId == dialogId
        if cancelsActiveConversationWork {
            mediaDownloadTask?.cancel()
            historyHydrationTask?.cancel()
        }
        let cancelsComposer = composerMediaDialogId == dialogId
            || activeComposerTransferId.map(transferIds.contains) == true
        if cancelsComposer { composerMediaTask?.cancel() }
        for task in cancellableTasks { await task.value }
        for transferId in transferIds {
            mediaTransferTasks[transferId] = nil
            mediaTransferDialogIds[transferId] = nil
            mediaTransfersInFlight.remove(transferId)
        }
        if cancelsActiveConversationWork {
            await mediaDownloadTask?.value
            await historyHydrationTask?.value
            mediaDownloadTask = nil
            historyHydrationTask = nil
        }
        if cancelsComposer {
            await composerMediaTask?.value
            composerMediaTask = nil
            composerMediaDialogId = nil
            activeComposerTransferId = nil
            composerMediaOperationId = nil
        }

        cachedLinesByDialog[dialogId] = nil
        cachedLocalMessagesByDialog[dialogId] = nil
        cachedConversationCostByDialog[dialogId] = nil
        cachedLineDialogOrder.removeAll { $0 == dialogId }
        timelineForwardCursorByDialog[dialogId] = nil
        conversationOpenWaiters[dialogId]?.forEach { $0.resume() }
        conversationOpenWaiters[dialogId] = nil
        conversationOpenStartedAt[dialogId] = nil
        dialogs.removeAll { $0.id == dialogId }
        if savedMessagesDialogId == dialogId { savedMessagesDialogId = nil }
        if activeDialogId == dialogId {
            activeDialogId = nil
            lines = []
            loadedLocalMessages = []
            pendingVisibleReadMessages = []
            canLoadEarlier = false
        }
    }
}
