import Foundation
import Observation
import UIKit

extension CloudAppModel {
    func selectDialog(_ dialogId: String) async {
        if activeDialogId != dialogId || timelineObservationTask == nil {
            beginConversationSelection(dialogId)
        }
        guard activeDialogId == dialogId, conversationOpenState == .loadingLocal else { return }
        await withCheckedContinuation { continuation in
            guard activeDialogId == dialogId, conversationOpenState == .loadingLocal else {
                continuation.resume()
                return
            }
            conversationOpenWaiters[dialogId, default: []].append(continuation)
        }
    }

    /// Starts the encrypted local observation before the navigation animation begins. This method
    /// performs no network work and publishes an LRU hit in the same main-actor turn as the tap.
    func prepareConversationOpen(dialogId: String, focusMsgId: Int64? = nil) {
        if let focusMsgId {
            // Set before selection so `beginConversationSelection` can anchor on it instead of
            // resetting to the bottom.
            pendingFocusMsgId = focusMsgId
        }
        guard activeDialogId != dialogId || timelineObservationTask == nil else { return }
        beginConversationSelection(dialogId)
    }

    func scheduleActiveDraftPersistence(
        reason: DraftSyncCoordinator.FlushReason = .idle
    ) {
        #if DEBUG
        if isDemoMode {
            guard
                !suppressDraftPersistence,
                let dialogId = activeDialogId,
                let index = dialogs.firstIndex(where: { $0.id == dialogId })
            else { return }
            let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
            dialogs[index].draftPreview = trimmed.isEmpty ? nil : trimmed
            return
        }
        #endif
        guard
            !sessionTearingDown,
            !suppressDraftPersistence,
            let dialogId = activeDialogId,
            storedSession != nil
        else { return }
        if case .editing = composerMode { return }
        let generation = (draftPersistenceGenerations[dialogId] ?? 0) &+ 1
        draftPersistenceGenerations[dialogId] = generation
        let text = draft
        let reply = activeReplyDraftContext()
        let mentions = resolvedMentions(in: text, dialogId: dialogId)
        let previous = draftPersistenceTasks[dialogId]
        draftPersistenceTasks[dialogId] = Task { [weak self] in
            // Preserve every local generation in order. The SQL row/outbox entry is still
            // coalesced by dialog, so this durability guarantee never creates a network backlog.
            await previous?.value
            guard let self else { return }
            do {
                let saved = try await self.draftSyncCoordinator.mutate(
                    dialogId: dialogId,
                    text: text,
                    replyToMsgId: reply.0,
                    replyPreview: reply.1,
                    mentions: mentions,
                    reason: reason
                )
                guard !self.sessionTearingDown else { return }
                self.minimumObservedDraftGenerations[dialogId] = max(
                    self.minimumObservedDraftGenerations[dialogId] ?? 0,
                    saved.localGeneration
                )
            } catch is CancellationError {
                return
            } catch {
                self.status = "Draft could not be saved locally: \(error.localizedDescription)"
            }
            if self.draftPersistenceGenerations[dialogId] == generation {
                self.draftPersistenceTasks[dialogId] = nil
            }
        }
    }

    private func activeReplyDraftContext() -> (Int64?, CloudDraftReplyPreview?) {
        guard case let .replying(messageId, preview) = composerMode,
              let line = lines.first(where: { $0.id == messageId }),
              let msgId = line.msgId
        else { return (nil, nil) }
        let sender = loadedLocalMessages.first(where: { $0.localId == messageId })?.senderAccountId ?? ""
        return (
            msgId,
            CloudDraftReplyPreview(
                msgId: msgId,
                senderAccountId: sender,
                text: preview,
                unavailable: false
            )
        )
    }

    private func startDraftObservation(dialogId: String) {
        draftObservationTask?.cancel()
        guard let localStore, let accountId = storedSession?.session.accountId else { return }
        draftObservationTask = Task { [weak self, localStore] in
            do {
                let values = await localStore.observeDraft(
                    accountId: accountId,
                    dialogId: dialogId
                )
                for try await observed in values {
                    try Task.checkCancellation()
                    guard let self, self.activeDialogId == dialogId else { return }
                    self.acceptObservedDraft(observed)
                }
            } catch is CancellationError {
                return
            } catch {
                guard let self, self.activeDialogId == dialogId else { return }
                self.status = "Draft observation paused: \(error.localizedDescription)"
            }
        }
    }

