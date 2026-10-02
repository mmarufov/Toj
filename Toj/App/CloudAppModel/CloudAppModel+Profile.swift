import Foundation
import Observation
import UIKit

extension CloudAppModel {
    func loadProfileDetails() async {
        guard let saved = storedSession else { return }
        let generation = accountSessionGeneration
        let expectedStore = localStore
        do {
            let loaded = try await tokenStore.loadProfile(accountId: saved.session.accountId)
                ?? Self.profileDetails(from: saved.displayName)
            guard profileOperationIsCurrent(
                saved: saved, generation: generation, store: expectedStore
            ) else { return }
            profileDetails = loaded
        } catch {
            guard profileOperationIsCurrent(
                saved: saved, generation: generation, store: expectedStore
            ) else { return }
            profileDetails = Self.profileDetails(from: saved.displayName)
            status = "Could not load profile details"
        }
    }

    @discardableResult
    func saveProfileDetails(_ candidate: StoredProfileDetails) async -> Bool {
        guard let saved = storedSession, !profileSaveInFlight else { return false }
        if let username = Self.cleanedUsername(candidate.username),
           username.range(of: "^[a-z][a-z0-9_]{4,31}$", options: .regularExpression) == nil {
            status = "Username must start with a letter and contain 5–32 letters, numbers, or underscores"
            return false
        }
        let cleaned = StoredProfileDetails(
            username: Self.cleanedUsername(candidate.username),
            firstName: Self.cleanedProfileText(candidate.firstName, limit: 48),
            lastName: Self.cleanedProfileText(candidate.lastName, limit: 48),
            bio: Self.cleanedProfileText(candidate.bio, limit: 120, preservesNewlines: true),
            birthday: candidate.birthday,
            colorIndex: max(0, min(candidate.colorIndex, 7)),
            serverUpdatedAt: candidate.serverUpdatedAt,
            pendingSync: true
        )
        guard !cleaned.firstName.isEmpty else {
            status = "First name is required"
            return false
        }

        profileSaveInFlight = true
        defer { profileSaveInFlight = false }
        let generation = accountSessionGeneration
        let expectedStore = localStore
        let operationId = UUID()
        let task = Task { [weak self] in
            guard let self else { return false }
            return await self.performProfileSave(
                cleaned,
                saved: saved,
                generation: generation,
                store: expectedStore
            )
        }
        profileSaveTasks[operationId] = task
        let result = await task.value
        profileSaveTasks.removeValue(forKey: operationId)
        return result
    }

    private func performProfileSave(
        _ cleaned: StoredProfileDetails,
        saved: StoredCloudSession,
        generation: UInt64,
        store expectedStore: CloudLocalStore?
    ) async -> Bool {
        let updatedSession = StoredCloudSession(
            session: saved.session,
            phone: saved.phone,
            displayName: cleaned.displayName
        )

        do {
            guard profileOperationIsCurrent(
                saved: saved, generation: generation, store: expectedStore
            ),
                  !Task.isCancelled else { return false }
            try await tokenStore.saveProfile(cleaned, accountId: saved.session.accountId)
            guard profileOperationIsCurrent(
                saved: saved, generation: generation, store: expectedStore
            ),
                  !Task.isCancelled else { return false }
            try await tokenStore.save(updatedSession)
        } catch {
            if profileOperationIsCurrent(
                saved: saved, generation: generation, store: expectedStore
            ) {
                status = "Could not save profile: \(error.localizedDescription)"
            }
            return false
        }

        guard profileOperationIsCurrent(
            saved: saved, generation: generation, store: expectedStore
        ),
              !Task.isCancelled else { return false }
        profileDetails = cleaned
        storedSession = updatedSession
        displayName = cleaned.displayName
        status = "Profile saved"

        #if DEBUG
        if isDemoMode { return true }
        #endif

        profileSyncTask?.cancel()
        let token = saved.session.token
        profileSyncTask = Task { [weak self] in
            await self?.uploadPendingProfile(
                cleaned,
                accountId: saved.session.accountId,
                deviceId: saved.session.deviceId,
                token: token,
                generation: generation,
                store: expectedStore
            )
        }
        return true
    }

