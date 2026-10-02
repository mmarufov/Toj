import Foundation

nonisolated enum ProfilePhotoSyncState: Equatable, Sendable {
    case localOnly
    case synced
    case pending
    case failed(String)
    case conflict
}

nonisolated enum ProfilePhotoCommitResult: Sendable {
    case idle
    case committed(CloudProfile)
    case superseded(CloudProfile)
    case retrying(String, TimeInterval)
    case failed(String)
    case conflict
    case cancelled
}

/// Owns the profile-photo mutation lane so it cannot become another collection of ad-hoc
/// `CloudAppModel` flags. The SQLCipher store remains the source of truth across process death.
actor ProfilePhotoSyncCoordinator {
    private let api: CloudAPI
    private let mediaEngine: CloudMediaTransferEngine
    private var store: CloudLocalStore?
    private var session: CloudSession?
    private var generation: UInt64 = 0
    private var enabled = false
    private var inFlightCommit: (generation: UInt64, clientMutationId: String)?

    init(api: CloudAPI, mediaEngine: CloudMediaTransferEngine) {
        self.api = api
        self.mediaEngine = mediaEngine
    }

    func configure(store: CloudLocalStore?, session: CloudSession?, enabled: Bool) {
        let sameStore: Bool
        switch (self.store, store) {
        case (nil, nil):
            sameStore = true
        case let (current?, next?):
            sameStore = current === next
        default:
            sameStore = false
        }
        guard !sameStore || self.session != session || self.enabled != enabled else { return }
        generation &+= 1
        self.store = store
        self.session = session
        self.enabled = enabled
    }

    func pending() async -> PendingProfilePhotoMutation? {
        guard let store, let accountId = session?.accountId else { return nil }
        return try? await store.pendingProfilePhotoMutation(accountId: accountId)
    }

    func stageSet(
        prepared: PreparedMediaUpload,
        baseRevision: Int64,
        source: String = "user"
    ) async throws -> PendingProfilePhotoMutation {
        guard enabled, let store, let session else {
            throw ProfilePhotoCoordinatorError.unavailable
        }
        let expectedGeneration = generation
        let previous = try await store.pendingProfilePhotoMutation(accountId: session.accountId)
        try ensureCurrent(generation: expectedGeneration, store: store, session: session)
        let previousTransfer: MediaTransferRecord?
        if let transferId = previous?.transferId {
            previousTransfer = try await store.mediaTransfer(id: transferId)
            try ensureCurrent(generation: expectedGeneration, store: store, session: session)
        } else {
            previousTransfer = nil
        }
        let mutation: PendingProfilePhotoMutation
        do {
            mutation = try await store.stageProfilePhotoSet(
                accountId: session.accountId,
                prepared: prepared,
                basePhotoRevision: baseRevision,
                source: source
            )
        } catch {
            await mediaEngine.discardPrepared(prepared)
            throw error
        }
        do {
            try ensureCurrent(generation: expectedGeneration, store: store, session: session)
            if let previousTransfer { await mediaEngine.discardTransfer(previousTransfer) }
            try ensureCurrent(generation: expectedGeneration, store: store, session: session)
            return mutation
        } catch {
            // The SQLCipher write may finish after sign-out or a genuine capability transition.
            // Remove only this exact intent and erase both now-unreferenced encrypted payloads.
            _ = try? await store.discardProfilePhotoMutation(
                accountId: session.accountId,
                clientMutationId: mutation.clientMutationId
            )
            await mediaEngine.discardPrepared(prepared)
            if let previousTransfer { await mediaEngine.discardTransfer(previousTransfer) }
            throw CancellationError()
        }
    }

    func stageRemoval(baseRevision: Int64) async throws -> PendingProfilePhotoMutation {
        guard enabled, let store, let session else {
            throw ProfilePhotoCoordinatorError.unavailable
        }
        let expectedGeneration = generation
        let previous = try await store.pendingProfilePhotoMutation(accountId: session.accountId)
        try ensureCurrent(generation: expectedGeneration, store: store, session: session)
        let previousTransfer: MediaTransferRecord?
        if let transferId = previous?.transferId {
            previousTransfer = try await store.mediaTransfer(id: transferId)
            try ensureCurrent(generation: expectedGeneration, store: store, session: session)
        } else {
            previousTransfer = nil
        }
        let mutation = try await store.stageProfilePhotoRemoval(
            accountId: session.accountId,
            basePhotoRevision: baseRevision
        )
        do {
            try ensureCurrent(generation: expectedGeneration, store: store, session: session)
            if let previousTransfer { await mediaEngine.discardTransfer(previousTransfer) }
            try ensureCurrent(generation: expectedGeneration, store: store, session: session)
            return mutation
        } catch {
            _ = try? await store.discardProfilePhotoMutation(
                accountId: session.accountId,
                clientMutationId: mutation.clientMutationId
            )
            if let previousTransfer { await mediaEngine.discardTransfer(previousTransfer) }
            throw CancellationError()
        }
    }

    func markUploaded(transferId: String, mediaId: String) async throws {
        guard let store, let session else { throw ProfilePhotoCoordinatorError.unavailable }
        let expectedGeneration = generation
        try await store.markProfilePhotoUploaded(transferId: transferId, mediaId: mediaId)
        try ensureCurrent(generation: expectedGeneration, store: store, session: session)
    }

    func commitReady() async -> ProfilePhotoCommitResult {
        guard enabled, let store, let session else { return .idle }
        let expectedGeneration = generation
        guard inFlightCommit?.generation != expectedGeneration else { return .idle }
        guard let mutation = try? await store.readyProfilePhotoMutation(accountId: session.accountId) else {
            return .idle
        }
        guard isCurrent(generation: expectedGeneration, store: store, session: session) else {
            return .cancelled
        }
        inFlightCommit = (expectedGeneration, mutation.clientMutationId)
        defer {
            if inFlightCommit?.generation == expectedGeneration,
               inFlightCommit?.clientMutationId == mutation.clientMutationId {
                inFlightCommit = nil
            }
        }
        do {
            let response = try await api.updateProfilePhoto(
                mediaId: mutation.operation == "remove" ? nil : mutation.mediaId,
                clientMutationId: mutation.clientMutationId,
                basePhotoRevision: mutation.basePhotoRevision,
                token: session.token
            )
            try Task.checkCancellation()
            try ensureCurrent(generation: expectedGeneration, store: store, session: session)

            let transfer: MediaTransferRecord?
            if let transferId = mutation.transferId {
                transfer = try? await store.mediaTransfer(id: transferId)
                try ensureCurrent(generation: expectedGeneration, store: store, session: session)
            } else {
                transfer = nil
            }
            if let transfer {
                let promoted = await mediaEngine.finishUpload(transfer, localStore: store)
                try ensureCurrent(generation: expectedGeneration, store: store, session: session)
                if !promoted {
                    await mediaEngine.discardTransfer(transfer)
                    try ensureCurrent(generation: expectedGeneration, store: store, session: session)
                }
            }
            let completed = try await store.completeProfilePhotoMutation(
                accountId: session.accountId,
                clientMutationId: mutation.clientMutationId,
                profile: response.profile
            )
            try ensureCurrent(generation: expectedGeneration, store: store, session: session)
            return completed ? .committed(response.profile) : .superseded(response.profile)
        } catch is CancellationError {
            return .cancelled
        } catch {
            guard isCurrent(generation: expectedGeneration, store: store, session: session) else {
                return .cancelled
            }
            if let apiError = error as? CloudAPIError,
               apiError.status == 409 || apiError.code == "stale_profile_photo" {
                let failed = try? await store.failProfilePhotoMutation(
                    accountId: session.accountId,
                    clientMutationId: mutation.clientMutationId,
                    error: apiError.localizedDescription,
                    retryAfter: nil,
                    conflict: true
                )
                guard isCurrent(generation: expectedGeneration, store: store, session: session) else {
                    return .cancelled
                }
                guard failed == true else { return .idle }
                return .conflict
            }
            switch cloudFailureDisposition(error) {
            case let .transient(serverDelay):
                let delay = serverDelay ?? min(300, pow(2, Double(mutation.retryCount + 1)))
                let failed = try? await store.failProfilePhotoMutation(
                    accountId: session.accountId,
                    clientMutationId: mutation.clientMutationId,
                    error: error.localizedDescription,
                    retryAfter: delay
                )
                guard isCurrent(generation: expectedGeneration, store: store, session: session) else {
                    return .cancelled
                }
                guard failed == true else { return .idle }
                return .retrying(error.localizedDescription, delay)
            case .authenticationRequired:
                return .cancelled
            case .unsupportedServer:
                return .failed(String(localized: "Profile photo sync is unavailable."))
            case .permanent:
                let failed = try? await store.failProfilePhotoMutation(
                    accountId: session.accountId,
                    clientMutationId: mutation.clientMutationId,
                    error: error.localizedDescription,
                    retryAfter: nil,
                    terminal: true
                )
                guard isCurrent(generation: expectedGeneration, store: store, session: session) else {
                    return .cancelled
                }
                guard failed == true else { return .idle }
                return .failed(error.localizedDescription)
            }
        }
    }

    func useCloudPhoto() async throws -> CloudProfile {
        guard let store, let session else { throw ProfilePhotoCoordinatorError.unavailable }
        let expectedGeneration = generation
        let pending = try await store.pendingProfilePhotoMutation(accountId: session.accountId)
        try ensureCurrent(generation: expectedGeneration, store: store, session: session)
        let transfer: MediaTransferRecord?
        if let transferId = pending?.transferId {
            transfer = try await store.mediaTransfer(id: transferId)
            try ensureCurrent(generation: expectedGeneration, store: store, session: session)
        } else {
            transfer = nil
        }
        let profile = try await api.getProfile(token: session.token)
        try ensureCurrent(generation: expectedGeneration, store: store, session: session)
        if let pending {
            let discarded = try await store.discardProfilePhotoMutation(
                accountId: session.accountId,
                clientMutationId: pending.clientMutationId
            )
            try ensureCurrent(generation: expectedGeneration, store: store, session: session)
            guard discarded else {
                // A newer local choice won while the cloud fetch was suspended. Keep that intent,
                // but retain the fetched profile as canonical base state for later reconciliation.
                try await store.saveProfile(profile)
                throw CancellationError()
            }
        }
        if let transfer { await mediaEngine.discardTransfer(transfer) }
        try ensureCurrent(generation: expectedGeneration, store: store, session: session)
        try await store.saveProfile(profile)
        try ensureCurrent(generation: expectedGeneration, store: store, session: session)
        return profile
    }

    func retryMine() async throws -> CloudProfile {
        guard let store, let session else { throw ProfilePhotoCoordinatorError.unavailable }
        let expectedGeneration = generation
        guard let pending = try await store.pendingProfilePhotoMutation(accountId: session.accountId) else {
            throw ProfilePhotoCoordinatorError.unavailable
        }
        try ensureCurrent(generation: expectedGeneration, store: store, session: session)
        let cloud = try await api.getProfile(token: session.token)
        try ensureCurrent(generation: expectedGeneration, store: store, session: session)
        try await store.saveProfile(cloud)
        try ensureCurrent(generation: expectedGeneration, store: store, session: session)
        let rebased = try await store.rebaseProfilePhotoMutation(
            accountId: session.accountId,
            clientMutationId: pending.clientMutationId,
            baseRevision: cloud.photoRevision
        )
        try ensureCurrent(generation: expectedGeneration, store: store, session: session)
        guard rebased else { throw CancellationError() }
        return cloud
    }

    func retryFailed() async throws {
        guard let store, let session else {
            throw ProfilePhotoCoordinatorError.unavailable
        }
        let expectedGeneration = generation
        guard let pending = try await store.pendingProfilePhotoMutation(accountId: session.accountId) else {
            throw ProfilePhotoCoordinatorError.unavailable
        }
        try ensureCurrent(generation: expectedGeneration, store: store, session: session)
        let retried = try await store.retryProfilePhotoMutation(
            accountId: session.accountId,
            clientMutationId: pending.clientMutationId
        )
        try ensureCurrent(generation: expectedGeneration, store: store, session: session)
        guard retried else { throw CancellationError() }
    }

    func discard() async {
        guard let store, let session else { return }
        let expectedGeneration = generation
        guard let pending = try? await store.pendingProfilePhotoMutation(accountId: session.accountId)
        else { return }
        guard isCurrent(generation: expectedGeneration, store: store, session: session) else { return }
        let transfer: MediaTransferRecord?
        if let transferId = pending.transferId {
            transfer = try? await store.mediaTransfer(id: transferId)
            guard isCurrent(generation: expectedGeneration, store: store, session: session) else { return }
        } else {
            transfer = nil
        }
        let discarded = try? await store.discardProfilePhotoMutation(
            accountId: session.accountId,
            clientMutationId: pending.clientMutationId
        )
        guard isCurrent(generation: expectedGeneration, store: store, session: session) else { return }
        guard discarded == true else { return }
        if let transfer { await mediaEngine.discardTransfer(transfer) }
    }

    private func isCurrent(
        generation expectedGeneration: UInt64,
        store expectedStore: CloudLocalStore,
        session expectedSession: CloudSession
    ) -> Bool {
        generation == expectedGeneration
            && store === expectedStore
            && session == expectedSession
    }

    private func ensureCurrent(
        generation expectedGeneration: UInt64,
        store expectedStore: CloudLocalStore,
        session expectedSession: CloudSession
    ) throws {
        guard isCurrent(
            generation: expectedGeneration,
            store: expectedStore,
            session: expectedSession
        ) else { throw CancellationError() }
    }
}

nonisolated enum ProfilePhotoCoordinatorError: Error, LocalizedError {
    case unavailable

    var errorDescription: String? {
        String(localized: "Profile photo sync is unavailable.")
    }
}
