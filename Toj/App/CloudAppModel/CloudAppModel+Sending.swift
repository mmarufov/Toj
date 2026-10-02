import Foundation
import Observation
import UIKit

extension CloudAppModel {
    func sendDraft(silent: Bool = false, deliverAfter: Date? = nil) async {
        if let activeDialogId {
            await presenceCoordinator.stopLocalTyping(dialogId: activeDialogId)
        }
        let rawText = draft
        let trimmedText = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        if case let .editing(messageId, _) = composerMode {
            guard !trimmedText.isEmpty else { return }
            #if DEBUG
            if isDemoMode {
                updateDemoMessage(messageId: messageId, text: trimmedText)
                restoreUnderlyingDraftComposer()
                return
            }
            #endif
            guard let line = lines.first(where: { $0.id == messageId }) else {
                status = "Message is no longer available"
                return
            }
            await edit(line, text: trimmedText)
            return
        }
        if currentDraft?.attachments.isEmpty == false {
            if let deliverAfter {
                await scheduleStagedDraft(deliverAt: deliverAfter, silent: silent)
                return
            }
            await sendStagedDraft(silent: silent)
            return
        }
        // A reply target can be saved before the user types, but it is not itself a message.
        // Keep that draft intact instead of enqueueing a request the server must reject.
        guard !trimmedText.isEmpty else { return }
        let replyPreview: String?
        let replyToMsgId: Int64?
        if case let .replying(messageId, preview) = composerMode {
            replyPreview = preview
            replyToMsgId = lines.first(where: { $0.id == messageId })?.msgId
                ?? currentDraft?.replyToMsgId
        } else {
            replyPreview = nil
            replyToMsgId = nil
        }
        let mentions = activeDialogId.map {
            resolvedMentions(in: rawText, dialogId: $0)
        } ?? []
        if let dialogId = activeDialogId {
            await draftPersistenceTasks[dialogId]?.value
        }
        if let activeDialogId {
            draftMentionsByDialog.removeValue(forKey: activeDialogId)
        }
        suppressDraftPersistence = true
        draft = ""
        suppressDraftPersistence = false
        composerMode = .text
        #if DEBUG
        if isDemoMode {
            sendDemo(rawText, replyPreview: replyPreview)
            return
        }
        #endif
        await send(
            rawText,
            replyToMsgId: replyToMsgId,
            mentions: mentions,
            silent: silent,
            deliverAfter: deliverAfter
        )
    }

    func currentAccountOperationContext() -> AccountOperationContext? {
        guard !sessionTeardownActive,
              !isSessionTeardownInProgress,
              let session = storedSession?.session,
              let localStore else { return nil }
        return AccountOperationContext(
            accountId: session.accountId,
            deviceId: session.deviceId,
            token: session.token,
            generation: accountSessionGeneration,
            store: localStore
        )
    }

    func isCurrentAccountOperation(_ context: AccountOperationContext) -> Bool {
        guard !sessionTeardownActive,
              !isSessionTeardownInProgress,
              accountSessionGeneration == context.generation,
              let session = storedSession?.session,
              let localStore else { return false }
        return session.accountId == context.accountId
            && session.deviceId == context.deviceId
            && session.token == context.token
            && localStore === context.store
    }

