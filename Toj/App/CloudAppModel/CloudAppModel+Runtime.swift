import Foundation
import Observation
import UIKit

extension CloudAppModel {
    func startReplicaIntegrityVerification(store: CloudLocalStore, accountId: String) {
        replicaIntegrityTask?.cancel()
        replicaIntegrityTask = Task { [weak self, store] in
            do {
                // Let the cached list and first interaction win disk bandwidth. This check is
                // important, but it is not part of the launch critical path.
                try await Task.sleep(for: .seconds(2))
                try await store.verifyIntegrity()
                try Task.checkCancellation()
            } catch is CancellationError {
                return
            } catch {
                guard let self,
                      self.storedSession?.session.accountId == accountId,
                      let currentStore = self.localStore,
                      currentStore === store
                else { return }
                self.postSignInTask?.cancel()
                self.postSyncWorkTask?.cancel()
                await self.replicaSyncCoordinator.invalidate()
                self.historyHydrationTask?.cancel()
                self.mediaDownloadTask?.cancel()
                self.dialogObservationTask?.cancel()
                self.timelineObservationTask?.cancel()
                await self.hintSocket?.stop()
                self.hintSocket = nil
                await BackgroundRuntimeCoordinator.shared.removeWorkHandlersAndWait()
                self.setReplicaSyncState(.localFailure)
                self.launchPhase = .recoveringStore
                self.status = "Local store integrity check failed; cached files were preserved for recovery"
            }
        }
    }

    func activateForegroundServices() async {
        mediaSchedulerForegrounded = true
        await mediaPrefetchScheduler.update(
            networkClass: ReplicaNetworkMonitor.shared.snapshot().networkClass,
            foregrounded: true
        )
        guard launchPhase == .localReady, storedSession != nil else { return }
        #if DEBUG
        if TelegramFastUITestFixture.enabled {
            // The fixture token is deliberately non-routable. Keep deterministic UI scenarios
            // behind the same online-service boundary as before credential refresh was added, or
            // its expected presence state is immediately replaced by a transport failure.
            await startOnlineServices()
            return
        }
        #endif
        await prepareCurrentCredentials()
        guard launchPhase == .localReady, storedSession != nil else { return }
        startCredentialRefreshLoopIfNeeded()
        guard postSignInTask == nil else { return }
        postSignInTask = Task { [weak self] in
            guard let self else { return }
            await self.startOnlineServices()
            self.postSignInTask = nil
        }
    }