    private func profileOperationIsCurrent(
        saved: StoredCloudSession,
        generation: UInt64,
        store expectedStore: CloudLocalStore?
    ) -> Bool {
        let storeMatches = switch (expectedStore, localStore) {
        case (nil, nil): true
        case let (expected?, current?): expected === current
        default: false
        }
        return !sessionTeardownActive
            && !isSessionTeardownInProgress
            && accountSessionGeneration == generation
            && storedSession?.session.accountId == saved.session.accountId
            && storedSession?.session.deviceId == saved.session.deviceId
            && storedSession?.session.token == saved.session.token
            && storeMatches
    }

    func reconcileProfileWithServer() {
        guard let saved = storedSession else { return }
        #if DEBUG
        if isDemoMode { return }
        #endif
        profileSyncTask?.cancel()
        let local = profileDetails
        let generation = accountSessionGeneration
        let expectedStore = localStore
        profileSyncTask = Task { [weak self] in
            guard let self else { return }
            if local.needsServerSync {
                await self.uploadPendingProfile(
                    local,
                    accountId: saved.session.accountId,
                    deviceId: saved.session.deviceId,
                    token: saved.session.token,
                    generation: generation,
                    store: expectedStore
                )
                return
            }
            do {
                let profile = try await self.api.getProfile(token: saved.session.token)
                guard !Task.isCancelled else { return }
                await self.acceptCanonicalProfile(
                    profile,
                    accountId: saved.session.accountId,
                    deviceId: saved.session.deviceId,
                    token: saved.session.token,
                    generation: generation,
                    store: expectedStore
                )
            } catch {
                // Keep the encrypted local snapshot. Reconciliation runs again on the next launch.
            }
        }
    }

    private func uploadPendingProfile(
        _ local: StoredProfileDetails,
        accountId: String,
        deviceId: String,
        token: String,
        generation: UInt64,
        store expectedStore: CloudLocalStore?
    ) async {
        do {
            let profile = try await api.updateProfile(local, token: token)
            guard !Task.isCancelled,
                  accountSessionGeneration == generation,
                  storedSession?.session.accountId == accountId,
                  storedSession?.session.deviceId == deviceId,
                  storedSession?.session.token == token,
                  Self.store(expectedStore, matches: localStore) else { return }
            await acceptCanonicalProfile(
                profile,
                accountId: accountId,
                deviceId: deviceId,
                token: token,
                generation: generation,
                store: expectedStore
            )
            if accountSessionGeneration == generation,
               storedSession?.session.accountId == accountId,
               storedSession?.session.deviceId == deviceId,
               storedSession?.session.token == token,
               Self.store(expectedStore, matches: localStore) {
                status = "Profile updated everywhere"
            }
        } catch {
            guard !Task.isCancelled,
                  accountSessionGeneration == generation,
                  storedSession?.session.accountId == accountId,
                  storedSession?.session.deviceId == deviceId,
                  storedSession?.session.token == token,
                  Self.store(expectedStore, matches: localStore) else { return }
            status = "Profile saved offline — will sync when reconnected"
        }
    }