    private func acceptObservedDraft(_ observed: LocalDraft?) {
        if let dialogId = activeDialogId,
           draftPersistenceTasks[dialogId] != nil {
            return
        }
        if let observed,
           observed.localGeneration < (minimumObservedDraftGenerations[observed.dialogId] ?? 0) {
            return
        }
        currentDraft = observed
        guard transientUnderlyingDraftText == nil, transientVoiceComposerMode == nil else { return }
        suppressDraftPersistence = true
        draft = observed?.state == "active" ? observed?.text ?? "" : ""
        if let observed, observed.state == "active",
           let reply = observed.replyPreview, let replyId = observed.replyToMsgId {
            composerMode = .replying(
                messageId: "\(observed.dialogId):\(replyId)",
                preview: reply.unavailable
                    ? String(localized: "Original message unavailable")
                    : reply.text
            )
        } else {
            composerMode = .text
        }
        suppressDraftPersistence = false
        guard let observed else { return }
        let nsText = observed.text as NSString
        draftMentionsByDialog[observed.dialogId] = observed.mentions.compactMap { mention in
            let range = NSRange(location: mention.offset, length: mention.length)
            guard NSMaxRange(range) <= nsText.length else { return nil }
            return DraftMention(
                accountId: mention.accountId,
                token: nsText.substring(with: range)
            )
        }
    }

    private func beginConversationSelection(_ dialogId: String) {
        if let previousDialogId = activeDialogId, previousDialogId != dialogId {
            presenceCoordinator.dialogDidChange(from: previousDialogId)
            conversationOpenStartedAt.removeValue(forKey: previousDialogId)
            finishConversationOpenWaiters(dialogId: previousDialogId)
            let pendingPersistence = draftPersistenceTasks[previousDialogId]
            Task { [draftSyncCoordinator] in
                await pendingPersistence?.value
                _ = await draftSyncCoordinator.flush(dialogId: previousDialogId, force: true)
            }
        }
        openingAnchorHydrationGeneration &+= 1
        openingAnchorHydrationTask?.cancel()
        openingAnchorHydrationTask = nil
        draftObservationTask?.cancel()
        draftObservationTask = nil
        activeDialogId = dialogId
        conversationOpenStartedAt[dialogId] = Date()
        dialogSelectionGeneration &+= 1
        currentDraft = nil
        suppressDraftPersistence = true
        draft = ""
        suppressDraftPersistence = false
        composerMode = .text
        // A search result opens *at* its message, so the window is centred rather than
        // bottom-weighted and the anchor is the target instead of the unread watermark.
        let focus = pendingFocusMsgId
        pendingFocusMsgId = nil
        timelineBeforeCount = focus == nil ? 40 : 40
        timelineAfterCount = focus == nil ? 79 : 40
        openingTimelineAnchor = focus.map { .saved(msgId: $0) } ?? .bottom
        focusedSearchMsgId = focus
        timelineTopVisibleMsgId = nil
        timelineIsAtBottom = focus == nil
        pendingVisibleReadMessages = []
        canLoadEarlier = false
        loadingEarlier = false
        canLoadLater = false
        loadingLater = false

        // Publish the in-memory LRU synchronously. Returning chats never wait for Keychain,
        // SQLCipher, anchor resolution, or any network operation before cached bubbles appear.
        let hasPreparedSnapshot = cachedLinesByDialog[dialogId] != nil
        lines = cachedLinesByDialog[dialogId] ?? []
        loadedLocalMessages = cachedLocalMessagesByDialog[dialogId] ?? []
        conversationOpenState = hasPreparedSnapshot ? .cached : .loadingLocal
        #if DEBUG
        if isDemoMode {
            let storedDraft = dialogs.first(where: { $0.id == dialogId })?.draftPreview ?? ""
            suppressDraftPersistence = true
            draft = storedDraft
            suppressDraftPersistence = false
            openingTimelineAnchor = .bottom
            timelineIsAtBottom = true
            timelineTopVisibleMsgId = nil
            lines = demoLinesByDialog[dialogId] ?? []
            canLoadEarlier = false
            dialogs = dialogs.map { dialog in
                guard dialog.id == dialogId, dialog.unreadCount > 0 else { return dialog }
                var updated = dialog
                updated.unreadCount = 0
                updated.mentionCount = 0
                return updated
            }
            conversationOpenState = lines.isEmpty ? .empty : .ready
            recordConversationLocalReady(dialogId: dialogId)
            finishConversationOpenWaiters(dialogId: dialogId)
            return
        }
        #endif
        startDraftObservation(dialogId: dialogId)
        startTimelineObservation(dialogId: dialogId)
        if dialogs.first(where: { $0.id == dialogId })?.type == "group",
           groupMembersByDialog[dialogId] == nil {
            Task { [weak self] in
                await self?.loadGroupProfile(dialogId: dialogId)
            }
        }
    }