    private func startCredentialRefreshLoopIfNeeded() {
        guard credentialRefreshLoopTask == nil else { return }
        credentialRefreshLoopTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard !Task.isCancelled else { return }
                await self.prepareCurrentCredentials()
            }
        }
    }

    private func prepareCurrentCredentials() async {
        guard let saved = storedSession, !sessionTeardownActive else { return }
        do {
            if saved.session.tokenVersion < 2 {
                let capabilities = try await api.capabilities(token: saved.session.token)
                guard capabilities.capabilities.contains("auth_sessions_v2") else { return }
                let upgraded = try await api.upgradeSession(token: saved.session.token)
                let installed = await applySecuritySession(upgraded, replacing: saved)
                if !installed, storedSession == nil {
                    status = "Session upgraded. Sign in again to resume your saved chats."
                }
            } else {
                _ = try await SessionCredentialCoordinator.shared.refreshIfNeeded(
                    matching: saved.session.token
                )
            }
        } catch let error as CloudAPIError {
            switch error.code {
            case "session_expired":
                await pauseForExpiredSession(saved)
            case "device_revoked", "refresh_reuse_detected":
                await clearLocalSession(finalStatus: "Session ended for security")
            default:
                publishTransportFailure(error)
            }
        } catch {
            publishTransportFailure(error)
        }
    }

    func pauseForExpiredSession(_ saved: StoredCloudSession) async {
        guard storedSession?.session.deviceId == saved.session.deviceId else { return }
        expiredSessionAccountId = saved.session.accountId
        // Save the local-replica identity before removing the expired credential. If Keychain is
        // unavailable, retain the old session item as a conservative identity fallback on launch.
        let reauthenticationMarkerSaved: Bool
        do {
            try await tokenStore.savePendingReauthentication(accountId: saved.session.accountId)
            reauthenticationMarkerSaved = true
        } catch {
            reauthenticationMarkerSaved = false
        }
        accountSessionGeneration &+= 1
        savedMessagesSessionGeneration &+= 1
        let cloudTasks: [Task<Void, Never>] = [
            postSignInTask, postSyncWorkTask, historyHydrationTask, mediaDownloadTask,
            readReceiptRetryTask, retryTask, resendTask, profileSyncTask,
            composerMediaTask,
        ].compactMap { $0 }
        let transfers = Array(mediaTransferTasks.values)
        let preferences = Array(preferenceMutationTasks.values)
        cloudTasks.forEach { $0.cancel() }
        transfers.forEach { $0.cancel() }
        preferences.forEach { $0.cancel() }
        credentialRefreshLoopTask?.cancel()
        credentialRefreshLoopTask = nil
        hintTask?.cancel()
        hintTask = nil
        storedSession = nil
        await draftSyncCoordinator.suspendRetries()
        await dialogPreferencesCoordinator.cancelAndWait()
        await hintSocket?.stop()
        hintSocket = nil
        await replicaSyncCoordinator.stop()
        await mediaPrefetchScheduler.stop()
        await BackgroundRuntimeCoordinator.shared.removeWorkHandlersAndWait()
        for task in cloudTasks { await task.value }
        for task in transfers { await task.value }
        for task in preferences { await task.value }
        postSignInTask = nil
        postSyncWorkTask = nil
        historyHydrationTask = nil
        mediaDownloadTask = nil
        readReceiptRetryTask = nil
        retryTask = nil
        resendTask = nil
        profileSyncTask = nil
        composerMediaTask = nil
        mediaTransferTasks.removeAll()
        mediaTransferDialogIds.removeAll()
        preferenceMutationTasks.removeAll()
        await SessionCredentialCoordinator.shared.clear()
        if reauthenticationMarkerSaved {
            try? await tokenStore.clearSession(ifTokenMatches: saved.session.token)
        }
        launchPhase = .localReady
        setReplicaSyncState(.sessionExpired)
        status = "Session expired. Sign in again to resume your saved chats."
    }

    func setForegroundActive(_ isActive: Bool) async {
        await presenceCoordinator.setForegroundActive(isActive)
        mediaSchedulerForegrounded = isActive
        await mediaPrefetchScheduler.update(
            networkClass: ReplicaNetworkMonitor.shared.snapshot().networkClass,
            foregrounded: isActive
        )
        if isActive {
            await draftSyncCoordinator.resumeRetries()
            scheduleMediaDownloadProcessing()
        } else {
            for task in Array(draftPersistenceTasks.values) {
                await task.value
            }
            await draftSyncCoordinator.flushAll(reason: .background)
        }
    }

    func prepareBackgroundMediaRuntime() async {
        guard
            !backgroundMediaRuntimePrepared,
            launchPhase == .localReady,
            storedSession != nil,
            let localStore
        else { return }
        backgroundMediaRuntimePrepared = true
        do {
            try await mediaEngine.warmCache(localStore: localStore)
        } catch {
            // Media is evictable and must never block the encrypted text replica. Leave this false
            // so the foreground activation or a later background wake can retry initialization.
            backgroundMediaRuntimePrepared = false
        }
    }

    func ensureLocalStore() async throws -> CloudLocalStore? {
        if let localStore { return localStore }
        guard opensDefaultLocalStore else { return nil }
        let interval = LocalFirstMetrics.begin("Database open")
        defer { LocalFirstMetrics.end("Database open", interval) }
        let store = try await localStoreBootstrapper.openDefaultStore()
        localStore = store
        return store
    }

    private func startOnlineServices() async {
        guard launchPhase == .localReady, storedSession != nil else { return }
        #if DEBUG
        if TelegramFastUITestFixture.enabled {
            if TelegramFastUITestFixture.presenceScenario == nil {
                setReplicaSyncState(.offline)
                status = "Offline fixture — showing saved chats"
            }
            return
        }
        #endif
        await resume()
        // Registration can prompt, so connection checking must already be in flight. Everything
        // that can compete with opening a cached chat is deferred until the difference pass wins.
        await pushCenter.requestAuthorization()
    }

    #if DEBUG
    func installTelegramFastUITestFixture() async throws {
        if TelegramFastUITestFixture.resetsStorage {
            try? await tokenStore.clear()
            try TelegramFastUITestFixture.reset()
        }
        let fixtureSession = TelegramFastUITestFixture.session
        // The deterministic fixture is reinstalled on every UI-test process launch. Avoid a
        // Keychain dependency so unsigned simulator verification can exercise the encrypted
        // replica and presentation without failing on errSecMissingEntitlement.
        isSessionTeardownInProgress = false
        installAuthenticatedSession(fixtureSession)
        phone = fixtureSession.phone
        displayName = fixtureSession.displayName
        profileDetails = StoredProfileDetails(
            firstName: "UI",
            lastName: "Fixture",
            bio: "Encrypted offline test profile",
            birthday: nil,
            colorIndex: 3
        )
        negotiatedCapabilities = .demo
        guard let store = try await ensureLocalStore() else {
            throw CloudAppModelError.localStoreUnavailable
        }
        try await TelegramFastUITestFixture.install(into: store)
        await afterSignIn()
        if let scenario = TelegramFastUITestFixture.presenceScenario {
            if scenario == "unsupported" {
                negotiatedCapabilities.remove(.presence)
                await presenceCoordinator.configure(
                    store: store, session: fixtureSession.session, enabled: false
                )
            } else {
                await presenceCoordinator.configure(
                    store: store, session: fixtureSession.session, enabled: true
                )
                presenceCoordinator.enableFixturesForTesting()
                await presenceCoordinator.handle(PresenceUpdateHint(
                    type: "presence_update",
                    accountId: TelegramFastUITestFixture.peerAccountId,
                    online: true,
                    lastSeenAt: nil,
                    revision: 1
                ))
                if scenario == "typing" {
                    // Keep the deterministic fixture alive across slow hosted UI automation.
                    // Production typing leases still use the short server-provided expiry.
                    presenceCoordinator.handle(TypingUpdateHint(
                        type: "typing_update",
                        dialogId: TelegramFastUITestFixture.primaryDialogId,
                        actorAccountId: TelegramFastUITestFixture.peerAccountId,
                        typingSessionId: "00000000-0000-4000-8000-000000000701",
                        active: true,
                        expiresInMs: 30_000
                    ))
                }
            }
            if scenario == "offline_override" {
                setReplicaSyncState(.offline)
                status = "Offline fixture — showing saved chats"
            } else {
                setReplicaSyncState(.ready)
                status = "Ready"
            }
        } else {
            setReplicaSyncState(.offline)
            status = "Offline fixture — showing saved chats"
        }
    }
    #endif

    func installBackgroundWorkHandlers() {
        BackgroundRuntimeCoordinator.shared.installWorkHandlers(
            appRefresh: { [weak self] context in
                guard let self else { return .noData }
                do {
                    try context.checkCancellation()
                    let previousPts = await self.pts
                    await self.runCoordinatedSync(trigger: .background)
                    try context.checkCancellation()
                    await self.retryPendingOutbox()
                    try context.checkCancellation()
                    await self.retryPendingDialogPreferences()
                    try context.checkCancellation()
                    await self.retryPendingMessageMutations()
                    try context.checkCancellation()
                    await self.retryPendingReadReceipts()
                    return await self.pts > previousPts ? .completed : .noData
                } catch {
                    return .retry
                }
            },
            processing: { [weak self] context in
                guard let self else { return .noData }
                do {
                    try context.checkCancellation()
                    await self.runCoordinatedSync(trigger: .background)
                    try context.checkCancellation()
                    await self.resumeHistoryHydration()
                    try context.checkCancellation()
                    await self.retryPendingDialogPreferences()
                    try context.checkCancellation()
                    await self.retryPendingReadReceipts()
                    try context.checkCancellation()
                    await self.processMediaDownloadJobs(maximumJobs: 12)
                    try context.checkCancellation()
                    if let coordinator = await self.searchCoordinator {
                        await coordinator.runScheduledMaintenance()
                    }
                    try context.checkCancellation()
                    if let localStore = await self.localStore {
                        await self.mediaEngine.enforceCachePolicy(localStore: localStore)
                    } else {
                        await self.mediaEngine.enforceCachePolicy()
                    }
                    try context.checkCancellation()
                    await self.refreshMediaCacheUsage()
                    return .completed
                } catch {
                    return .retry
                }
            },
            // Search maintenance is local and useful offline. Network-backed work already checks
            // connectivity and remains resumable, so the shared processing task need not require a
            // network before iOS will launch it.
            processingRequiresNetworkConnectivity: false
        )
        BackgroundRuntimeCoordinator.shared.schedulePendingWork()
    }

    func startDialogObservation(accountId: String) {
        dialogObservationTask?.cancel()
        guard let localStore else { return }
        dialogObservationTask = Task { [weak self, localStore] in
            do {
                let values = await localStore.observeDialogs(accountId: accountId)
                for try await localDialogs in values {
                    try Task.checkCancellation()
                    guard let self, self.storedSession?.session.accountId == accountId else { return }
                    self.acceptObservedDialogs(localDialogs)
                }
            } catch is CancellationError {
                return
            } catch {
                guard let self, self.storedSession?.session.accountId == accountId else { return }
                self.status = "Dialog observation paused: \(error.localizedDescription)"
            }
        }
    }

    func startTimelineObservation(dialogId: String) {
        timelineObservationTask?.cancel()
        guard let localStore else {
            conversationOpenState = .failedLocal
            conversationOpenStartedAt.removeValue(forKey: dialogId)
            finishConversationOpenWaiters(dialogId: dialogId)
            return
        }
        timelineObservationTask = Task { [weak self, localStore] in
            do {
                let values = await localStore.observeConversation(dialogId: dialogId, window: .initial)
                for try await snapshot in values {
                    try Task.checkCancellation()
                    guard let self, self.activeDialogId == dialogId else { return }
                    await self.loadLocalLines(dialogId: dialogId, observedSnapshot: snapshot)
                }
            } catch is CancellationError {
                return
            } catch {
                guard let self, self.activeDialogId == dialogId else { return }
                self.conversationOpenState = .failedLocal
                self.status = "Timeline observation paused: \(error.localizedDescription)"
                self.conversationOpenStartedAt.removeValue(forKey: dialogId)
                self.finishConversationOpenWaiters(dialogId: dialogId)
            }
        }
    }

    func startMemoryPressureObservation() {
        guard memoryPressureTask == nil else { return }
        memoryPressureTask = Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(
                named: UIApplication.didReceiveMemoryWarningNotification
            ) {
                guard let self, !Task.isCancelled else { return }
                self.purgePreparedConversations()
                MediaPresentationCache.shared.removeAll()
            }
        }
    }

    func acceptObservedDialogs(_ localDialogs: [LocalDialog]) {
        let previous = Dictionary(uniqueKeysWithValues: dialogs.map { ($0.id, $0) })
        dialogs = localDialogs.map { local in
            var resolved = dialog(from: local)
            let trimmedDraft = local.draftText?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !trimmedDraft.isEmpty {
                resolved.draftPreview = trimmedDraft
            } else if local.draftAttachmentCount > 0 {
                resolved.draftPreview = String(
                    localized: "\(local.draftAttachmentCount) attachments"
                )
            } else if local.hasDraftReply {
                resolved.draftPreview = String(localized: "Reply draft")
            }
            return resolved
        }
        savedMessagesDialogId = localDialogs.first(where: { $0.type == "saved" })?.dialogId
        let directPeers = dialogs.compactMap { dialog in
            dialog.type == "direct" ? dialog.peerAccountId : nil
        }
        Task { [weak self] in
            await self?.presenceCoordinator.updateDirectPeers(directPeers)
        }
        sortDialogsForPresentation()
        if let activeDialogId,
           let removedType = previous[activeDialogId]?.type,
           removedType == "group" || removedType == "saved",
           !dialogs.contains(where: { $0.id == activeDialogId }) {
            self.activeDialogId = nil
            lines = []
            presentNotice(
                removedType == "saved"
                    ? String(localized: "Saved Messages access ended")
                    : String(localized: "Group access ended"),
                message: removedType == "saved"
                    ? String(localized: "The unauthorized Saved Messages offline copy was removed.")
                    : String(localized: "You are no longer a member of this group. Its offline copy was removed.")
            )
        }
    }

    func updateTimelineViewport(
        dialogId: String,
        visibleLineIds: [String],
        isAtBottom: Bool
    ) {
        guard activeDialogId == dialogId else { return }
        let visibleIds = Set(visibleLineIds)
        let topVisibleMsgId = lines.first(where: { visibleIds.contains($0.id) })?.msgId
        timelineTopVisibleMsgId = isAtBottom ? nil : topVisibleMsgId
        timelineIsAtBottom = isAtBottom

        let visibleMessages = loadedLocalMessages.filter { visibleIds.contains($0.localId) }
        pendingVisibleReadMessages = visibleMessages
        let visibleMedia = visibleMessages.compactMap(\.media)
        if !visibleMedia.isEmpty {
            Task { [weak self] in
                guard let self, self.activeDialogId == dialogId else { return }
                await self.queueMediaDownloads(visibleMedia, dialogId: dialogId, visible: true)
                for media in visibleMedia where media.kind == "video" {
                    await self.prewarmStreamingVideoAssetIfLocal(for: media)
                }
            }
        }
        viewportPersistenceTask?.cancel()
        viewportPersistenceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, let self,
                  self.activeDialogId == dialogId,
                  let accountId = self.storedSession?.session.accountId,
                  let localStore = self.localStore else { return }
            let state = ChatViewportState(
                dialogId: dialogId,
                accountId: accountId,
                topVisibleMsgId: topVisibleMsgId,
                wasAtBottom: isAtBottom
            )
            try? await localStore.saveViewportState(state)
            await self.markReadIfNeeded(dialogId: dialogId, messages: visibleMessages)
        }
    }

    func resumeHistoryHydration() async {
        if let historyHydrationTask {
            await withTaskCancellationHandler {
                await historyHydrationTask.value
            } onCancel: {
                historyHydrationTask.cancel()
            }
            return
        }
        guard let token = storedSession?.session.token, localStore != nil else { return }
        let task = Task { [weak self] in
            guard let self else { return }
            await self.hydrateHistoryPages(token: token)
        }
        historyHydrationTask = task
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        historyHydrationTask = nil
    }

    private func hydrateHistoryPages(token: String) async {
        let interval = LocalFirstMetrics.begin("History hydration")
        defer { LocalFirstMetrics.end("History hydration", interval) }
        guard let localStore else { return }
        var pagesSinceYield = 0

        while !Task.isCancelled, storedSession?.session.token == token {
            let activeId = activeDialogId
            let unreadIds = Set(dialogs.lazy.filter { $0.unreadCount > 0 }.map(\.id))
            var priorityIds: [String] = []
            if let activeId { priorityIds.append(activeId) }
            priorityIds.append(contentsOf: dialogs.lazy.filter { $0.unreadCount > 0 }.prefix(199).map(\.id))
            let ready: [DialogHistoryState]
            do {
                let general = try await localStore.historyStatesReady(limit: 100)
                let priority = try await localStore.historyStatesReady(dialogIds: priorityIds)
                ready = Array(Dictionary(
                    (general + priority).map { ($0.dialogId, $0) },
                    uniquingKeysWith: { _, newer in newer }
                ).values)
            } catch {
                return
            }
            guard !ready.isEmpty else { return }

            let network = ReplicaNetworkMonitor.shared.snapshot()
            guard network.allowsEssentialSync else { return }
            let recency = Dictionary(uniqueKeysWithValues: dialogs.enumerated().map { ($0.element.id, $0.offset) })
            let eligible = network.allowsDiscretionaryHydration
                ? ready
                : ready.filter { $0.dialogId == activeId || unreadIds.contains($0.dialogId) }
            if eligible.isEmpty {
                BackgroundRuntimeCoordinator.shared.scheduleProcessing()
                return
            }
            let prioritized = eligible.sorted { lhs, rhs in
                let lhsTier = lhs.dialogId == activeId ? 0 : (unreadIds.contains(lhs.dialogId) ? 1 : 2)
                let rhsTier = rhs.dialogId == activeId ? 0 : (unreadIds.contains(rhs.dialogId) ? 1 : 2)
                if lhsTier != rhsTier { return lhsTier < rhsTier }
                return (recency[lhs.dialogId] ?? .max) < (recency[rhs.dialogId] ?? .max)
            }

            var madeProgress = false
            for state in prioritized {
                if Task.isCancelled || storedSession?.session.token != token { return }
                let beforeMsgId = state.nextBeforeMsgId ?? max(1, state.ceilingMsgId + 1)
                do {
                    let page = try await api.getHistory(
                        dialogId: state.dialogId,
                        beforeMsgId: beforeMsgId,
                        limit: 100,
                        token: token
                    )
                    try await localStore.applyHistoryPage(page)
                    await enqueueArrivalMediaDownloads(page.messages, recentOnly: true)
                    pagesSinceYield += 1
                    madeProgress = true
                } catch is CancellationError {
                    return
                } catch {
                    let delay = retryDelay(forRetryCount: state.retryCount + 1)
                    try? await localStore.markHistoryHydrationFailed(
                        dialogId: state.dialogId,
                        retryAfter: delay
                    )
                    BackgroundRuntimeCoordinator.shared.scheduleProcessing()
                    BackgroundRuntimeCoordinator.shared.scheduleAppRefresh(
                        earliestBeginDate: Date(timeIntervalSinceNow: delay)
                    )
                    if case .authenticationRequired = cloudFailureDisposition(error) { return }
                }
            }
            if !madeProgress { break }
            // Keep long backfills cooperative without imposing a global page cap. The persisted
            // cursor makes every yield/termination resumable.
            if pagesSinceYield >= 24 {
                pagesSinceYield = 0
                await Task.yield()
            }
        }

        if !Task.isCancelled,
           (try? await localStore.historyStatesReady(limit: 1).isEmpty) == false {
            BackgroundRuntimeCoordinator.shared.scheduleProcessing()
        }
    }

    func refreshServerCapabilities() async {
        guard !isSessionTeardownInProgress else { return }
        let accountId = storedSession?.session.accountId
        let token = storedSession?.session.token
        let savedGeneration = savedMessagesSessionGeneration
        let generation = accountSessionGeneration
        let previouslyHadCloudDrafts = negotiatedCapabilities.contains(.cloudDrafts)
        do {
            let response = try await api.capabilities(token: token)
            guard
                !Task.isCancelled,
                savedMessagesSessionGeneration == savedGeneration,
                generation == accountSessionGeneration,
                accountId == storedSession?.session.accountId,
                token == storedSession?.session.token
            else { return }
            var resolved: MessagingCapabilities = []
            let advertised = Set(response.capabilities)
            if advertised.contains("core_text") || advertised.contains("replies") {
                resolved.insert(.replies)
            }
            if advertised.contains("message_mutations") {
                resolved.formUnion([.editing, .deletion])
            }
            if advertised.contains("reactions") { resolved.insert(.reactions) }
            if advertised.contains("forwarding") { resolved.insert(.forwarding) }
            if advertised.contains("media_uploads") { resolved.insert(.media) }
            if advertised.contains("media_multipart_v2"), resolved.contains(.media) {
                resolved.insert(.multipartMedia)
            }
            if advertised.contains("voice_notes"), resolved.contains(.media) {
                resolved.insert(.voiceNotes)
            }
            if advertised.contains("profiles") { resolved.insert(.profiles) }
            if advertised.contains("groups_v1") { resolved.insert(.groups) }
            savedMessagesCapabilityState = .advertised(in: advertised)
            if savedMessagesCapabilityState == .supported {
                resolved.insert(.savedMessages)
            }
            if advertised.contains("cloud_drafts_v1") { resolved.insert(.cloudDrafts) }
            if advertised.contains("media_groups_v1"), resolved.contains(.media) {
                resolved.insert(.mediaGroups)
            }
            if advertised.contains("dialog_preferences_v1") {
                resolved.formUnion([.chatOrganization, .dialogPreferences])
            }
            if advertised.contains("chat_folders_v1") { resolved.insert(.chatFolders) }
            if advertised.contains("scheduled_delivery_v1") { resolved.insert(.scheduledDelivery) }
            if advertised.contains("link_previews_v1") { resolved.insert(.linkPreviews) }
            if advertised.contains("abuse_reports_v1") { resolved.insert(.abuseReports) }
            if advertised.contains("voice_calls_v1"), WebRTCEngineFactory.isAvailable {
                resolved.insert(.calls)
            }
            if advertised.contains("video_calls_v1"), WebRTCEngineFactory.supportsCameraVideoProfile {
                resolved.insert(.videoCalls)
            }
            if advertised.contains("group_calls_v1"), GroupCallEngineFactory.isAvailable {
                resolved.insert(.groupCalls)
            }
            if advertised.contains("group_video_calls_v1"), resolved.contains(.groupCalls) {
                resolved.insert(.groupVideoCalls)
            }
            if advertised.contains("screen_sharing_v1"),
               resolved.contains(.groupCalls),
               GroupCallEngineFactory.supportsScreenShare {
                resolved.insert(.screenSharing)
            }
            if advertised.contains("presence_v1") { resolved.insert(.presence) }
            if advertised.contains("profile_photos_v1"), resolved.contains(.media) {
                resolved.insert(.profilePhotos)
            }
            negotiatedCapabilities = resolved
            await profilePhotoSyncCoordinator.configure(
                store: localStore,
                session: storedSession?.session,
                enabled: resolved.contains(.profilePhotos)
            )
            await presenceCoordinator.configure(
                store: localStore,
                session: storedSession?.session,
                enabled: resolved.contains(.presence)
            )
            await draftSyncCoordinator.configure(
                store: localStore,
                session: storedSession?.session,
                cloudEnabled: resolved.contains(.cloudDrafts)
            )
            if !previouslyHadCloudDrafts,
               resolved.contains(.cloudDrafts),
               let token = storedSession?.session.token {
                // Difference deliberately advances across killed draft events without payloads.
                // A replacement bootstrap is therefore required to recover the current shadows.
                Task { [weak self] in
                    guard let self else { return }
                    try? await self.rebuildLocalReplica(token: token)
                    self.scheduleOutboxRetry()
                }
            }
            // Account-scoped rollout bits must not leak between sign-ins through the server-wide
            // capability cache. A locally materialized Saved Messages row still opens offline.
            capabilityDefaults.set(
                Int(resolved.subtracting([
                    .videoCalls, .savedMessages, .chatFolders, .scheduledDelivery, .linkPreviews,
                    .abuseReports,
                    .presence, .profilePhotos,
                ]).rawValue),
                forKey: capabilityCacheKey
            )
            if resolved.contains(.savedMessages) {
                _ = await ensureSavedMessages(presentsFailure: false)
            }
            await refreshCloudProductivity()
            if let localStore, let accountId = storedSession?.session.accountId {
                if resolved.contains(.chatOrganization) {
                    let reactivated = (try? await localStore
                        .reactivateDormantDialogPreferences(accountId: accountId)) ?? 0
                    guard
                        !Task.isCancelled,
                        !isSessionTeardownInProgress,
                        generation == accountSessionGeneration,
                        accountId == storedSession?.session.accountId
                    else { return }
                    if reactivated > 0 {
                        await retryPendingDialogPreferences()
                    }
                } else if resolved.contains(.groups) {
                    let moved = (try? await localStore.movePendingGroupMutesToLegacy(
                        accountId: accountId
                    )) ?? 0
                    guard
                        !Task.isCancelled,
                        !isSessionTeardownInProgress,
                        generation == accountSessionGeneration,
                        accountId == storedSession?.session.accountId
                    else { return }
                    if moved > 0 {
                        await retryPendingGroupMutations()
                    }
                }
            }
        } catch let error as CloudAPIError where error.status == 404 {
            guard
                !Task.isCancelled,
                savedMessagesSessionGeneration == savedGeneration,
                generation == accountSessionGeneration,
                accountId == storedSession?.session.accountId,
                token == storedSession?.session.token
            else { return }
            negotiatedCapabilities = [.replies]
            savedMessagesCapabilityState = .unsupported
            await draftSyncCoordinator.configure(
                store: localStore,
                session: storedSession?.session,
                cloudEnabled: false
            )
            await presenceCoordinator.configure(
                store: localStore,
                session: storedSession?.session,
                enabled: false
            )
            await profilePhotoSyncCoordinator.configure(
                store: localStore,
                session: storedSession?.session,
                enabled: false
            )
            capabilityDefaults.set(Int(MessagingCapabilities.replies.rawValue), forKey: capabilityCacheKey)
        } catch {
            // Keep the last successfully negotiated set when the server cannot be reached.
        }
    }

    func acceptDraftFlushResult(
        _ result: DraftSyncCoordinator.FlushResult
    ) async -> Bool {
        switch result {
        case .synced:
            return true
        case .unsupported:
            // Withdraw the lane in the same main-actor turn. Durable dependencies remain queued
            // and excluded from retry timing until a later capability refresh re-enables them.
            negotiatedCapabilities.remove(.cloudDrafts)
            await draftSyncCoordinator.configure(
                store: localStore,
                session: storedSession?.session,
                cloudEnabled: false
            )
            Task { [weak self] in await self?.refreshServerCapabilities() }
            return false
        case .retryable, .suspended:
            return false
        case .terminal:
            return false
        }
    }

    func setReplicaSyncState(_ state: ReplicaSyncState) {
        replicaSyncState = state
        switch state {
        case .checking:
            replicaConnectivityState = .checking
            replicaUpdatePhase = .checkingRemoteState
            connectionViewState = .connecting
        case .updating:
            replicaConnectivityState = .reachable
            replicaUpdatePhase = .catchingUp(appliedBatches: appliedSyncBatches)
            connectionViewState = .connecting
        case .ready:
            replicaConnectivityState = .reachable
            replicaUpdatePhase = .upToDate
            connectionViewState = .live
        case .offline:
            replicaConnectivityState = .offline
            replicaUpdatePhase = .idle
            connectionViewState = .offline
        case .connectionSlow:
            replicaConnectivityState = .checking
            replicaUpdatePhase = .stalled(reason: .slowConnection)
            connectionViewState = .connecting
        case .serverUnavailable:
            replicaConnectivityState = .serverUnavailable
            replicaUpdatePhase = .stalled(reason: .serverUnavailable)
            connectionViewState = .connecting
        case .sessionExpired:
            replicaConnectivityState = .sessionExpired
            replicaUpdatePhase = .idle
            connectionViewState = .connecting
        case .protocolFailure:
            replicaConnectivityState = .reachable
            replicaUpdatePhase = .stalled(reason: .protocolFailure)
            connectionViewState = .connecting
        case .localFailure:
            replicaUpdatePhase = .stalled(reason: .localReplicaFailure)
            connectionViewState = .connecting
        case .configurationError:
            replicaConnectivityState = .configurationError
            replicaUpdatePhase = .stalled(reason: .configuration)
            connectionViewState = .connecting
        }
    }
}