    func acceptCanonicalProfile(
        _ profile: CloudProfile,
        accountId: String,
        deviceId: String,
        token: String,
        generation: UInt64,
        store expectedStore: CloudLocalStore?
    ) async {
        guard !sessionTeardownActive,
              let saved = storedSession,
              profile.accountId == accountId,
              saved.session.accountId == accountId,
              saved.session.deviceId == deviceId,
              saved.session.token == token,
              accountSessionGeneration == generation,
              Self.store(expectedStore, matches: localStore)
        else { return }
        let canonical: CloudProfile
        do {
            try await expectedStore?.saveProfile(profile)
            canonical = try await expectedStore?.profile(accountId: accountId) ?? profile
        } catch {
            status = "Profile updated, but local storage could not be refreshed"
            return
        }
        guard !sessionTeardownActive,
              accountSessionGeneration == generation,
              storedSession?.session.accountId == accountId,
              storedSession?.session.deviceId == deviceId,
              storedSession?.session.token == token,
              Self.store(expectedStore, matches: localStore),
              !Task.isCancelled
        else { return }
        let details = Self.profileDetails(from: canonical, pendingSync: false)
        let updatedSession = StoredCloudSession(
            session: saved.session,
            phone: saved.phone,
            displayName: details.displayName
        )
        do {
            try await tokenStore.saveProfile(details, accountId: saved.session.accountId)
        } catch {
            if accountSessionGeneration == generation,
               storedSession?.session.accountId == accountId,
               storedSession?.session.deviceId == deviceId,
               storedSession?.session.token == token,
               Self.store(expectedStore, matches: localStore) {
                status = "Profile updated, but local storage could not be refreshed"
            }
            return
        }
        guard !sessionTeardownActive,
              accountSessionGeneration == generation,
              storedSession?.session.accountId == saved.session.accountId,
              storedSession?.session.deviceId == deviceId,
              storedSession?.session.token == token,
              Self.store(expectedStore, matches: localStore),
              !Task.isCancelled
        else { return }
        profileDetails = details
        storedSession = updatedSession
        displayName = details.displayName
        let photoIdentityChanged = canonicalProfilePhoto?.id != canonical.photo?.id
        let replacedPhotoId = canonicalProfilePhoto?.id == canonical.photo?.id
            ? nil
            : canonicalProfilePhoto?.id
        canonicalProfilePhoto = canonical.photo
        profilePhotoRevision = canonical.photoRevision
        if let replacedPhotoId, let expectedStore {
            MediaPresentationCache.shared.revoke(mediaIds: [replacedPhotoId])
            await mediaEngine.clearMediaCache(mediaIds: [replacedPhotoId], localStore: expectedStore)
            guard !sessionTeardownActive,
                  accountSessionGeneration == generation,
                  storedSession?.session.accountId == accountId,
                  storedSession?.session.deviceId == deviceId,
                  storedSession?.session.token == token,
                  Self.store(expectedStore, matches: localStore)
            else { return }
        }

        let pending = try? await expectedStore?.pendingProfilePhotoMutation(accountId: accountId)
        guard !sessionTeardownActive,
              accountSessionGeneration == generation,
              storedSession?.session.accountId == accountId,
              storedSession?.session.deviceId == deviceId,
              storedSession?.session.token == token,
              Self.store(expectedStore, matches: localStore)
        else { return }
        guard pending == nil else {
            profilePhotoSyncState = pending?.state == "conflict" ? .conflict : .pending
            return
        }
        if let photo = canonical.photo {
            // Never present bytes for a different canonical media object if its replacement cannot
            // be fetched yet. A pending local mutation is handled above and deliberately keeps its
            // optimistic preview.
            if photoIdentityChanged { profilePhotoDisplayData = nil }
            if let bytes = try? await mediaEngine.thumbnail(
                media: photo,
                token: token,
                localStore: expectedStore
            ), accountSessionGeneration == generation,
               storedSession?.session.accountId == accountId,
               storedSession?.session.deviceId == deviceId,
               storedSession?.session.token == token,
               Self.store(expectedStore, matches: localStore) {
                profilePhotoDisplayData = bytes
                _ = await EncryptedProfilePhotoStore.persist(nil, accountId: accountId)
                guard !sessionTeardownActive,
                      accountSessionGeneration == generation,
                      storedSession?.session.accountId == accountId,
                      storedSession?.session.deviceId == deviceId,
                      storedSession?.session.token == token,
                      Self.store(expectedStore, matches: localStore)
                else { return }
            }
            guard !sessionTeardownActive,
                  accountSessionGeneration == generation,
                  storedSession?.session.accountId == accountId,
                  storedSession?.session.deviceId == deviceId,
                  storedSession?.session.token == token,
                  Self.store(expectedStore, matches: localStore)
            else { return }
            profilePhotoSyncState = .synced
        } else {
            let legacy = await EncryptedProfilePhotoStore.load(accountId: accountId)
            guard !sessionTeardownActive,
                  accountSessionGeneration == generation,
                  storedSession?.session.accountId == accountId,
                  storedSession?.session.deviceId == deviceId,
                  storedSession?.session.token == token,
                  Self.store(expectedStore, matches: localStore)
            else { return }
            profilePhotoDisplayData = legacy
            profilePhotoSyncState = capabilities.contains(.profilePhotos) && legacy != nil ? .pending : .localOnly
            if capabilities.contains(.profilePhotos), let legacy {
                await seedLegacyProfilePhotoIfNeeded(legacy, accountId: accountId)
            }
        }
    }

