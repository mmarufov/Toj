import Foundation
import Observation
import UIKit

extension CloudAppModel {
    @discardableResult
    func ensureSavedMessages(presentsFailure: Bool = true) async -> String? {
        guard !sessionTeardownActive else { return nil }
        return await runTrackedSavedOperation {
            await self.ensureSavedMessagesCore(presentsFailure: presentsFailure)
        } ?? nil
    }

    private func ensureSavedMessagesCore(presentsFailure: Bool) async -> String? {
        guard
            !sessionTeardownActive,
            let accountId = storedSession?.session.accountId,
            let token = storedSession?.session.token,
            let localStore
        else { return nil }
        let generation = savedMessagesSessionGeneration
        guard isCurrentSavedMessagesSession(
            accountId: accountId,
            token: token,
            store: localStore,
            generation: generation
        ) else { return nil }
        if let savedMessagesDialogId {
            guard isCurrentSavedMessagesSession(
                accountId: accountId,
                token: token,
                store: localStore,
                generation: generation
            ) else { return nil }
            return savedMessagesDialogId
        }
        if let local = try? await savedMessagesService.localDialogId(
            store: localStore,
            accountId: accountId
        ) {
            guard isCurrentSavedMessagesSession(
                accountId: accountId,
                token: token,
                store: localStore,
                generation: generation
            ) else { return nil }
            savedMessagesDialogId = local
            savedMessagesSetupFailure = nil
            return local
        }
        guard savedMessagesCapabilityState != .unsupported else {
            savedMessagesSetupFailure = String(localized: "Unavailable on this server")
            return nil
        }

        savedMessagesSetupInFlight = true
        savedMessagesSetupFailure = nil
        defer {
            if savedMessagesSessionGeneration == generation {
                savedMessagesSetupInFlight = false
            }
        }
        do {
            let dialogId = try await savedMessagesService.ensure(
                api: api,
                store: localStore,
                accountId: accountId,
                token: token,
                generation: generation
            )
            guard isCurrentSavedMessagesSession(
                accountId: accountId,
                token: token,
                store: localStore,
                generation: generation
            ) else { return nil }
            savedMessagesDialogId = dialogId
            savedMessagesSetupFailure = nil
            await refreshDialogs()
            return dialogId
        } catch is CancellationError {
            return nil
        } catch {
            guard isCurrentSavedMessagesSession(
                accountId: accountId,
                token: token,
                store: localStore,
                generation: generation
            ) else { return nil }
            let message: String
            let apiStatus = (error as? CloudAPIError)?.status
            savedMessagesCapabilityState = savedMessagesCapabilityState.resolvingEnsureFailure(
                statusCode: apiStatus
            )
            if apiStatus == 404 {
                negotiatedCapabilities.remove(.savedMessages)
                message = String(localized: "Unavailable on this server")
            } else {
                switch cloudFailureDisposition(error) {
                case .transient:
                    message = String(localized: "Connect once to set up Saved Messages")
                case .authenticationRequired:
                    message = String(localized: "Sign in again to set up Saved Messages")
                case .unsupportedServer:
                    message = String(localized: "Unavailable on this server")
                case .permanent:
                    message = String(localized: "Saved Messages could not be set up")
                }
            }
            savedMessagesSetupFailure = message
            if presentsFailure {
                presentNotice(String(localized: "Saved Messages"), message: message)
            }
            return nil
        }
    }

    func isCurrentSavedMessagesSession(
        accountId: String,
        token: String,
        store: CloudLocalStore,
        generation: UInt64
    ) -> Bool {
        !sessionTeardownActive
            && savedMessagesSessionGeneration == generation
            && storedSession?.session.accountId == accountId
            && storedSession?.session.token == token
            && localStore === store
    }

    func saveMessage(_ line: Line) async {
        guard !sessionTeardownActive else { return }
        _ = await runTrackedSavedOperation {
            await self.saveMessageCore(line)
        }
    }

    private func saveMessageCore(_ line: Line) async {
        guard
            !sessionTeardownActive,
            !line.isDeleted,
            line.msgId != nil,
            line.dialogId != savedMessagesDialogId,
            let targetDialogId = await ensureSavedMessagesCore(presentsFailure: true)
        else { return }
        await forwardMessageCore(line, to: targetDialogId)
        if status == "Forwarded" {
            status = String(localized: "Saved to Saved Messages")
        }
    }

    func runTrackedSavedOperation<T: Sendable>(
        _ operation: @escaping @MainActor () async -> T
    ) async -> T? {
        guard !sessionTeardownActive else { return nil }
        let id = UUID()
        let task = Task { await operation() }
        trackedSavedOperations[id] = TrackedSavedOperation(
            cancel: { task.cancel() },
            wait: { _ = await task.result }
        )
        let result = await task.value
        trackedSavedOperations.removeValue(forKey: id)
        guard !sessionTeardownActive, !Task.isCancelled else { return nil }
        return result
    }
}
