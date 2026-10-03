import Foundation
import Observation
import UIKit

extension CloudAppModel {
    func deleteMessage(_ line: Line) async {
        #if DEBUG
        if isDemoMode {
            deleteDemoMessage(line.id)
            return
        }
        #endif
        guard
            let localStore,
            line.mine,
            !line.isDeleted,
            let dialogId = line.dialogId,
            let msgId = line.msgId
        else { return }
        let targetKey = "\(dialogId):\(msgId)"
        guard mutationTargetsBeingQueued.insert(targetKey).inserted else { return }
        defer { mutationTargetsBeingQueued.remove(targetKey) }
        do {
            let mutationId = UUID().uuidString.lowercased()
            try await localStore.enqueueMessageMutation(
                clientMutationId: mutationId, operation: "delete",
                dialogId: dialogId, msgId: msgId
            )
            await loadLocalLines(dialogId: dialogId)
            await processMessageMutation(PendingMessageMutation(
                clientMutationId: mutationId, operation: "delete", dialogId: dialogId,
                msgId: msgId, body: nil, expectedEditVersion: nil, emoji: nil,
                retryCount: 0, nextRetryAt: nil, lastError: nil
            ))
        } catch {
            status = "Delete failed: \(error.localizedDescription)"
            presentNotice("Could not delete message", message: error.localizedDescription)
        }
    }

    func reactToMessage(_ line: Line, reaction: String = "❤️") async {
        #if DEBUG
        if isDemoMode {
            reactToDemoMessage(line.id, reaction: reaction)
            return
        }
        #endif
        guard
            let localStore,
            !line.isDeleted,
            let dialogId = line.dialogId,
            let msgId = line.msgId
        else { return }
        let targetKey = "\(dialogId):\(msgId)"
        guard mutationTargetsBeingQueued.insert(targetKey).inserted else { return }
        defer { mutationTargetsBeingQueued.remove(targetKey) }
        let desiredReaction: String? = line.myReaction == reaction ? nil : reaction
        do {
            let mutationId = UUID().uuidString.lowercased()
            try await localStore.enqueueMessageMutation(
                clientMutationId: mutationId, operation: "reaction",
                dialogId: dialogId, msgId: msgId, emoji: desiredReaction
            )
            await loadLocalLines(dialogId: dialogId)
            await processMessageMutation(PendingMessageMutation(
                clientMutationId: mutationId, operation: "reaction", dialogId: dialogId,
                msgId: msgId, body: nil, expectedEditVersion: nil, emoji: desiredReaction,
                retryCount: 0, nextRetryAt: nil, lastError: nil
            ))
        } catch {
            status = "Reaction failed: \(error.localizedDescription)"
            presentNotice("Could not update reaction", message: error.localizedDescription)
        }
    }

    func forwardMessage(_ line: Line, to targetDialogId: String) async {
        guard !sessionTeardownActive else { return }
        _ = await runTrackedSavedOperation {
            await self.forwardMessageCore(line, to: targetDialogId)
        }
    }