    @discardableResult
    func saveProfilePhoto(_ data: Data?, accountId: String) async -> Bool {
        guard let session = storedSession?.session, session.accountId == accountId else { return false }
        let generation = accountSessionGeneration
        if !capabilities.contains(.profilePhotos) {
            let stored = await EncryptedProfilePhotoStore.persist(data, accountId: accountId)
            let current = generation == accountSessionGeneration && storedSession?.session == session
            if stored, current {
                profilePhotoDisplayData = data
                profilePhotoSyncState = .localOnly
            }
            return stored && current
        }
        do {
            if let data {
                let photo = await Task.detached(priority: .userInitiated) {
                    SafeMediaImageDecoder.prepareProfilePhotoUpload(data)
                }.value
                guard generation == accountSessionGeneration,
                      storedSession?.session == session
                else { throw CancellationError() }
                guard let photo else {
                    throw CloudAppModelError.invalidMedia
                }
                let prepared = try await mediaEngine.prepare(
                    data: photo.data,
                    kind: "photo",
                    contentType: photo.contentType,
                    fileName: "profile-photo.\(photo.filenameExtension)",
                    width: photo.pixelWidth,
                    height: photo.pixelHeight,
                    thumbnail: photo.thumbnail
                )
                guard generation == accountSessionGeneration,
                      storedSession?.session == session
                else {
                    await mediaEngine.discardPrepared(prepared)
                    throw CancellationError()
                }
                _ = try await profilePhotoSyncCoordinator.stageSet(
                    prepared: prepared,
                    baseRevision: profilePhotoRevision
                )
            } else {
                _ = try await profilePhotoSyncCoordinator.stageRemoval(
                    baseRevision: profilePhotoRevision
                )
            }
            guard generation == accountSessionGeneration,
                  storedSession?.session == session
            else { throw CancellationError() }
            guard await EncryptedProfilePhotoStore.persist(data, accountId: accountId) else {
                guard generation == accountSessionGeneration,
                      storedSession?.session == session
                else { throw CancellationError() }
                await profilePhotoSyncCoordinator.discard()
                throw CloudAppModelError.localStoreUnavailable
            }
            guard generation == accountSessionGeneration,
                  storedSession?.session == session
            else { throw CancellationError() }
            profilePhotoDisplayData = data
            profilePhotoSyncState = .pending
            scheduleOutboxRetry()
            BackgroundRuntimeCoordinator.shared.scheduleProcessing()
            return true
        } catch is CancellationError {
            return false
        } catch {
            guard generation == accountSessionGeneration,
                  storedSession?.session == session else { return false }
            profilePhotoSyncState = .failed(error.localizedDescription)
            return false
        }
    }

    func retryProfilePhoto() async {
        guard let session = storedSession?.session else { return }
        let generation = accountSessionGeneration
        if case .conflict = profilePhotoSyncState {
            do {
                let cloud = try await profilePhotoSyncCoordinator.retryMine()
                guard generation == accountSessionGeneration,
                      storedSession?.session == session else { return }
                canonicalProfilePhoto = cloud.photo
                profilePhotoRevision = cloud.photoRevision
            } catch is CancellationError {
                return
            } catch {
                guard generation == accountSessionGeneration,
                      storedSession?.session == session else { return }
                profilePhotoSyncState = .failed(error.localizedDescription)
                return
            }
        } else {
            do {
                try await profilePhotoSyncCoordinator.retryFailed()
                guard generation == accountSessionGeneration,
                      storedSession?.session == session else { return }
            } catch is CancellationError {
                return
            } catch {
                guard generation == accountSessionGeneration,
                      storedSession?.session == session else { return }
                profilePhotoSyncState = .failed(error.localizedDescription)
                return
            }
        }
        profilePhotoSyncState = .pending
        scheduleOutboxRetry()
    }

