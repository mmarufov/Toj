import Foundation
import Observation
import UIKit

extension CloudAppModel {
    func actions(for line: Line) -> [MessageAction] {
        if line.isDeleted { return [.inspect] }
        if line.pendingMutation != nil { return [.inspect] }
        var actions: [MessageAction] = line.text.isEmpty ? [] : [.copy]
        if capabilities.contains(.replies) { actions.insert(.reply, at: 0) }
        if line.msgId != nil, capabilities.contains(.reactions) { actions.insert(.react, at: min(1, actions.count)) }
        if line.mine, line.media == nil, capabilities.contains(.editing) { actions.append(.edit) }
        let sourceType = line.dialogId.flatMap { sourceId in
            dialogs.first(where: { $0.id == sourceId })?.type
        }
        let sourceIsSaved = sourceType == "saved"
        if line.msgId != nil,
           !sourceIsSaved,
           savedMessagesDialogId != nil || capabilities.contains(.savedMessages) {
            actions.append(.save)
        }
        if line.msgId != nil, capabilities.contains(.forwarding) { actions.append(.forward) }
        if line.mine, capabilities.contains(.deletion) { actions.append(.delete) }
        if (sourceType == "direct" || sourceType == "group"),
           Self.isReportable(line, capabilities: capabilities) {
            actions.append(.report)
        }
        if case .failed = line.delivery {
            actions.append(.retry)
            actions.append(.remove)
        }
        actions.append(.inspect)
        return actions
    }

    func canShowAccountReport(dialogId: String) -> Bool {
        Self.canReportAccount(
            dialogType: dialogs.first(where: { $0.id == dialogId })?.type,
            capabilities: capabilities
        )
    }

    nonisolated static func canReportAccount(
        dialogType: String?,
        capabilities: MessagingCapabilities
    ) -> Bool {
        capabilities.contains(.abuseReports) && dialogType == "direct"
    }

    nonisolated static func isReportable(
        _ line: Line,
        capabilities: MessagingCapabilities
    ) -> Bool {
        let serverAcknowledged: Bool
        switch line.delivery {
        case .sent, .seen:
            serverAcknowledged = true
        case .sending, .failed:
            serverAcknowledged = false
        }
        return capabilities.contains(.abuseReports)
            && !line.mine
            && line.kind != "service"
            && line.msgId != nil
            && serverAcknowledged
            && !line.isDeleted
            && line.pendingMutation == nil
    }

    func retryFailedMessage(_ line: Line) {
        guard case .failed = line.delivery else { return }
        Task { [weak self] in
            guard let self else { return }
            if let localStore = self.localStore {
                if let groupId = line.mediaGroupId {
                    try? await localStore.retryMediaGroupSend(clientGroupId: groupId)
                    if let dialogId = line.dialogId, self.activeDialogId == dialogId {
                        await self.loadLocalLines(dialogId: dialogId)
                    }
                    self.scheduleOutboxRetry()
                    return
                }
                try? await localStore.markRetrying(clientMsgId: line.clientMsgId)
                try? await localStore.markMediaRetrying(clientMsgId: line.clientMsgId)
                if let dialogId = line.dialogId, self.activeDialogId == dialogId {
                    await self.loadLocalLines(dialogId: dialogId)
                }
            }
            self.scheduleOutboxRetry()
        }
    }

    func removeFailedMessage(_ line: Line) {
        guard case .failed = line.delivery, !sessionTeardownActive else { return }
        Task { [weak self] in
            guard let self, !self.sessionTeardownActive, let localStore = self.localStore else {
                return
            }
            try? await localStore.removePendingOutboxMessage(clientMsgId: line.clientMsgId)
            if let dialogId = line.dialogId, self.activeDialogId == dialogId {
                await self.loadLocalLines(dialogId: dialogId)
            }
            await self.refreshDialogs()
        }
    }

    func removeFailedMedia(_ line: Line) {
        guard line.media != nil else { return }
        Task { [weak self] in
            guard let self, !self.sessionTeardownActive, let localStore else { return }
            if let groupId = line.mediaGroupId {
                let transfers = (try? await localStore.removeMediaGroupSend(
                    clientGroupId: groupId
                )) ?? []
                for transfer in transfers {
                    await mediaEngine.discardTransfer(transfer)
                }
                if let dialogId = line.dialogId, activeDialogId == dialogId {
                    await loadLocalLines(dialogId: dialogId)
                }
                await refreshDialogs()
                return
            }
            guard
                  let transfer = try? await localStore.mediaTransfer(clientMsgId: line.clientMsgId)
            else {
                try? await localStore.removePendingOutboxMessage(clientMsgId: line.clientMsgId)
                if let dialogId = line.dialogId, self.activeDialogId == dialogId {
                    await self.loadLocalLines(dialogId: dialogId)
                }
                await self.refreshDialogs()
                return
            }
            if let activeTask = mediaTransferTasks[transfer.transferId] {
                activeTask.cancel()
                await activeTask.value
                return
            }
            if let token = storedSession?.session.token {
                await cancelMediaTransfer(transfer, token: token)
            } else {
                try? await localStore.cancelMediaTransfer(
                    transferId: transfer.transferId, clientMsgId: transfer.clientMsgId
                )
                await mediaEngine.discardTransfer(transfer)
                if activeDialogId == transfer.dialogId { await loadLocalLines(dialogId: transfer.dialogId) }
            }
        }
    }