    func retryConversationLocalLoad() {
        guard let activeDialogId else { return }
        conversationOpenState = cachedLinesByDialog[activeDialogId] == nil ? .loadingLocal : .cached
        startTimelineObservation(dialogId: activeDialogId)
    }

    func deselectDialog(_ dialogId: String) {
        guard activeDialogId == dialogId else { return }
        closeInChatSearch()
        conversationOpenStartedAt.removeValue(forKey: dialogId)
        finishConversationOpenWaiters(dialogId: dialogId)
        cacheCurrentLines(for: dialogId)
        draftObservationTask?.cancel()
        draftObservationTask = nil
        timelineObservationTask?.cancel()
        timelineObservationTask = nil
        viewportPersistenceTask?.cancel()
        viewportPersistenceTask = nil
        openingAnchorHydrationGeneration &+= 1
        openingAnchorHydrationTask?.cancel()
        openingAnchorHydrationTask = nil
        activeDialogId = nil
        conversationOpenState = .loadingLocal
        currentDraft = nil
        suppressDraftPersistence = true
        draft = ""
        suppressDraftPersistence = false
        composerMode = .text
        canLoadEarlier = false
        loadingEarlier = false
        canLoadLater = false
        loadingLater = false
        dialogSelectionGeneration &+= 1
        timelineLoadGeneration &+= 1
        pendingVisibleReadMessages = []
    }

    /// Captures the semantic anchor and visible-read watermark before navigation tears down the
    /// conversation. Unlike the regular viewport updates, this final write is not debounced.
    func flushAndDeselectDialog(_ dialogId: String) async {
        guard activeDialogId == dialogId else { return }
        await presenceCoordinator.stopLocalTyping(dialogId: dialogId)
        viewportPersistenceTask?.cancel()
        viewportPersistenceTask = nil
        let accountId = storedSession?.session.accountId
        let store = localStore
        let state = accountId.map {
            ChatViewportState(
                dialogId: dialogId,
                accountId: $0,
                topVisibleMsgId: timelineIsAtBottom ? nil : timelineTopVisibleMsgId,
                wasAtBottom: timelineIsAtBottom
            )
        }
        let visibleMessages = pendingVisibleReadMessages
        let pendingDraftPersistence = draftPersistenceTasks[dialogId]

        // Clear presentation state synchronously, before the first suspension point, so a quick
        // navigation into another conversation cannot be undone by this closing task.
        deselectDialog(dialogId)
        await pendingDraftPersistence?.value
        _ = await draftSyncCoordinator.flush(dialogId: dialogId, force: true)
        if let state, let store {
            try? await store.saveViewportState(state)
            await markReadIfNeeded(dialogId: dialogId, messages: visibleMessages)
        }
    }

    func jumpToLatest(_ dialogId: String) async {
        guard activeDialogId == dialogId else { return }
        openingAnchorHydrationGeneration &+= 1
        openingAnchorHydrationTask?.cancel()
        openingAnchorHydrationTask = nil
        openingTimelineAnchor = .bottom
        timelineTopVisibleMsgId = nil
        timelineIsAtBottom = true
        timelineBeforeCount = 40
        timelineAfterCount = 79
        await loadLocalLines(dialogId: dialogId)
    }

    private func startOpeningAnchorHydration(dialogId: String, candidateMsgId: Int64) {
        guard openingAnchorHydrationTask == nil else { return }
        openingAnchorHydrationGeneration &+= 1
        let generation = openingAnchorHydrationGeneration
        openingAnchorHydrationTask = Task { [weak self] in
            guard let self else { return }
            await self.hydrateOpeningAnchor(dialogId: dialogId, candidateMsgId: candidateMsgId)
            if self.openingAnchorHydrationGeneration == generation {
                self.openingAnchorHydrationTask = nil
            }
        }
    }

