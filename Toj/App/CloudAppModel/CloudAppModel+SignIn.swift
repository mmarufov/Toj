import Foundation
import Observation
import UIKit

extension CloudAppModel {
    func requestCode() async {
        guard canRequestCode else { return }
        let trimmed = phone.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        authRequestInFlight = true
        defer { authRequestInFlight = false }
        do {
            // Refresh first: the picker must never offer a channel the server cannot send on, and
            // this is the one place the answer is cheap to get and always needed.
            if let capabilities = try? await api.capabilities() {
                applyOTPChannels(capabilities.capabilities)
            }
            let deliveryChannel = availableOTPChannels.isEmpty ? nil : selectedOTPChannel?.rawValue
            let response = try await api.startAuth(phone: trimmed, deliveryChannel: deliveryChannel)
            requestedCode = true
            if deliveryChannel != nil {
                // A real channel was used, so any code in the response is a development artefact
                // and must not be pre-filled as though the user had received it.
                code = ""
            } else if let devCode = response.code {
                code = devCode
            }
            startResendCountdown(response.retryAfter ?? 30)
            status = "Code requested"
        } catch {
            if let retryAfter = (error as? CloudAPIError)?.retryAfter {
                startResendCountdown(retryAfter)
            }
            status = "Code request failed: \(error.localizedDescription)"
        }
    }

    func verifyCode() async {
        guard canVerifyCode else { return }
        let trimmedPhone = phone.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedCode = code.filter(\.isNumber)
        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPhone.isEmpty, !trimmedCode.isEmpty else { return }

        authVerifyInFlight = true
        defer { authVerifyInFlight = false }
        do {
            let publicCapabilities = try await api.capabilities()
            let supportsV2 = publicCapabilities.capabilities.contains("auth_sessions_v2")
            if supportsV2 {
                let response = try await api.checkAuthV2(
                    phone: trimmedPhone,
                    code: trimmedCode,
                    displayName: name,
                    deviceName: UIDevice.current.name
                )
                if response.state == "two_factor_required", let challengeId = response.challengeId {
                    twoFactorChallengeId = challengeId
                    status = "Enter your two-step verification password"
                    return
                }
                guard let session = response.session else {
                    throw CloudAPIError(
                        status: -1,
                        message: "Invalid authentication response",
                        retryAfter: nil
                    )
                }
                await finishAuthentication(
                    session: session,
                    phone: trimmedPhone,
                    displayName: name
                )
            } else {
                let session = try await api.checkAuth(
                    phone: trimmedPhone,
                    code: trimmedCode,
                    displayName: name,
                    deviceName: UIDevice.current.name
                )
                await finishAuthentication(
                    session: session,
                    phone: trimmedPhone,
                    displayName: name
                )
            }
        } catch {
            status = "Sign in failed: \(error.localizedDescription)"
        }
    }