    func togglePinned(_ dialogId: String) {
        guard !isSessionTeardownInProgress else { return }
        guard capabilities.contains(.chatOrganization) else { return }
        #if DEBUG
        if isDemoMode {
            updateDialog(dialogId) {
                $0.isPinned.toggle()
                $0.pinnedAt = $0.isPinned ? CloudLocalStore.sqliteTimestamp(Date()) : nil
            }
            sortDialogsForPresentation()
            return
        }
        #endif
        launchDialogPreferenceMutation(dialogId: dialogId, field: .pinned)
    }

    func toggleMuted(_ dialogId: String) {
        guard !isSessionTeardownInProgress else { return }
        guard let dialog = dialogs.first(where: { $0.id == dialogId }) else { return }
        guard dialog.type != "saved" else { return }
        let supportsLegacyGroupMute = dialog.type == "group" && capabilities.contains(.groups)
        guard capabilities.contains(.chatOrganization) || supportsLegacyGroupMute else { return }
        #if DEBUG
        if isDemoMode {
            updateDialog(dialogId) {
                $0.isMuted.toggle()
                $0.notificationMode = $0.isMuted ? "muted" : "all"
            }
            return
        }
        #endif
        if !capabilities.contains(.chatOrganization), supportsLegacyGroupMute {
            launchLegacyGroupMute(dialogId: dialogId, muted: !dialog.isMuted)
            return
        }
        launchDialogPreferenceMutation(dialogId: dialogId, field: .muted)
    }

    func archive(_ dialogId: String) {
        guard !isSessionTeardownInProgress else { return }
        guard capabilities.contains(.chatOrganization) else { return }
        // Saved Messages is the permanent self-dialog. It can be pinned but is neither muted nor
        // archived; legacy local archived state is ignored by the forwarding picker.
        guard dialogs.first(where: { $0.id == dialogId })?.type != "saved" else { return }
        #if DEBUG
        if isDemoMode {
            updateDialog(dialogId) { $0.isArchived = true }
            return
        }
        #endif
        launchDialogPreferenceMutation(
            dialogId: dialogId,
            field: .archived,
            desiredValue: true
        )
    }

    func unarchive(_ dialogId: String) {
        guard !isSessionTeardownInProgress else { return }
        guard capabilities.contains(.chatOrganization) else { return }
        guard dialogs.first(where: { $0.id == dialogId })?.type != "saved" else { return }
        #if DEBUG
        if isDemoMode {
            updateDialog(dialogId) { $0.isArchived = false }
            return
        }
        #endif
        launchDialogPreferenceMutation(
            dialogId: dialogId,
            field: .archived,
            desiredValue: false
        )
    }