    /// A bootstrap intentionally carries only five recent messages. Fetch forward from the
    /// persisted read watermark so a large unread gap resolves to the real first unread without
    /// making the initial cached render wait for the network.
    func hydrateOpeningAnchor(dialogId: String, candidateMsgId: Int64) async {
        guard let token = storedSession?.session.token,
              let accountId = storedSession?.session.accountId,
              let localStore else { return }
        var afterMsgId = max(0, candidateMsgId - 1)
        if timelineHasMoreForwardByDialog[dialogId] == true,
           let savedCursor = timelineForwardCursorByDialog[dialogId] {
            afterMsgId = max(afterMsgId, savedCursor)
        }
        var resolvedUnreadMsgId: Int64?
        var reachedEnd = false
        var pagesFetched = 0

        while true {
            if Task.isCancelled || activeDialogId != dialogId || storedSession?.session.token != token {
                return
            }
            do {
                let page = try await api.getHistory(
                    dialogId: dialogId,
                    beforeMsgId: nil,
                    afterMsgId: afterMsgId,
                    limit: TimelineWindow.initialLimit,
                    token: token
                )
                try await localStore.applyTargetedHistoryPage(page)
                timelineHasMoreForwardByDialog[dialogId] = page.hasMore
                if let next = page.nextAfterMsgId {
                    timelineForwardCursorByDialog[dialogId] = next
                }
                if case let .firstUnread(msgId) = try await localStore.resolveOpeningAnchor(
                    dialogId: dialogId,
                    accountId: accountId
                ) {
                    resolvedUnreadMsgId = msgId
                    break
                }
                guard page.hasMore,
                      let next = page.nextAfterMsgId,
                      next > afterMsgId else {
                    reachedEnd = true
                    break
                }
                afterMsgId = next
                pagesFetched += 1
                if pagesFetched.isMultiple(of: 24) {
                    // A very large unread gap must stay correct without monopolizing the executor.
                    await Task.yield()
                }
            } catch is CancellationError {
                return
            } catch {
                BackgroundRuntimeCoordinator.shared.scheduleProcessing()
                return
            }
        }

        guard activeDialogId == dialogId else { return }
        if let resolvedUnreadMsgId {
            openingTimelineAnchor = .firstUnread(msgId: resolvedUnreadMsgId)
            timelineTopVisibleMsgId = resolvedUnreadMsgId
            timelineIsAtBottom = false
        } else if reachedEnd {
            timelineHasMoreForwardByDialog[dialogId] = false
            openingTimelineAnchor = .bottom
            timelineTopVisibleMsgId = nil
            timelineIsAtBottom = true
        }
        await loadLocalLines(dialogId: dialogId)
    }