    func verifySecondFactor() async {
        guard canVerifySecondFactor, let challengeId = twoFactorChallengeId else { return }
        authVerifyInFlight = true
        defer { authVerifyInFlight = false }
        do {
            let response = try await api.completeTwoFactorLogin(
                challengeId: challengeId,
                password: usesTwoFactorRecovery ? nil : twoFactorPassword,
                recoveryCode: usesTwoFactorRecovery ? twoFactorRecoveryCode : nil,
                newPassword: usesTwoFactorRecovery ? twoFactorReplacementPassword : nil
            )
            recoveredTwoFactorCodes = response.recoveryCodes ?? []
            await finishAuthentication(
                session: response.session,
                phone: phone.trimmingCharacters(in: .whitespacesAndNewlines),
                displayName: displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        } catch {
            status = "Two-step verification failed: \(error.localizedDescription)"
        }
    }

    private func finishAuthentication(
        session: CloudSession,
        phone: String,
        displayName: String
    ) async {
        if let expiredSessionAccountId, expiredSessionAccountId != session.accountId {
            do {
                // The successful login already created a server device. Persist its revocation
                // token before showing a destructive local-replica choice so cancellation, loss
                // of network, or process death cannot strand an unreachable live session.
                try await tokenStore.savePendingRevocationToken(
                    session.token,
                    eraseLocalReplicaOnLaunch: false,
                    localReplicaAccountId: expiredSessionAccountId
                )
            } catch {
                _ = try? await api.revokeSession(token: session.token)
                status = "Sign in could not be staged safely: \(error.localizedDescription)"
                return
            }
            pendingDifferentAccountAuthentication = (session, phone, displayName)
            requiresDifferentAccountCleanupConfirmation = true
            status = "Confirm before replacing the saved chats from another account."
            return
        }
        let stored = StoredCloudSession(session: session, phone: phone, displayName: displayName)
        do {
            try await tokenStore.save(stored)
            do {
                try await tokenStore.clearPendingRevocationToken(ifMatches: session.token)
                try await tokenStore.markPendingRevocationsRemoteOnly(
                    localReplicaAccountId: session.accountId
                )
                try await tokenStore.clearPendingReauthentication()
            } catch {
                // Leave the durable revocation marker intact and remove the newly saved session.
                // On relaunch Toj will retry revocation instead of restoring ambiguous identity.
                try? await tokenStore.clearSession(ifTokenMatches: session.token)
                throw error
            }
            // Clear the in-memory replacement fence only after both the new credential and the
            // removal of its durable reauthentication marker have committed successfully.
            expiredSessionAccountId = nil
            sessionEpoch &+= 1
            sessionTearingDown = false
            isSessionTeardownInProgress = false
            accountSessionGeneration &+= 1
            installAuthenticatedSession(stored)
            profileDetails = Self.profileDetails(from: displayName)
            try? await tokenStore.saveProfile(profileDetails, accountId: session.accountId)
            resendTask?.cancel()
            resendTask = nil
            resendSeconds = 0
            twoFactorChallengeId = nil
            twoFactorPassword = ""
            twoFactorRecoveryCode = ""
            twoFactorReplacementPassword = ""
            usesTwoFactorRecovery = false
            status = "Signed in"
            setReplicaSyncState(.checking)
            await afterSignIn()
            await prepareBackgroundMediaRuntime()
            await activateForegroundServices()
        } catch {
            // Authentication already created a server-side device. If its durable local commit
            // fails, revoke that otherwise unreachable credential before allowing another retry.
            _ = try? await api.revokeSession(token: session.token)
            status = "Sign in failed: \(error.localizedDescription)"
        }
    }

    func cancelDifferentAccountSignIn() async {
        guard let pending = pendingDifferentAccountAuthentication else { return }
        pendingDifferentAccountAuthentication = nil
        requiresDifferentAccountCleanupConfirmation = false
        // Cancellation resolves only this staged token's relationship to the preserved replica.
        // Keep retrying its remote revoke without turning that cleanup into a second auth fence;
        // the independent reauthentication marker for the original account remains authoritative.
        try? await tokenStore.markPendingRevocationRemoteOnly(ifMatches: pending.session.token)
        await revokeSignedOutToken(pending.session.token)
        status = "Saved chats were kept. Sign in with the original account to resume."
    }

    func confirmDifferentAccountSignIn() async {
        guard let pending = pendingDifferentAccountAuthentication else { return }
        pendingDifferentAccountAuthentication = nil
        requiresDifferentAccountCleanupConfirmation = false
        let cleanupSucceeded = await clearLocalSession(
            finalStatus: "Previous account removed from this device"
        )
        guard cleanupSucceeded else {
            // Never install another account over a replica whose destructive cleanup was partial.
            // The revocation marker survives a transient network failure and is retried at launch.
            await revokeSignedOutToken(pending.session.token)
            status = "Could not safely replace the previous account. Restart Toj to finish cleanup."
            return
        }
        expiredSessionAccountId = nil
        await finishAuthentication(
            session: pending.session,
            phone: pending.phone,
            displayName: pending.displayName
        )
    }

    func dismissOperationNotice() {
        let terminal = pendingProductivityTerminalNotice.flatMap { pending in
            operationNotice?.id == pending.noticeId ? pending.failure : nil
        }
        operationNotice = nil
        if terminal != nil { pendingProductivityTerminalNotice = nil }
        guard let terminal, let context = currentAccountOperationContext() else { return }
        productivityTerminalAcknowledgementTask?.task.cancel()
        let id = UUID()
        let task = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.productivityTerminalAcknowledgementTask?.id == id {
                    self.productivityTerminalAcknowledgementTask = nil
                }
            }
            await self.productivitySyncCoordinator.bind(context)
            guard self.isCurrentAccountOperation(context) else { return }
            try? await self.productivitySyncCoordinator.acknowledgeTerminalError(terminal)
            guard self.isCurrentAccountOperation(context) else { return }
            let report = await self.productivitySyncCoordinator.drain(api: self.api)
            await self.publishProductivityDrainReport(report, context: context)
        }
        productivityTerminalAcknowledgementTask = (id, task)
    }

    func resetAuthCode() {
        guard !authRequestInFlight, !authVerifyInFlight else { return }
        requestedCode = false
        code = ""
        twoFactorChallengeId = nil
        twoFactorPassword = ""
        twoFactorRecoveryCode = ""
        twoFactorReplacementPassword = ""
        usesTwoFactorRecovery = false
        status = "Signed out"
    }

    private func startResendCountdown(_ seconds: Int) {
        resendTask?.cancel()
        resendSeconds = min(max(0, seconds), Self.maxResendCountdownSeconds)
        guard resendSeconds > 0 else {
            resendTask = nil
            return
        }
        resendTask = Task { [weak self] in
            while let self, self.resendSeconds > 0, !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                self.resendSeconds -= 1
            }
            self?.resendTask = nil
        }
    }
}
