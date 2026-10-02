import Foundation
import Observation
import UIKit

extension CloudAppModel {
    func start() async {
        await prepareForBackgroundRuntime()
        await activateForegroundServices()
    }

    /// Restores the encrypted replica and installs bounded background handlers without starting
    /// sockets, prompting for notifications, or running foreground hydration. UIApplicationDelegate
    /// calls this during a headless BGTask/URLSession launch; the UI calls `start()` on activation.
    func prepareForBackgroundRuntime() async {
        if localRestoreCompleted {
            await finishBackgroundRuntimePreparation()
            return
        }
        if let localRestoreTask {
            await localRestoreTask.value
            await finishBackgroundRuntimePreparation()
            return
        }

        let task = Task { [weak self] in
            guard let self else { return }
            await self.performLocalRestore()
        }
        localRestoreTask = task
        await task.value
        localRestoreTask = nil
        localRestoreCompleted = true
        await finishBackgroundRuntimePreparation()
    }

    private func finishBackgroundRuntimePreparation() async {
        if launchPhase == .localReady, storedSession != nil {
            await prepareBackgroundMediaRuntime()
        } else {
            BackgroundRuntimeCoordinator.shared.completePendingTasksWithNoData()
        }
    }

    private func performLocalRestore() async {
        let launchInterval = LocalFirstMetrics.begin("Local restore")
        defer { LocalFirstMetrics.end("Local restore", launchInterval) }
        launchPhase = .restoringLocal
        do {
            #if DEBUG
            if TelegramFastUITestFixture.enabled {
                try await installTelegramFastUITestFixture()
                return
            }
            #endif
            let pendingRevocations = try await tokenStore.loadPendingRevocations()
            let pendingLocalErasure = try await tokenStore.hasPendingLocalErasure()
            let pendingReauthentication = try await tokenStore
                .loadPendingReauthenticationAccountId()
            let savedSession = try await tokenStore.load()
            let launchAction = PendingRevocationLaunchPolicy.action(
                savedSession: savedSession,
                pendingRevocations: pendingRevocations,
                hasPendingLocalErasure: pendingLocalErasure,
                pendingReauthenticationAccountId: pendingReauthentication
            )
            if case .eraseLocalReplica = launchAction, !pendingLocalErasure {
                // Remote revocation can clear its own marker before the longer teardown reaches
                // disk. Persist destructive intent first so a crash in that window still erases
                // the replica on the next launch.
                let accountId = savedSession?.session.accountId
                    ?? pendingRevocations.first(where: \.eraseLocalReplicaOnLaunch)?
                        .localReplicaAccountId
                try await tokenStore.savePendingLocalErasure(accountId: accountId)
            } else if case let .requireAuthentication(localReplicaAccountId) = launchAction,
                      let accountId = localReplicaAccountId ?? savedSession?.session.accountId {
                // A revocation retry may clear its own token marker at any moment. Establish the
                // independent local-replica fence first so successful remote cleanup cannot make a
                // later launch forget that reauthentication is still required.
                try await tokenStore.savePendingReauthentication(accountId: accountId)
            }
            for pendingRevocation in pendingRevocations {
                Task { [weak self] in await self?.revokeSignedOutToken(pendingRevocation.token) }
            }
            switch launchAction {
            case .eraseLocalReplica:
                // Sign-out was interrupted. Restore only enough identity to erase its profile,
                // then finish deleting SQLCipher, its key, media, and Keychain session data.
                storedSession = savedSession
                await clearLocalSession(finalStatus: "Signed out")
                return
            case let .requireAuthentication(localReplicaAccountId):
                if let savedSession {
                    // Launch has not installed credentials or started account work yet. Remove only
                    // this stale session while retaining the independent replica-authentication
                    // marker; a different-account credential is also queued for remote cleanup.
                    if let localReplicaAccountId,
                       savedSession.session.accountId != localReplicaAccountId {
                        try await tokenStore.savePendingRevocationToken(
                            savedSession.session.token,
                            eraseLocalReplicaOnLaunch: false,
                            localReplicaAccountId: localReplicaAccountId
                        )
                        Task { [weak self] in
                            await self?.revokeSignedOutToken(savedSession.session.token)
                        }
                    }
                    try await tokenStore.clearSession(ifTokenMatches: savedSession.session.token)
                }
                expiredSessionAccountId = localReplicaAccountId
                    ?? savedSession?.session.accountId
                launchPhase = .localReady
                setReplicaSyncState(.sessionExpired)
                status = "Session expired. Sign in again to resume your saved chats."
                return
            case .restoreSavedSession:
                break
            }
            if let saved = savedSession {
                isSessionTeardownInProgress = false
                installAuthenticatedSession(saved)
                phone = saved.phone
                displayName = saved.displayName
                await loadProfileDetails()
                status = "Signed in"
                setReplicaSyncState(.checking)
                await afterSignIn()
            } else {
                status = "Signed out"
                launchPhase = .signedOut
            }
        } catch {
            status = "Session restore failed: \(error.localizedDescription)"
            setReplicaSyncState(.localFailure)
            launchPhase = storedSession == nil ? .signedOut : .recoveringStore
        }
    }

    func retryLocalRecovery() async {
        guard let saved = storedSession else {
            launchPhase = .signedOut
            return
        }
        launchPhase = .restoringLocal
        do {
            // A remote authenticated read is the safety gate: an unreadable replica is preserved
            // until we know its cloud source still exists and this session may rebuild it.
            _ = try await api.getState(token: saved.session.token)
            localStore = try await localStoreBootstrapper.quarantineAndOpenDefaultStore()
            backgroundMediaRuntimePrepared = false
            try await rebuildLocalReplica(token: saved.session.token)
            await afterSignIn()
            await prepareBackgroundMediaRuntime()
            await activateForegroundServices()
        } catch {
            status = "Recovery paused: \(error.localizedDescription)"
            setReplicaSyncState(Self.replicaFailureState(
                for: error,
                network: ReplicaNetworkMonitor.shared.snapshot()
            ))
            launchPhase = .recoveringStore
        }
    }
}