    func dialogs(matching query: String) -> [Dialog] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return dialogs.filter { !$0.isArchived } }
        return dialogs.filter {
            $0.title.localizedStandardContains(trimmed)
                || $0.subtitle.localizedStandardContains(trimmed)
        }
    }

    func dialogs(matching query: String, scope: SearchScope) -> [Dialog] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return dialogs.filter { !$0.isArchived } }

        switch scope {
        case .chats:
            return dialogs.filter {
                $0.title.localizedStandardContains(trimmed)
                    || $0.subtitle.localizedStandardContains(trimmed)
            }
        case .people:
            return dialogs.filter {
                $0.type == "direct"
                    && !$0.isArchived
                    && $0.title.localizedStandardContains(trimmed)
            }
        case .messages:
            #if DEBUG
            if isDemoMode {
                let matchingIds = Set(demoLinesByDialog.compactMap { dialogId, lines in
                    lines.contains(where: { $0.text.localizedStandardContains(trimmed) }) ? dialogId : nil
                })
                return dialogs.filter { matchingIds.contains($0.id) }
            }
            #endif
            return dialogs(matching: trimmed)
        case .media, .links, .files:
            #if DEBUG
            if isDemoMode {
                let matchingIds = Set(demoLinesByDialog.compactMap { dialogId, lines in
                    let matches = lines.contains { line in
                        guard let attachment = line.attachment else { return false }
                        let typeMatches: Bool
                        switch (scope, attachment) {
                        case (.media, .photo), (.media, .video), (.links, .link), (.files, .file): typeMatches = true
                        default: typeMatches = false
                        }
                        return typeMatches && (
                            attachment.title.localizedStandardContains(trimmed)
                                || line.text.localizedStandardContains(trimmed)
                        )
                    }
                    return matches ? dialogId : nil
                })
                return dialogs.filter { matchingIds.contains($0.id) }
            }
            #endif
            return []
        }
    }

    func loadEarlier() async {
        guard !loadingEarlier else { return }
        guard let dialogId = activeDialogId, let localStore else { return }
        let selectionGeneration = dialogSelectionGeneration
        let preservedAnchor = timelineTopVisibleMsgId
            ?? loadedLocalMessages.compactMap(\.msgId).min()

        loadingEarlier = true
        defer {
            if activeDialogId == dialogId, dialogSelectionGeneration == selectionGeneration {
                loadingEarlier = false
            }
        }

        do {
            let loadedOldest = loadedLocalMessages.compactMap(\.msgId).min()
            let storedOldest = try await localStore.oldestServerMsgId(dialogId: dialogId)
            guard activeDialogId == dialogId, dialogSelectionGeneration == selectionGeneration else {
                return
            }
            guard let beforeMsgId = loadedOldest ?? storedOldest else {
                canLoadEarlier = false
                historyHasMoreByDialog[dialogId] = false
                return
            }

            let earlierLocal = try await localStore.messages(
                dialogId: dialogId,
                limit: TimelineWindow.pageLimit,
                beforeMsgId: beforeMsgId
            )
            guard activeDialogId == dialogId, dialogSelectionGeneration == selectionGeneration else {
                return
            }
            if !earlierLocal.isEmpty {
                // Grow the window around the semantic viewport row; never replace it with the
                // page cursor. SwiftUI restores the same visible target after the prepend.
                timelineTopVisibleMsgId = preservedAnchor
                timelineIsAtBottom = false
                timelineBeforeCount = min(
                    TimelineWindow.maximumRetainedMessages - 1,
                    timelineBeforeCount + TimelineWindow.pageLimit
                )
                timelineAfterCount = min(
                    timelineAfterCount,
                    TimelineWindow.maximumRetainedMessages - timelineBeforeCount - 1
                )
                await loadLocalLines(dialogId: dialogId)
                status = "Earlier messages loaded"
                return
            }

            if let historyState = try await localStore.loadHistoryState(dialogId: dialogId),
               historyState.historyComplete {
                canLoadEarlier = false
                return
            }

            guard let token = storedSession?.session.token else {
                status = "Offline — cached history shown"
                return
            }

            let page = try await api.getHistory(
                dialogId: dialogId,
                beforeMsgId: beforeMsgId,
                limit: TimelineWindow.pageLimit,
                token: token
            )
            try await localStore.applyHistoryPage(page)
            await enqueueArrivalMediaDownloads(page.messages)
            guard activeDialogId == dialogId, dialogSelectionGeneration == selectionGeneration else {
                return
            }
            historyHasMoreByDialog[dialogId] = page.hasMore
            let currentState = try await localStore.loadHistoryState(dialogId: dialogId)
            try await localStore.saveHistoryState(
                DialogHistoryState(
                    dialogId: dialogId,
                    ceilingMsgId: currentState?.ceilingMsgId
                        ?? loadedLocalMessages.compactMap(\.msgId).max()
                        ?? 0,
                    nextBeforeMsgId: page.nextBeforeMsgId,
                    historyComplete: !page.hasMore
                )
            )
            guard activeDialogId == dialogId, dialogSelectionGeneration == selectionGeneration else {
                return
            }
            timelineTopVisibleMsgId = preservedAnchor
            timelineIsAtBottom = false
            timelineBeforeCount = min(
                TimelineWindow.maximumRetainedMessages - 1,
                timelineBeforeCount + TimelineWindow.pageLimit
            )
            timelineAfterCount = min(
                timelineAfterCount,
                TimelineWindow.maximumRetainedMessages - timelineBeforeCount - 1
            )
            await loadLocalLines(dialogId: dialogId)
            status = page.messages.isEmpty ? "No earlier messages" : "History loaded"
        } catch {
            if activeDialogId == dialogId, dialogSelectionGeneration == selectionGeneration {
                status = "History failed: \(error.localizedDescription)"
            }
        }
    }

    /// Extends a centered unread/saved window toward newer rows. Local pages are exposed first;
    /// when a targeted forward fetch reported another page, its keyset cursor resumes that fetch.
    func loadLater() async {
        guard !loadingLater, canLoadLater else { return }
        guard let dialogId = activeDialogId, let localStore else { return }
        let selectionGeneration = dialogSelectionGeneration
        loadingLater = true
        defer {
            if activeDialogId == dialogId, dialogSelectionGeneration == selectionGeneration {
                loadingLater = false
            }
        }

        do {
            let loadedNewest = loadedLocalMessages.compactMap(\.msgId).max()
            var forwardFetchAfterMsgId: Int64?
            if let loadedNewest {
                let newerLocal = try await localStore.messages(
                    dialogId: dialogId,
                    limit: 1,
                    afterMsgId: loadedNewest
                )
                guard activeDialogId == dialogId,
                      dialogSelectionGeneration == selectionGeneration else { return }
                if newerLocal.first?.msgId == loadedNewest + 1 {
                    timelineAfterCount = min(
                        TimelineWindow.maximumRetainedMessages - 1,
                        timelineAfterCount + TimelineWindow.pageLimit
                    )
                    timelineBeforeCount = min(
                        timelineBeforeCount,
                        TimelineWindow.maximumRetainedMessages - timelineAfterCount - 1
                    )
                    await loadLocalLines(dialogId: dialogId)
                    return
                }
                if newerLocal.first?.msgId != nil
                    || timelineHasMoreForwardByDialog[dialogId] == true {
                    // A non-contiguous newer local row is usually the five-message bootstrap
                    // preview. Fill the missing server range before it is allowed on screen.
                    forwardFetchAfterMsgId = loadedNewest
                }
            } else if timelineHasMoreForwardByDialog[dialogId] == true {
                forwardFetchAfterMsgId = timelineForwardCursorByDialog[dialogId]
            }

            guard let afterMsgId = forwardFetchAfterMsgId else {
                canLoadLater = false
                return
            }
            guard let token = storedSession?.session.token else { return }
            let page = try await api.getHistory(
                dialogId: dialogId,
                beforeMsgId: nil,
                afterMsgId: afterMsgId,
                limit: TimelineWindow.pageLimit,
                token: token
            )
            try await localStore.applyTargetedHistoryPage(page)
            guard activeDialogId == dialogId,
                  dialogSelectionGeneration == selectionGeneration else { return }
            timelineHasMoreForwardByDialog[dialogId] = page.hasMore
            if let next = page.nextAfterMsgId {
                timelineForwardCursorByDialog[dialogId] = next
            }
            timelineAfterCount = min(
                TimelineWindow.maximumRetainedMessages - 1,
                timelineAfterCount + TimelineWindow.pageLimit
            )
            timelineBeforeCount = min(
                timelineBeforeCount,
                TimelineWindow.maximumRetainedMessages - timelineAfterCount - 1
            )
            await loadLocalLines(dialogId: dialogId)
        } catch is CancellationError {
            return
        } catch {
            if activeDialogId == dialogId, dialogSelectionGeneration == selectionGeneration {
                status = "Newer history failed: \(error.localizedDescription)"
            }
        }
    }

    func dialogTitle(_ dialogId: String) -> String {
        dialogs.first(where: { $0.id == dialogId })?.title ?? shortDialogId(dialogId)
    }

    func typingSummary(dialogId: String) -> String? {
        guard let dialog = dialogs.first(where: { $0.id == dialogId }), dialog.type != "saved" else {
            return nil
        }
        let accountIds = presenceCoordinator.typingAccountIds(dialogId: dialogId)
        guard !accountIds.isEmpty else { return nil }
        if dialog.type == "direct" { return String(localized: "typing…") }
        let names = accountIds.map { accountId in
            groupMembersByDialog[dialogId]?
                .first(where: { $0.accountId == accountId })?.displayName
                ?? String(localized: "Someone")
        }
        if names.count == 1 {
            return String(format: String(localized: "%@ is typing…"), names[0])
        }
        if names.count == 2 {
            return String(format: String(localized: "%@ and %@ are typing…"), names[0], names[1])
        }
        return String(format: String(localized: "%lld people are typing…"), Int64(names.count))
    }

    func directPresenceSubtitle(dialogId: String) -> String {
        guard capabilities.contains(.presence),
              let peer = dialogs.first(where: { $0.id == dialogId })?.peerAccountId else {
            return String(localized: "status unavailable")
        }
        guard let presence = presenceCoordinator.presence(accountId: peer) else {
            return String(localized: "status unavailable")
        }
        if presence.online { return String(localized: "online") }
        return TojPresenceFormatting.lastSeen(presence.lastSeenAt)
    }

    func userEditedComposer(dialogId: String, text: String, focused: Bool) {
        presenceCoordinator.userEditedDraft(dialogId: dialogId, text: text, focused: focused)
    }

    func composerFocusChanged(dialogId: String, focused: Bool) {
        presenceCoordinator.composerFocusChanged(dialogId: dialogId, focused: focused, text: draft)
    }

    func stopTyping(dialogId: String) async {
        await presenceCoordinator.stopLocalTyping(dialogId: dialogId)
    }
}