    func useCloudProfilePhoto() async {
        guard let session = storedSession?.session else { return }
        let generation = accountSessionGeneration
        let expectedStore = localStore
        do {
            let profile = try await profilePhotoSyncCoordinator.useCloudPhoto()
            guard generation == accountSessionGeneration,
                  storedSession?.session == session else { return }
            _ = await EncryptedProfilePhotoStore.persist(nil, accountId: session.accountId)
            guard generation == accountSessionGeneration,
                  storedSession?.session == session else { return }
            await acceptCanonicalProfile(
                profile,
                accountId: session.accountId,
                deviceId: session.deviceId,
                token: session.token,
                generation: generation,
                store: expectedStore
            )
        } catch is CancellationError {
            return
        } catch {
            guard generation == accountSessionGeneration,
                  storedSession?.session == session else { return }
            profilePhotoSyncState = .failed(error.localizedDescription)
        }
    }

    func discardPendingProfilePhoto() async {
        guard let session = storedSession?.session else { return }
        let generation = accountSessionGeneration
        let expectedStore = localStore
        await profilePhotoSyncCoordinator.discard()
        guard generation == accountSessionGeneration,
              storedSession?.session == session else { return }
        _ = await EncryptedProfilePhotoStore.persist(nil, accountId: session.accountId)
        guard generation == accountSessionGeneration,
              storedSession?.session == session else { return }
        do {
            let profile = try await api.getProfile(token: session.token)
            guard generation == accountSessionGeneration,
                  storedSession?.session == session else { return }
            await acceptCanonicalProfile(
                profile,
                accountId: session.accountId,
                deviceId: session.deviceId,
                token: session.token,
                generation: generation,
                store: expectedStore
            )
        } catch {
            guard generation == accountSessionGeneration,
                  storedSession?.session == session else { return }
            profilePhotoDisplayData = nil
            profilePhotoSyncState = .localOnly
        }
    }

    private func seedLegacyProfilePhotoIfNeeded(_ data: Data, accountId: String) async {
        guard let session = storedSession?.session, session.accountId == accountId else { return }
        let generation = accountSessionGeneration
        guard (try? await localStore?.pendingProfilePhotoMutation(accountId: accountId)) == nil,
              generation == accountSessionGeneration,
              storedSession?.session == session
        else { return }
        let photo = await Task.detached(priority: .utility) {
            SafeMediaImageDecoder.prepareProfilePhotoUpload(data)
        }.value
        guard generation == accountSessionGeneration,
              storedSession?.session == session,
              let photo,
              let prepared = try? await mediaEngine.prepare(
                data: photo.data,
                kind: "photo",
                contentType: photo.contentType,
                fileName: "profile-photo.\(photo.filenameExtension)",
                width: photo.pixelWidth,
                height: photo.pixelHeight,
                thumbnail: photo.thumbnail
              )
        else { return }
        guard generation == accountSessionGeneration,
              storedSession?.session == session
        else {
            await mediaEngine.discardPrepared(prepared)
            return
        }
        do {
            _ = try await profilePhotoSyncCoordinator.stageSet(
                prepared: prepared,
                baseRevision: profilePhotoRevision,
                source: "legacy"
            )
            guard generation == accountSessionGeneration,
                  storedSession?.session == session
            else { return }
            profilePhotoSyncState = .pending
            scheduleOutboxRetry()
        } catch {
            await mediaEngine.discardPrepared(prepared)
        }
    }

    static func store(
        _ expected: CloudLocalStore?,
        matches current: CloudLocalStore?
    ) -> Bool {
        switch (expected, current) {
        case (nil, nil): true
        case let (expected?, current?): expected === current
        default: false
        }
    }
}