    func forwardMessageCore(_ line: Line, to targetDialogId: String) async {
        #if DEBUG
        if isDemoMode {
            status = "Forwarded"
            return
        }
        #endif
        guard
            !sessionTeardownActive,
            !line.isDeleted,
            let token = storedSession?.session.token,
            let accountId = storedSession?.session.accountId,
            let localStore,
            let sourceDialogId = line.dialogId,
            let sourceMsgId = line.msgId
        else { return }
        let generation = savedMessagesSessionGeneration
        guard isCurrentSavedMessagesSession(
            accountId: accountId,
            token: token,
            store: localStore,
            generation: generation
        ) else { return }
        let clientMsgId = UUID().uuidString.lowercased()
        do {
            _ = try await localStore.insertSending(
                dialogId: targetDialogId,
                clientMsgId: clientMsgId,
                text: line.text,
                senderAccountId: accountId,
                forwardedFromAccountId: line.senderAccountId,
                forwardedFromDialogId: sourceDialogId,
                forwardedFromMsgId: sourceMsgId,
                kind: line.kind,
                media: line.media
            )
            try Task.checkCancellation()
            guard isCurrentSavedMessagesSession(
                accountId: accountId,
                token: token,
                store: localStore,
                generation: generation
            ) else { throw CancellationError() }
            await refreshDialogs()
            let response = try await api.forwardMessage(
                dialogId: targetDialogId,
                clientMsgId: clientMsgId,
                sourceDialogId: sourceDialogId,
                sourceMsgId: sourceMsgId,
                token: token
            )
            try Task.checkCancellation()
            guard isCurrentSavedMessagesSession(
                accountId: accountId,
                token: token,
                store: localStore,
                generation: generation
            ) else { throw CancellationError() }
            try await localStore.markSent(response, senderAccountId: accountId)
            if activeDialogId == response.dialogId {
                await loadLocalLines(dialogId: response.dialogId)
            }
            await refreshDialogs()
            scheduleSync()
            status = "Forwarded"
        } catch is CancellationError {
            return
        } catch {
            guard isCurrentSavedMessagesSession(
                accountId: accountId,
                token: token,
                store: localStore,
                generation: generation
            ) else { return }
            let disposition = cloudOperationFailureDisposition(
                error,
                serverAdvertisesFeature: capabilities.contains(.forwarding)
            )
            switch disposition {
            case let .transient(retryAfter):
                let delay = retryAfter ?? retryDelay(forRetryCount: 1)
                try? await localStore.markFailed(clientMsgId: clientMsgId, retryAfter: delay)
                await refreshDialogs()
                scheduleOutboxRetry(after: delay)
                publishTransportFailure(error)
            case .authenticationRequired, .unsupportedServer, .permanent:
                // Source deletion/inaccessibility is permanent. Keep one terminal bubble with an
                // explicit atomic Remove action instead of retrying forever.
                try? await localStore.markFailed(clientMsgId: clientMsgId, terminal: true)
                await refreshDialogs()
            }
            status = "Forward failed: \(error.localizedDescription)"
        }
    }

    static func reactionBadges(_ reactions: [CloudReaction]) -> [String] {
        let grouped = Dictionary(grouping: reactions, by: \.emoji)
        return grouped.keys.sorted().map { emoji in
            let count = grouped[emoji]?.count ?? 0
            return count > 1 ? "\(emoji) \(count)" : emoji
        }
    }

    func retryPendingMessageMutations() async {
        guard let localStore else { return }
        do {
            for mutation in try await localStore.pendingMessageMutationsReady() {
                try Task.checkCancellation()
                await processMessageMutation(mutation)
            }
        } catch is CancellationError {
            return
        } catch {
            presentNotice("Could not resume message changes", message: error.localizedDescription)
        }
    }

    func processMessageMutation(_ mutation: PendingMessageMutation) async {
        guard !messageMutationsInFlight.contains(mutation.clientMutationId) else { return }
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
        ), (try? await localStore.isDialogAccessRevoked(dialogId: mutation.dialogId)) == false
        else { return }
        messageMutationsInFlight.insert(mutation.clientMutationId)
        defer { messageMutationsInFlight.remove(mutation.clientMutationId) }

