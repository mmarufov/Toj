import Foundation
import Observation
import UIKit

extension CloudAppModel {
    func startNetworkObservation() {
        networkObservationTask?.cancel()
        networkObservationTask = Task { [weak self] in
            var previous = ReplicaNetworkClass.unknown
            for await snapshot in ReplicaNetworkMonitor.shared.updates() {
                guard let self, !Task.isCancelled else { return }
                await self.mediaPrefetchScheduler.update(
                    networkClass: snapshot.networkClass,
                    foregrounded: self.mediaSchedulerForegrounded
                )
                let recovered = previous == .offline && snapshot.networkClass != .offline
                previous = snapshot.networkClass
                if snapshot.networkClass == .offline {
                    self.scheduleOfflineStatePaint()
                    continue
                }
                self.cancelOfflineStatePaint()
                guard recovered else { continue }
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled,
                      ReplicaNetworkMonitor.shared.snapshot().networkClass != .offline else { continue }
                await self.replicaSyncCoordinator.trigger(.pathRecovery)
                self.scheduleMediaDownloadProcessing()
                await self.resumeHistoryHydration()
            }
        }
    }

    /// Interface handoffs (Wi-Fi ↔ cellular) report sub-second unsatisfied paths. Painting the
    /// offline banner is debounced so only a real outage is announced; sync and media gating read
    /// live snapshots and are unaffected by the delay.
    private func scheduleOfflineStatePaint() {
        guard offlinePaintTask == nil else { return }
        offlinePaintTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(1500))
            guard let self, !Task.isCancelled else { return }
            self.offlinePaintTask = nil
            guard ReplicaNetworkMonitor.shared.snapshot().networkClass == .offline else { return }
            self.setReplicaSyncState(.offline)
            self.status = String(localized: "Offline. Showing downloaded conversations.")
        }
    }

    private func cancelOfflineStatePaint() {
        offlinePaintTask?.cancel()
        offlinePaintTask = nil
    }

    nonisolated static func replicaFailureState(
        for error: Error,
        network: ReplicaNetworkSnapshot
    ) -> ReplicaSyncState {
        if error is CancellationError || (error as? URLError)?.code == .cancelled {
            return .checking
        }
        if network.networkClass == .offline { return .offline }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .internationalRoamingOff, .dataNotAllowed:
                return .offline
            case .timedOut:
                return .connectionSlow
            case .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed,
                 .networkConnectionLost, .badServerResponse:
                return .serverUnavailable
            default:
                return .serverUnavailable
            }
        }
        if let apiError = error as? CloudAPIError {
            switch apiError.status {
            case 401, 403: return .sessionExpired
            case 408, 429, 500...599: return .serverUnavailable
            default: return .protocolFailure
            }
        }
        if error is DecodingError { return .protocolFailure }
        return .localFailure
    }

    func publishTransportFailure(_ error: Error) {
        let failure = Self.replicaFailureState(
            for: error,
            network: ReplicaNetworkMonitor.shared.snapshot()
        )
        switch failure {
        case .offline, .connectionSlow, .serverUnavailable, .sessionExpired:
            setReplicaSyncState(failure)
        case .checking, .updating, .ready, .protocolFailure, .localFailure, .configurationError:
            break
        }
    }

    func presentNotice(_ title: String, message: String, opensSettings: Bool = false) {
        if let pending = pendingProductivityTerminalNotice,
           operationNotice?.id == pending.noticeId {
            // A higher-priority notice may replace this alert, but the journal error stays
            // unacknowledged and will be offered again by the next productivity drain.
            pendingProductivityTerminalNotice = nil
        }
        operationNotice = Notice(title: title, message: message, opensSettings: opensSettings)
    }

    func uploadPushToken(_ deviceToken: String, environment: String) async {
        guard let token = storedSession?.session.token else { return }
        let registration = "\(environment):\(deviceToken)"
        guard uploadedPushRegistration != registration else { return }
        do {
            _ = try await api.registerPushToken(deviceToken, environment: environment, token: token)
            guard storedSession?.session.token == token else {
                // Registration and sign-out can overlap at an await point. If sign-out won the
                // race, undo this late registration so the signed-out device receives no alerts.
                _ = try? await api.unregisterPushToken(token: token)
                return
            }
            uploadedPushRegistration = registration
        } catch {
            // Token registration is retried when APNs rotates the token or on the next app launch.
            status = "Push registration failed: \(error.localizedDescription)"
        }
    }

    func uploadVoIPPushToken(_ deviceToken: String?, environment: String) async {
        guard let token = storedSession?.session.token else { return }
        guard let deviceToken, callCoordinator.canRegisterForIncomingCalls else {
            // Token rotation and permission changes can race the normal resume path. Always clear
            // the server registration when this installation cannot answer; otherwise a later
            // PushKit callback could silently make a microphone-denied device callable again.
            _ = try? await api.unregisterVoIPPushToken(token: token)
            uploadedVoIPPushRegistration = nil
            return
        }
        let capabilities = WebRTCEngineFactory.deviceCapabilities
        let groupCapabilities = GroupCallEngineFactory.deviceCapabilities
        let registration = [
            environment,
            deviceToken,
            capabilities.supportedCallProtocolVersions.map(String.init).joined(separator: ","),
            capabilities.supportedCallMediaProfileVersions.map(String.init).joined(separator: ","),
            String(capabilities.callViewVersion),
            groupCapabilities.supportedGroupCallVersions.map(String.init).joined(separator: ","),
            String(groupCapabilities.groupCallViewVersion),
            String(groupCapabilities.supportsGroupScreenShare),
        ].joined(separator: ":")
        guard uploadedVoIPPushRegistration != registration else { return }
        do {
            _ = try await api.registerVoIPPushToken(
                deviceToken,
                environment: environment,
                token: token,
                capabilities: capabilities,
                groupCapabilities: groupCapabilities
            )
            guard storedSession?.session.token == token,
                  callCoordinator.canRegisterForIncomingCalls else {
                _ = try? await api.unregisterVoIPPushToken(token: token)
                uploadedVoIPPushRegistration = nil
                return
            }
            uploadedVoIPPushRegistration = registration
        } catch {
            status = "Call push registration failed: \(error.localizedDescription)"
        }
    }

    private func syncGroupCallCapabilities() async {
        guard let token = storedSession?.session.token else { return }
        let capabilities = GroupCallEngineFactory.deviceCapabilities
        let registration = [
            capabilities.supportedGroupCallVersions.map(String.init).joined(separator: ","),
            String(capabilities.groupCallViewVersion),
            String(capabilities.supportsGroupScreenShare),
        ].joined(separator: ":")
        guard uploadedGroupCallCapabilityRegistration != registration else { return }
        do {
            _ = try await api.registerGroupCallCapabilities(capabilities, token: token)
            guard storedSession?.session.token == token else { return }
            uploadedGroupCallCapabilityRegistration = registration
        } catch {
            // Capability registration is retried on foreground and post-sync. Until then the
            // backend treats this device as legacy and will not admit it to a group media room.
            status = "Group call registration failed: \(error.localizedDescription)"
        }
    }

    func syncFromPush() async -> Bool {
        let previousPts = pts
        await runCoordinatedSync(trigger: .push)
        return pts > previousPts
    }

    func resume() async {
        #if DEBUG
        if isDemoMode { return }
        #endif
        guard let token = storedSession?.session.token else { return }
        setReplicaSyncState(.checking)
        status = "Checking connection"
        pushCenter.refreshRegistration()
        await syncGroupCallCapabilities()
        if capabilities.contains(.calls) {
            await syncVoIPCallingAvailability()
        }
        await startHints(token: token)
        scheduleSync(trigger: .foreground)
        scheduleOutboxRetry()
    }

    func retryReplicaSync() {
        #if DEBUG
        if isDemoMode { return }
        #endif
        guard launchPhase == .localReady, storedSession?.session.token != nil else { return }
        setReplicaSyncState(.checking)
        status = "Checking connection"
        scheduleSync(trigger: .manualRetry)
    }

    private func syncVoIPCallingAvailability() async {
        guard let token = storedSession?.session.token else { return }
        if callCoordinator.canRegisterForIncomingCalls {
            voipPushCenter.refreshRegistration()
        } else {
            _ = try? await api.unregisterVoIPPushToken(token: token)
            uploadedVoIPPushRegistration = nil
        }
    }

    func startHints(token: String) async {
        // The socket is long-lived: it survives sync passes and reconnects itself with jittered
        // backoff. Only a token change (or an explicit stop) replaces it — cycling it on every
        // sync pass would burn round-trips and drop hints raised during each teardown window.
        if hintSocketToken == token, hintSocket != nil, hintTask?.isCancelled == false { return }
        hintTask?.cancel()
        await hintSocket?.stop()

        let socket = CloudHintSocket(url: api.config.wsURL(), token: token)
        hintSocket = socket
        hintSocketToken = token
        await presenceCoordinator.attach(socket: socket)
        hintTask = Task { [weak self, socket] in
            await socket.start()
            await withTaskGroup(of: Void.self) { group in
                group.addTask { [weak self, socket] in
                    for await event in socket.events {
                        guard let self,
                              !Task.isCancelled,
                              await self.isCurrentHintSocket(socket, token: token)
                        else { return }
                        switch event {
                        case .sync(let hint):
                            // The payload carries the account cursor; skip the probe entirely when
                            // the local replica is already at (or past) it.
                            let localPts = await self.pts
                            guard hint.pts > localPts else { continue }
                            await self.replicaSyncCoordinator.trigger(.hint)
                        case .call(let hint):
                            await self.callCoordinator.handle(hint)
                        case .groupCall(let hint):
                            await self.groupCallCoordinator.handle(hint)
                        case .sessionRevoked:
                            // Routed through the dedicated lossless control stream below.
                            continue
                        case .presence(let hint):
                            await self.presenceCoordinator.handle(hint)
                        case .presenceVisibility(let hint):
                            await self.presenceCoordinator.handle(hint)
                        case .typing(let hint):
                            await self.presenceCoordinator.handle(hint)
                        }
                    }
                }
                group.addTask { [weak self, socket] in
                    for await hint in socket.revocations {
                        guard let self,
                              !Task.isCancelled,
                              await self.isCurrentHintSocket(socket, token: token)
                        else { return }
                        guard await self.scheduleSessionClearFromRevokedHint(
                            deviceId: hint.deviceId
                        ) != nil else { continue }
                        // Teardown runs outside this exact hintTask so it can cancel and await all
                        // socket loops without ever awaiting itself.
                        return
                    }
                }
                group.addTask { [weak self, socket] in
                    var hasConnected = false
                    for await state in socket.states {
                        guard let self,
                              !Task.isCancelled,
                              await self.isCurrentHintSocket(socket, token: token)
                        else { return }
                        await self.presenceCoordinator.transportChanged(state)
                        guard state == .connected else { continue }
                        if hasConnected {
                            await self.replicaSyncCoordinator.trigger(.socketReconnect)
                            await self.callCoordinator.reconcileActiveCalls()
                            await self.groupCallCoordinator.reconcileAfterSocketReconnect()
                        }
                        hasConnected = true
                    }
                }
                await group.waitForAll()
            }
        }
    }

    private func isCurrentHintSocket(_ socket: CloudHintSocket, token: String) -> Bool {
        hintSocket === socket
            && hintSocketToken == token
            && storedSession?.session.token == token
            && !sessionTeardownActive
    }

    @discardableResult
    func scheduleSessionClearFromRevokedHint(
        deviceId: String?
    ) -> Task<Void, Never>? {
        let applies = deviceId == nil || deviceId == storedSession?.session.deviceId
        guard applies else { return nil }
        return Task { [weak self] in
            await self?.clearLocalSession(finalStatus: "Session ended")
        }
    }

    func scheduleSync(trigger: ReplicaSyncTrigger = .hint) {
        Task { [replicaSyncCoordinator] in
            await replicaSyncCoordinator.trigger(trigger)
        }
    }

    /// Runs one coordinated sync pass and waits for the coordinator to drain. Every sync entry
    /// point funnels through the coordinator (here or via `scheduleSync`) so passes are
    /// serialized and an overlap can never be misreported as a network failure.
    func runCoordinatedSync(trigger: ReplicaSyncTrigger) async {
        await replicaSyncCoordinator.trigger(trigger)
        await replicaSyncCoordinator.waitUntilIdle()
    }

    /// A cancelled or replaced attempt can return without publishing a state. Once the coordinator
    /// drains, a pill still stuck on progress means no pass owns it — retrigger once so the state
    /// always settles to ready or a retryable failure.
    func settleReplicaSyncStateAfterAttempt() {
        Task { [weak self] in
            guard let self else { return }
            await self.replicaSyncCoordinator.waitUntilIdle()
            guard self.replicaSyncState.showsProgress,
                  self.storedSession?.session.token != nil else { return }
            await self.replicaSyncCoordinator.trigger(.hint)
        }
    }

    func runForegroundSyncAttempt(generation: UInt64) async {
        guard let token = storedSession?.session.token else { return }
        if let issue = api.config.validationIssue() {
            setReplicaSyncState(.configurationError)
            status = issue.message
            return
        }
        let initialNetwork = ReplicaNetworkMonitor.shared.snapshot()
        if initialNetwork.networkClass == .offline {
            setReplicaSyncState(.offline)
            status = String(localized: "Offline. Showing downloaded conversations.")
            return
        }
        let api = api
        let timeout = Self.foregroundSyncTimeoutSeconds
        let probeInterval = LocalFirstMetrics.begin("Sync probe")
        let deadline = await ReplicaDeadline.run(for: .seconds(timeout)) { [api, token, initialNetwork] in
            do {
                let state = try await api.getState(token: token)
                try Task.checkCancellation()
                return ReplicaStateProbeOutcome.succeeded(state)
            } catch is CancellationError {
                return .cancelled
            } catch {
                return .failed(Self.replicaFailureState(for: error, network: initialNetwork))
            }
        }
        let outcome: ReplicaStateProbeOutcome = switch deadline {
        case .value(let value): value
        case .timedOut: .timedOut
        case .cancelled: .cancelled
        }
        LocalFirstMetrics.end("Sync probe", probeInterval)

        guard await replicaSyncCoordinator.isCurrent(generation),
              storedSession?.session.token == token else { return }
        switch outcome {
        case .succeeded(let remoteState):
            lastSuccessfulServerContact = Date()
            if remoteState.pts < pts {
                setReplicaSyncState(.protocolFailure)
                status = String(localized: "Server update state moved backwards. Showing the offline copy.")
                return
            }
            let replicaInitialized = if let localStore,
                                        let accountId = storedSession?.session.accountId {
                (try? await localStore.isReplicaInitialized(accountId: accountId)) == true
            } else {
                false
            }
            guard await replicaSyncCoordinator.isCurrent(generation),
                  storedSession?.session.token == token else { return }
            if replicaInitialized, remoteState.pts == pts {
                setReplicaSyncState(.ready)
                status = "Chats are up to date"
                schedulePostSyncWork(token: token)
                return
            }
            appliedSyncBatches = 0
            lastForegroundSyncFailure = nil
            await markReplicaUpdating(generation: generation, token: token)
            let succeeded = await syncNow(publishesConnectionState: false)
            guard await replicaSyncCoordinator.isCurrent(generation),
                  storedSession?.session.token == token,
                  !Task.isCancelled else { return }
            guard succeeded else {
                let failure = lastForegroundSyncFailure ?? .serverUnavailable
                setReplicaSyncState(failure)
                status = failure.title
                return
            }
            setReplicaSyncState(.ready)
            status = "Chats are up to date"
            schedulePostSyncWork(token: token)
        case .failed(let failure):
            setReplicaSyncState(failure)
            status = failure.title
        case .timedOut:
            setReplicaSyncState(.connectionSlow)
            status = String(localized: "Connection is slow. Showing the offline copy.")
        case .cancelled:
            return
        }
    }

    private func markReplicaUpdating(generation: UInt64, token: String) async {
        guard await replicaSyncCoordinator.isCurrent(generation),
              storedSession?.session.token == token else { return }
        setReplicaSyncState(.updating)
        status = "Updating chats"
    }

    private func stopHints() async {
        hintTask?.cancel()
        hintTask = nil
        await hintSocket?.stop()
        hintSocket = nil
        hintSocketToken = nil
        await presenceCoordinator.attach(socket: nil)
    }

    private func schedulePostSyncWork(token: String) {
        postSyncWorkTask?.cancel()
        postSyncWorkTask = Task(priority: .utility) { [weak self] in
            do {
                // Let the freshly updated list and the user's first chat tap get main-thread and
                // SQLCipher priority before discretionary reconciliation starts.
                try await Task.sleep(for: .milliseconds(500))
            } catch {
                return
            }
            guard let self, self.storedSession?.session.token == token else { return }
            await self.syncGroupCallCapabilities()
            // Group-call advertisement is device-scoped. Register the upgraded binary first so
            // this same refresh can observe the capability instead of waiting for another launch.
            await self.refreshServerCapabilities()
            if self.capabilities.contains(.calls) {
                await self.syncVoIPCallingAvailability()
            }
            self.reconcileProfileWithServer()
            await self.refreshMediaCacheUsage()
            await self.loadMediaPolicies()
            await self.retryPendingMessageMutations()
            await self.retryPendingGroupMutations()
            await self.retryPendingDialogPreferences()
            await self.retryPendingReadReceipts()
            await self.retryMediaTransfers()
            self.scheduleMediaDownloadProcessing()
            self.scheduleOutboxRetry()
            await self.resumeHistoryHydration()
            if self.storedSession?.session.token == token {
                self.postSyncWorkTask = nil
            }
        }
    }

    func scheduleOutboxRetry(after delay: TimeInterval = 0) {
        guard retryTask == nil else { return }
        retryTask = Task { [weak self] in
            if delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                if Task.isCancelled { return }
            }

            await self?.retryPendingOutbox()
            let nextDelay = await self?.nextOutboxRetryDelay()
            await MainActor.run {
                self?.retryTask = nil
            }
            if let nextDelay {
                await MainActor.run {
                    self?.scheduleOutboxRetry(after: nextDelay)
                }
            }
        }
    }

    @discardableResult
    private func syncNow(publishesConnectionState: Bool = true) async -> Bool {
        let syncInterval = LocalFirstMetrics.begin("Difference sync")
        defer { LocalFirstMetrics.end("Difference sync", syncInterval) }
        guard let token = storedSession?.session.token else { return false }
        if syncInFlight {
            // Every entry point funnels through ReplicaSyncCoordinator, so overlap indicates a
            // programming error — never a network failure. Ask the active pass to loop once more
            // rather than misreporting the connection state.
            assertionFailure("syncNow is expected to run only via ReplicaSyncCoordinator")
            syncAgain = true
            return false
        }

        syncInFlight = true
        defer { syncInFlight = false }

        repeat {
            syncAgain = false
            do {
                if let localStore,
                   let accountId = storedSession?.session.accountId,
                   !(try await localStore.isReplicaInitialized(accountId: accountId)) {
                    // A new device has no meaningful difference cursor yet. Bootstrap first even
                    // when the server could technically return a small difference from PTS zero.
                    // Returning devices skip this path and render their encrypted replica instantly.
                    try await rebuildLocalReplica(token: token)
                }
                var response = try await fetchDifferencePage(token: token)
                while true {
                    if response.kind == "difference_too_long" {
                        try await rebuildLocalReplica(token: token)
                        response = try await fetchDifferencePage(token: token)
                        continue
                    }
                    try await applyDifferencePage(response)
                    pts = response.state.pts
                    appliedSyncBatches += 1
                    if !publishesConnectionState {
                        setReplicaSyncState(.updating)
                    }
                    if response.kind != "difference_slice" { break }
                    response = try await fetchDifferencePage(token: token)
                }
                if publishesConnectionState {
                    setReplicaSyncState(.ready)
                    status = "Chats are up to date"
                    schedulePostSyncWork(token: token)
                }
            } catch {
                if Task.isCancelled
                    || (error as? URLError)?.code == .cancelled {
                    return false
                }
                status = "Sync failed: \(error.localizedDescription)"
                let failure = Self.replicaFailureState(
                    for: error,
                    network: ReplicaNetworkMonitor.shared.snapshot()
                )
                lastForegroundSyncFailure = failure
                if publishesConnectionState {
                    setReplicaSyncState(failure)
                }
                return false
            }
        } while syncAgain
        return true
    }

    private func fetchDifferencePage(token: String) async throws -> DifferenceResponse {
        let interval = LocalFirstMetrics.begin("Sync difference page")
        defer { LocalFirstMetrics.end("Sync difference page", interval) }
        let limits = Self.differenceRequestLimits(
            for: ReplicaNetworkMonitor.shared.snapshot()
        )
        return try await api.getDifference(
            sincePts: pts,
            maxEvents: limits.maxEvents,
            maxBytes: limits.maxBytes,
            token: token
        )
    }

    private func applyDifferencePage(_ response: DifferenceResponse) async throws {
        let interval = LocalFirstMetrics.begin("Sync apply page")
        defer { LocalFirstMetrics.end("Sync apply page", interval) }
        try await apply(response)
    }

    nonisolated static func differenceRequestLimits(
        for network: ReplicaNetworkSnapshot
    ) -> (maxEvents: Int, maxBytes: Int) {
        switch network.networkClass {
        case .wifi:
            (200, 256 * 1_024)
        case .cellular:
            (100, 128 * 1_024)
        case .unknown, .offline, .constrained, .roaming:
            (50, 64 * 1_024)
        }
    }
}