    /// Applies a chat-list action through the same durable local-first queues as a single-row
    /// action. The loop is serialized to keep preference ordering deterministic and to bound
    /// SQLCipher/network pressure when a user selects many chats.
    func performBulkDialogAction(
        _ action: BulkDialogAction,
        dialogIds: Set<String>
    ) async -> BulkDialogActionResult {
        guard !dialogIds.isEmpty, !isSessionTeardownInProgress else {
            return BulkDialogActionResult(changed: 0, skipped: dialogIds.count)
        }
        let selected = dialogs.filter { dialogIds.contains($0.id) }
        let missingCount = max(0, dialogIds.count - selected.count)

        #if DEBUG
        if isDemoMode {
            var changed = 0
            var skipped = missingCount
            for dialog in selected {
                if applyDemoBulkAction(action, dialogId: dialog.id) { changed += 1 }
                else { skipped += 1 }
            }
            sortDialogsForPresentation()
            return BulkDialogActionResult(changed: changed, skipped: skipped)
        }
        #endif

        guard
            let localStore,
            let accountId = storedSession?.session.accountId
        else {
            return BulkDialogActionResult(changed: 0, skipped: dialogIds.count)
        }
        let generation = accountSessionGeneration
        var changed = 0
        var skipped = missingCount
        var processed = 0

        for dialog in selected {
            guard
                !Task.isCancelled,
                !isSessionTeardownInProgress,
                generation == accountSessionGeneration,
                storedSession?.session.accountId == accountId
            else {
                skipped += selected.count - processed
                break
            }
            processed += 1

            switch action {
            case .markRead:
                guard dialog.type != "saved", dialog.unreadCount > 0, dialog.lastMsgId > 0 else {
                    skipped += 1
                    continue
                }
                do {
                    try await localStore.queueReadReceipt(
                        dialogId: dialog.id,
                        accountId: accountId,
                        maxReadMsgId: dialog.lastMsgId
                    )
                    changed += 1
                } catch {
                    skipped += 1
                }
            case let .pin(value):
                guard dialog.isPinned != value else { skipped += 1; continue }
                if await setDialogPreference(
                    dialogId: dialog.id,
                    field: .pinned,
                    desiredValue: value,
                    expectedAccountId: accountId,
                    sessionGeneration: generation
                ) { changed += 1 } else { skipped += 1 }
            case let .mute(value):
                guard dialog.type != "saved", dialog.isMuted != value else {
                    skipped += 1
                    continue
                }
                if await setDialogPreference(
                    dialogId: dialog.id,
                    field: .muted,
                    desiredValue: value,
                    expectedAccountId: accountId,
                    sessionGeneration: generation
                ) { changed += 1 } else { skipped += 1 }
            case let .archive(value):
                guard dialog.type != "saved", dialog.isArchived != value else {
                    skipped += 1
                    continue
                }
                if await setDialogPreference(
                    dialogId: dialog.id,
                    field: .archived,
                    desiredValue: value,
                    expectedAccountId: accountId,
                    sessionGeneration: generation
                ) { changed += 1 } else { skipped += 1 }
            }
        }

        if case .markRead = action, changed > 0 {
            await refreshDialogs()
            scheduleReadReceiptRetry()
        }
        return BulkDialogActionResult(changed: changed, skipped: skipped)
    }

    #if DEBUG
    private func applyDemoBulkAction(_ action: BulkDialogAction, dialogId: String) -> Bool {
        guard let index = dialogs.firstIndex(where: { $0.id == dialogId }) else { return false }
        switch action {
        case .markRead:
            guard dialogs[index].type != "saved", dialogs[index].unreadCount > 0 else { return false }
            dialogs[index].unreadCount = 0
        case let .pin(value):
            guard dialogs[index].isPinned != value else { return false }
            dialogs[index].isPinned = value
            dialogs[index].pinnedAt = value ? CloudLocalStore.sqliteTimestamp(Date()) : nil
        case let .mute(value):
            guard dialogs[index].type != "saved", dialogs[index].isMuted != value else { return false }
            dialogs[index].isMuted = value
            dialogs[index].notificationMode = value ? "muted" : "all"
        case let .archive(value):
            guard dialogs[index].type != "saved", dialogs[index].isArchived != value else { return false }
            dialogs[index].isArchived = value
        }
        return true
    }
    #endif

    func launchDialogPreferenceMutation(
        dialogId: String,
        field: DialogPreferenceField,
        desiredValue: Bool? = nil
    ) {
        guard
            !isSessionTeardownInProgress,
            let accountId = storedSession?.session.accountId
        else { return }
        let generation = accountSessionGeneration
        let taskId = UUID()
        let task = Task { [weak self] in
            guard let self else { return }
            defer { self.preferenceMutationTasks.removeValue(forKey: taskId) }
            _ = await self.setDialogPreference(
                dialogId: dialogId,
                field: field,
                desiredValue: desiredValue,
                expectedAccountId: accountId,
                sessionGeneration: generation
            )
        }
        preferenceMutationTasks[taskId] = task
    }

    func launchLegacyGroupMute(dialogId: String, muted: Bool) {
        guard
            !isSessionTeardownInProgress,
            let accountId = storedSession?.session.accountId
        else { return }
        let generation = accountSessionGeneration
        let taskId = UUID()
        let task = Task { [weak self] in
            guard let self else { return }
            defer { self.preferenceMutationTasks.removeValue(forKey: taskId) }
            guard
                !Task.isCancelled,
                self.accountSessionGeneration == generation,
                self.storedSession?.session.accountId == accountId
            else { return }
            _ = await self.submitGroupMutation(
                dialogId: dialogId,
                operation: "notifications",
                payload: GroupMutationPayload(mode: muted ? "muted" : "all")
            )
            guard
                !Task.isCancelled,
                self.accountSessionGeneration == generation,
                self.storedSession?.session.accountId == accountId
            else { return }
            await self.refreshDialogs()
        }
        preferenceMutationTasks[taskId] = task
    }