    private func send(
        _ text: String,
        replyToMsgId: Int64? = nil,
        mentions: [CloudMention] = [],
        silent: Bool = false,
        deliverAfter: Date? = nil
    ) async {
        guard let token = storedSession?.session.token, let dialogId = activeDialogId else { return }
        let accountOperationContext = currentAccountOperationContext()
        openingTimelineAnchor = .bottom
        timelineTopVisibleMsgId = nil
        timelineIsAtBottom = true
        let clientMsgId = UUID().uuidString.lowercased()
        let attemptedDraft = try? await draftSyncCoordinator.currentDraft(dialogId: dialogId)
        let consumesCloudDraft = capabilities.contains(.cloudDrafts)
        let draftConsumeOperationId = attemptedDraft?.state == "active"
            ? attemptedDraft?.operationId
            : nil
        if let deliverAfter, deliverAfter > Date() {
            guard let context = accountOperationContext,
                  context.token == token,
                  isCurrentAccountOperation(context),
                  activeDialogId == dialogId else { return }
            guard capabilities.contains(.scheduledDelivery) else {
                suppressDraftPersistence = true
                draft = text
                suppressDraftPersistence = false
                presentNotice(
                    "Scheduled sending is unavailable",
                    message: "Your message was restored to the composer and was not queued locally."
                )
                return
            }
            let request = CloudScheduledCreateRequest(
                scheduleId: UUID().uuidString.lowercased(),
                clientMutationId: UUID().uuidString.lowercased(),
                dialogId: dialogId,
                deliverAt: ISO8601DateFormatter().string(from: deliverAfter),
                silent: silent,
                reminder: dialogs.first(where: { $0.id == dialogId })?.type == "saved",
                items: [CloudScheduledItem(
                    clientMsgId: clientMsgId,
                    kind: "text",
                    body: text,
                    replyToMsgId: replyToMsgId,
                    mediaId: nil,
                    mentions: mentions,
                    linkPreviewCandidate: capabilities.contains(.linkPreviews)
                        ? CloudLinkPreviewCandidate.first(in: text)
                        : nil
                )]
            )
            do {
                await productivitySyncCoordinator.bind(context)
                guard isCurrentAccountOperation(context), activeDialogId == dialogId else { return }
                let local = try await productivitySyncCoordinator.stageScheduledCreate(
                    request,
                    draftOperationId: attemptedDraft?.operationId
                )
                guard isCurrentAccountOperation(context), activeDialogId == dialogId else { return }
                scheduledDeliveries.removeAll { $0.scheduleId == local.scheduleId }
                scheduledDeliveries.append(local)
                scheduledDeliveries.sort { $0.deliverAt < $1.deliverAt }
                status = String(localized: "Waiting for connection — not scheduled yet")
                scheduleOutboxRetry()
            } catch {
                guard isCurrentAccountOperation(context), activeDialogId == dialogId else { return }
                suppressDraftPersistence = true
                draft = text
                suppressDraftPersistence = false
                presentNotice("Message was not scheduled", message: error.localizedDescription)
            }
            return
        }
        do {
            if let localStore, let accountId = storedSession?.session.accountId {
                _ = try await localStore.insertSending(
                    dialogId: dialogId,
                    clientMsgId: clientMsgId,
                    text: text,
                    senderAccountId: accountId,
                    replyToMsgId: replyToMsgId,
                    mentions: mentions,
                    draftConsumeOperationId: draftConsumeOperationId,
                    requiresCloudDraftSync: consumesCloudDraft,
                    silent: silent,
                    deliverAfter: deliverAfter
                )
                await loadLocalLines(dialogId: dialogId)
                await refreshDialogs()
            } else {
                lines.append(Line(
                    id: clientMsgId,
                    dialogId: dialogId,
                    msgId: nil,
                    clientMsgId: clientMsgId,
                    text: text,
                    mine: true,
                    delivery: .sending,
                    timestamp: nil,
                    replyToMsgId: replyToMsgId
                ))
            }
        } catch {
            status = "Local send failed: \(error.localizedDescription)"
            return
        }

        if consumesCloudDraft {
            let flushResult = await draftSyncCoordinator.flush(dialogId: dialogId)
            guard await acceptDraftFlushResult(flushResult) else {
                status = "Queued — waiting to sync draft"
                scheduleOutboxRetry(after: 1)
                return
            }
        }

        do {
            try await sendOutboxItem(
                PendingOutboxItem(
                    clientMsgId: clientMsgId,
                    dialogId: dialogId,
                    body: text,
                    replyToMsgId: replyToMsgId,
                    forwardedFromDialogId: nil,
                    forwardedFromMsgId: nil,
                    draftConsumeOperationId: consumesCloudDraft ? draftConsumeOperationId : nil,
                    silent: silent,
                    retryCount: 0,
                    nextRetryAt: nil
                ),
                token: token
            )
        } catch {
            if let apiError = error as? CloudAPIError,
               apiError.code == "invalid_reply_target",
               await recoverTextSendAfterInvalidReply(clientMsgId: clientMsgId) {
                return
            }
            if let localStore {
                let disposition = cloudOperationFailureDisposition(
                    error, serverAdvertisesFeature: capabilities.contains(.replies)
                )
                if case let .transient(retryAfter) = disposition {
                    let delay = retryAfter ?? retryDelay(forRetryCount: 1)
                    try? await localStore.markFailed(clientMsgId: clientMsgId, retryAfter: delay)
                    scheduleOutboxRetry(after: delay)
                    publishTransportFailure(error)
                } else {
                    try? await localStore.markFailed(clientMsgId: clientMsgId, terminal: true)
                    presentNotice("Message was not sent", message: error.localizedDescription)
                }
                await loadLocalLines(dialogId: dialogId)
                await refreshDialogs()
            } else {
                if let index = lines.firstIndex(where: { $0.clientMsgId == clientMsgId }) {
                    lines[index].delivery = .failed(error.localizedDescription)
                }
            }
            status = "Send failed: \(error.localizedDescription)"
        }
    }
}