        do {
            let response: MessageMutationResponse
            switch mutation.operation {
            case "edit":
                guard let body = mutation.body, let expected = mutation.expectedEditVersion else {
                    throw CloudAppModelError.localStoreUnavailable
                }
                response = try await api.editMessage(
                    dialogId: mutation.dialogId,
                    msgId: mutation.msgId,
                    clientMutationId: mutation.clientMutationId,
                    expectedEditVersion: expected,
                    body: body,
                    token: token
                )
            case "delete":
                response = try await api.deleteMessage(
                    dialogId: mutation.dialogId,
                    msgId: mutation.msgId,
                    clientMutationId: mutation.clientMutationId,
                    token: token
                )
            case "reaction":
                response = try await api.setReaction(
                    dialogId: mutation.dialogId,
                    msgId: mutation.msgId,
                    clientMutationId: mutation.clientMutationId,
                    emoji: mutation.emoji,
                    token: token
                )
            default:
                throw CloudAppModelError.localStoreUnavailable
            }

            try Task.checkCancellation()
            guard isCurrentSavedMessagesSession(
                accountId: accountId,
                token: token,
                store: localStore,
                generation: generation
            ), (try? await localStore.isDialogAccessRevoked(dialogId: mutation.dialogId)) == false
            else { return }
            try await localStore.applyMessageMutation(response)
            try await localStore.completeMessageMutation(clientMutationId: mutation.clientMutationId)
            if activeDialogId == mutation.dialogId { await loadLocalLines(dialogId: mutation.dialogId) }
            await refreshDialogs()
            setReplicaSyncState(.ready)
            status = response.duplicate ? "Change confirmed" : "Updated"
            scheduleSync()
        } catch is CancellationError {
            return
        } catch {
            guard isCurrentSavedMessagesSession(
                accountId: accountId,
                token: token,
                store: localStore,
                generation: generation
            ), (try? await localStore.isDialogAccessRevoked(dialogId: mutation.dialogId)) == false
            else { return }
            if let apiError = error as? CloudAPIError,
               apiError.status == 409 || apiError.isMessageEditConflict {
                try? await localStore.completeMessageMutation(clientMutationId: mutation.clientMutationId)
                await runCoordinatedSync(trigger: .hint)
                // The banner must quote the message as the server now has it, not the pending edit.
                if activeDialogId == mutation.dialogId { await loadLocalLines(dialogId: mutation.dialogId) }
                if mutation.operation == "edit", let body = mutation.body {
                    draft = body
                    if let current = lines.first(where: { $0.msgId == mutation.msgId }) {
                        composerMode = .editing(messageId: current.id, original: current.text)
                    }
                }
                presentNotice(
                    "Message changed on another device",
                    message: mutation.operation == "edit"
                        ? "The latest message was loaded and your edit was restored. Review it and send again."
                        : "The latest message state has been loaded."
                )
                return
            }

            let featureIsAdvertised: Bool = switch mutation.operation {
            case "reaction": capabilities.contains(.reactions)
            default: capabilities.contains(.editing) || capabilities.contains(.deletion)
            }
            switch cloudOperationFailureDisposition(
                error, serverAdvertisesFeature: featureIsAdvertised
            ) {
            case let .transient(retryAfter):
                let delay = retryAfter ?? retryDelay(forRetryCount: mutation.retryCount + 1)
                try? await localStore.markMessageMutationFailed(
                    clientMutationId: mutation.clientMutationId,
                    error: error.localizedDescription,
                    retryAfter: delay,
                    terminal: false
                )
                publishTransportFailure(error)
                if activeDialogId == mutation.dialogId { await loadLocalLines(dialogId: mutation.dialogId) }
                scheduleOutboxRetry(after: delay)
            case .unsupportedServer:
                try? await localStore.completeMessageMutation(clientMutationId: mutation.clientMutationId)
                await refreshServerCapabilities()
                if activeDialogId == mutation.dialogId { await loadLocalLines(dialogId: mutation.dialogId) }
                presentNotice("Server upgrade required", message: "This server does not support that message action yet.")
            case .authenticationRequired:
                try? await localStore.completeMessageMutation(clientMutationId: mutation.clientMutationId)
                if activeDialogId == mutation.dialogId { await loadLocalLines(dialogId: mutation.dialogId) }
                presentNotice("Sign in again", message: "Your session ended before the message could be changed.")
            case .permanent:
                try? await localStore.completeMessageMutation(clientMutationId: mutation.clientMutationId)
                if activeDialogId == mutation.dialogId { await loadLocalLines(dialogId: mutation.dialogId) }
                presentNotice("Message was not changed", message: error.localizedDescription)
            }
        }
    }
}