    nonisolated static func forwardingPickerDialogs(_ dialogs: [Dialog]) -> [Dialog] {
        dialogs
            .filter { $0.type == "saved" || !$0.isArchived }
            .sorted {
                if ($0.type == "saved") != ($1.type == "saved") {
                    return $0.type == "saved"
                }
                return $0.updatedAt > $1.updatedAt
            }
    }

    private func updateDialog(_ dialogId: String, mutation: (inout Dialog) -> Void) {
        guard let index = dialogs.firstIndex(where: { $0.id == dialogId }) else { return }
        mutation(&dialogs[index])
    }

    func sortDialogsForPresentation() {
        dialogs.sort {
            if $0.isPinned != $1.isPinned { return $0.isPinned }
            if $0.isPinned, $0.pinnedAt != $1.pinnedAt {
                return ($0.pinnedAt ?? "") > ($1.pinnedAt ?? "")
            }
            if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
            return $0.id > $1.id
        }
    }

    @discardableResult
    private func setDialogPreference(
        dialogId: String,
        field: DialogPreferenceField,
        desiredValue: Bool? = nil,
        expectedAccountId: String? = nil,
        sessionGeneration: UInt64? = nil
    ) async -> Bool {
        guard !isSessionTeardownInProgress else { return false }
        guard capabilities.contains(.chatOrganization) else { return false }
        #if DEBUG
        if isDemoMode {
            updateDialog(dialogId) { dialog in
                let current: Bool
                switch field {
                case .pinned: current = dialog.isPinned
                case .muted: current = dialog.isMuted
                case .archived: current = dialog.isArchived
                }
                let value = desiredValue ?? !current
                switch field {
                case .pinned:
                    dialog.isPinned = value
                    dialog.pinnedAt = value ? CloudLocalStore.sqliteTimestamp(Date()) : nil
                case .muted:
                    dialog.isMuted = value
                    dialog.notificationMode = value ? "muted" : "all"
                case .archived:
                    dialog.isArchived = value
                }
            }
            sortDialogsForPresentation()
            return true
        }
        #endif
        guard
            let localStore,
            let accountId = storedSession?.session.accountId
        else { return false }
        let generation = sessionGeneration ?? accountSessionGeneration
        guard
            expectedAccountId == nil || expectedAccountId == accountId,
            generation == accountSessionGeneration
        else { return false }
        do {
            _ = try await dialogPreferencesCoordinator.queue(
                store: localStore,
                accountId: accountId,
                dialogId: dialogId,
                field: field,
                desiredValue: desiredValue
            )
            guard
                !Task.isCancelled,
                generation == accountSessionGeneration,
                storedSession?.session.accountId == accountId
            else { return false }
            // Observation publishes the SQLCipher overlay immediately; networking happens only
            // after the optimistic write has committed.
            await retryPendingDialogPreferences()
            scheduleOutboxRetry()
            return true
        } catch {
            presentNotice(
                String(localized: "Chat preference could not be saved"),
                message: error.localizedDescription
            )
            return false
        }
    }

    func retryPendingDialogPreferences() async {
        guard !isSessionTeardownInProgress else { return }
        guard
            capabilities.contains(.chatOrganization),
            let localStore,
            let accountId = storedSession?.session.accountId,
            let token = storedSession?.session.token
        else { return }
        let generation = accountSessionGeneration
        do {
            let result = try await dialogPreferencesCoordinator.drain(
                store: localStore,
                accountId: accountId,
                token: token,
                serverAdvertisesFeature: true,
                sessionGeneration: generation
            )
            guard
                !Task.isCancelled,
                generation == accountSessionGeneration,
                storedSession?.session.accountId == accountId,
                storedSession?.session.token == token
            else { return }
            if result.acceptedCount > 0 {
                scheduleSync()
            }
            if let retryAfter = result.retryAfter {
                scheduleOutboxRetry(after: retryAfter)
                BackgroundRuntimeCoordinator.shared.scheduleAppRefresh(
                    earliestBeginDate: Date(timeIntervalSinceNow: retryAfter)
                )
            }
            if result.authenticationRequired {
                status = String(localized: "Chat preferences are saved and will sync after sign-in")
            }
            if result.capabilityRefreshRequired {
                await refreshServerCapabilities()
                guard
                    generation == accountSessionGeneration,
                    storedSession?.session.accountId == accountId
                else { return }
            }
            if let error = result.permanentErrors.first {
                await refreshDialogs()
                presentNotice(
                    String(localized: "Chat preference was not changed"),
                    message: error
                )
            }
        } catch is CancellationError {
            return
        } catch {
            status = String(
                format: String(localized: "Chat preference sync paused: %@"),
                error.localizedDescription
            )
        }
    }
}
