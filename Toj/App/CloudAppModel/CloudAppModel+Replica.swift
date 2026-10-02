import Foundation
import Observation
import UIKit

extension CloudAppModel {
    func apply(_ difference: DifferenceResponse) async throws {
        if difference.kind == "difference_too_long" {
            throw CloudAppModelError.bootstrapRequired
        }

        if let localStore, let accountId = storedSession?.session.accountId {
            var scheduleAcknowledgements: [PendingScheduledCreate] = []
            for update in difference.updates ?? [] {
                guard update.type.hasPrefix("scheduled."),
                      let scheduleId = update.scheduledDelivery?.scheduleId,
                      let pending = try? await localStore.pendingScheduledCreate(
                        scheduleId: scheduleId,
                        accountId: accountId
                      ) else { continue }
                scheduleAcknowledgements.append(pending)
            }
            try await localStore.applyDifference(difference, accountId: accountId)
            for pending in scheduleAcknowledgements {
                await clearDraftAfterScheduledAcknowledgement(
                    dialogId: pending.request.dialogId,
                    operationId: pending.draftOperationId,
                    accountId: accountId,
                    localStore: localStore
                )
            }
            let updateTypes = Set((difference.updates ?? []).map(\.type))
            if updateTypes.contains("chat_folders.updated") {
                let snapshot = try await localStore.effectiveChatFolderSnapshot(accountId: accountId)
                chatFolders = snapshot.folders.sorted { $0.position < $1.position }
                chatFolderCollectionRevision = snapshot.collectionRevision
            }
            if !updateTypes.isDisjoint(with: [
                "scheduled.created", "scheduled.updated", "scheduled.canceled", "scheduled.failed",
            ]) {
                scheduledDeliveries = try await localStore.scheduledDeliveries(accountId: accountId)
                    .sorted { $0.deliverAt < $1.deliverAt }
            }
            let revokedDialogIds = Set(
                (difference.updates ?? []).compactMap { update in
                    update.type == "dialog.access_revoked" ? update.dialogId : nil
                }
            )
            if !revokedDialogIds.isEmpty {
                await cancelMediaTransfers(forRevokedDialogs: revokedDialogIds)
                if let token = storedSession?.session.token {
                    try await drainAccessPurges(
                        store: localStore,
                        accountId: accountId,
                        token: token,
                        generation: savedMessagesSessionGeneration
                    )
                }
            }
            if !profileDetails.needsServerSync,
               let session = storedSession?.session,
               let ownProfile = (difference.updates ?? []).reversed().compactMap({ update in
                   Self.cloudProfile(from: update, ownAccountId: accountId)
               }).first {
                await acceptCanonicalProfile(
                    ownProfile,
                    accountId: accountId,
                    deviceId: session.deviceId,
                    token: session.token,
                    generation: accountSessionGeneration,
                    store: localStore
                )
            }
            await enqueueArrivalMediaDownloads((difference.updates ?? []).compactMap { update -> CloudMessage? in
                guard update.type == "message.new" || update.type == "message.edited" else { return nil }
                return update.message
            })
            // Dialog and active-timeline observations publish this transaction once. Explicitly
            // querying both again here caused online-only reload storms during chat opening.
        } else {
            for update in difference.updates ?? [] {
                guard ["message.new", "message.edited", "message.deleted", "reaction.updated"].contains(update.type),
                      let message = update.message else { continue }
                upsert(message)
            }
        }
    }

    func rebuildLocalReplica(token: String) async throws {
        guard let accountId = storedSession?.session.accountId else { return }
        guard let localStore else {
            throw CloudAppModelError.localStoreUnavailable
        }

        status = "Rebuilding local cache"
        func downloadPages(bootstrapToken: String, startingAt initialCursor: String?) async throws {
            var cursor = initialCursor
            while true {
                try Task.checkCancellation()
                let page = try await api.getBootstrapDialogs(
                    bootstrapToken: bootstrapToken,
                    cursor: cursor,
                    limit: 20,
                    previewMessages: 5,
                    token: token
                )
                try await localStore.applyBootstrapPage(page)
                await enqueueArrivalMediaDownloads(page.dialogs.flatMap(\.messages), recentOnly: true)
                guard page.hasMore else { return }
                guard let nextCursor = page.nextCursor else {
                    throw CloudAppModelError.invalidBootstrapCursor
                }
                cursor = nextCursor
            }
        }

        var bootstrapToken: String
        var snapshotPts: Int64
        var startingCursor: String?
        let savedState = try await localStore.loadBootstrapState(accountId: accountId)
        let hasPublishedDialogs = try await localStore.latestDialogId() != nil
        let bootstrapMode = savedState?.mode ?? (hasPublishedDialogs ? .replacement : .initial)
        if let saved = savedState,
           saved.status == "in_progress", let savedToken = saved.token {
            bootstrapToken = savedToken
            snapshotPts = saved.snapshotPts
            startingCursor = saved.nextCursor
        } else {
            let bootstrap = try await api.startBootstrap(token: token)
            bootstrapToken = bootstrap.token
            snapshotPts = bootstrap.state.pts
            startingCursor = nil
            try await localStore.beginBootstrap(
                accountId: accountId,
                token: bootstrapToken,
                snapshotPts: snapshotPts,
                mode: bootstrapMode
            )
        }

        do {
            try await downloadPages(bootstrapToken: bootstrapToken, startingAt: startingCursor)
        } catch let error as CloudAPIError
            where error.status == 400 && error.message.localizedCaseInsensitiveContains("bootstrap") {
            let bootstrap = try await api.startBootstrap(token: token)
            bootstrapToken = bootstrap.token
            snapshotPts = bootstrap.state.pts
            startingCursor = nil
            try await localStore.beginBootstrap(
                accountId: accountId,
                token: bootstrapToken,
                snapshotPts: snapshotPts,
                mode: bootstrapMode
            )
            try await downloadPages(bootstrapToken: bootstrapToken, startingAt: nil)
        }

        try await localStore.finishBootstrap(accountId: accountId, pts: snapshotPts)
        pts = snapshotPts
        BackgroundRuntimeCoordinator.shared.scheduleProcessing()
    }

    func refreshDialogs() async {
        let interval = LocalFirstMetrics.begin("Dialog query")
        defer { LocalFirstMetrics.end("Dialog query", interval) }
        guard let localStore, let accountId = storedSession?.session.accountId else { return }
        do {
            let localDialogs = try await localStore.dialogs(accountId: accountId)
            acceptObservedDialogs(localDialogs)
        } catch {
            status = "Dialog load failed: \(error.localizedDescription)"
        }
    }

    func cacheCurrentLines(for dialogId: String) {
        cachedLinesByDialog[dialogId] = lines
        cachedLocalMessagesByDialog[dialogId] = loadedLocalMessages
        cachedConversationCostByDialog[dialogId] = Self.preparedConversationCost(
            lines: lines,
            messages: loadedLocalMessages
        )
        cachedLineDialogOrder.removeAll { $0 == dialogId }
        cachedLineDialogOrder.append(dialogId)
        while cachedLineDialogOrder.count > 12
            || cachedConversationCostByDialog.values.reduce(0, +) > 8 * 1_024 * 1_024 {
            let evicted = cachedLineDialogOrder.removeFirst()
            cachedLinesByDialog.removeValue(forKey: evicted)
            cachedLocalMessagesByDialog.removeValue(forKey: evicted)
            cachedConversationCostByDialog.removeValue(forKey: evicted)
        }
    }

    func purgePreparedConversations() {
        guard let activeDialogId,
              let activeLines = cachedLinesByDialog[activeDialogId],
              let activeMessages = cachedLocalMessagesByDialog[activeDialogId] else {
            cachedLinesByDialog.removeAll(keepingCapacity: true)
            cachedLocalMessagesByDialog.removeAll(keepingCapacity: true)
            cachedLineDialogOrder.removeAll(keepingCapacity: true)
            cachedConversationCostByDialog.removeAll(keepingCapacity: true)
            return
        }
        cachedLinesByDialog = [activeDialogId: activeLines]
        cachedLocalMessagesByDialog = [activeDialogId: activeMessages]
        cachedLineDialogOrder = [activeDialogId]
        cachedConversationCostByDialog = [
            activeDialogId: Self.preparedConversationCost(lines: activeLines, messages: activeMessages)
        ]
    }

    nonisolated private static func preparedConversationCost(
        lines: [Line],
        messages: [LocalMessage]
    ) -> Int {
        let lineStrings = lines.reduce(0) {
            $0 + $1.text.utf8.count + ($1.replyPreview?.utf8.count ?? 0) + 192
        }
        let messageStrings = messages.reduce(0) {
            $0 + $1.text.utf8.count + $1.clientMsgId.utf8.count + 160
        }
        return lineStrings + messageStrings
    }

    func loadLocalLines(
        dialogId: String,
        observedSnapshot: ConversationLocalSnapshot? = nil
    ) async {
        let timelineInterval = LocalFirstMetrics.begin("Timeline query")
        defer { LocalFirstMetrics.end("Timeline query", timelineInterval) }
        guard let localStore, activeDialogId == dialogId else { return }
        timelineLoadGeneration &+= 1
        let loadGeneration = timelineLoadGeneration
        let selectionGeneration = dialogSelectionGeneration
        do {
            let conversationSnapshot: ConversationLocalSnapshot
            let centeredAnchorMsgId = timelineIsAtBottom ? nil : timelineTopVisibleMsgId
            if let observedSnapshot, centeredAnchorMsgId == nil {
                conversationSnapshot = observedSnapshot
            } else if let anchorMsgId = centeredAnchorMsgId {
                let base = try await localStore.conversationSnapshot(
                    dialogId: dialogId,
                    window: .initial
                )
                let centeredTimeline = try await localStore.timelineWindow(
                    dialogId: dialogId,
                    anchorMsgId: anchorMsgId,
                    beforeCount: timelineBeforeCount,
                    afterCount: timelineAfterCount
                )
                conversationSnapshot = ConversationLocalSnapshot(
                    timeline: centeredTimeline,
                    mutations: base.mutations,
                    transfers: base.transfers,
                    peerReadMsgId: base.peerReadMsgId,
                    historyState: base.historyState
                )
            } else {
                conversationSnapshot = try await localStore.conversationSnapshot(
                    dialogId: dialogId,
                    window: .initial
                )
            }
            let snapshot = conversationSnapshot.timeline
            // Sparse bootstrap previews can sit thousands of IDs ahead of a hydrated unread page.
            // Never render that hole as if the rows were adjacent; expose only the contiguous run
            // around the semantic anchor and let `loadLater` fill the missing keyset pages.
            let messages = centeredAnchorMsgId.map {
                Self.contiguousTimelineSlice(snapshot.messages, anchorMsgId: $0)
            } ?? snapshot.messages
            let rawOldest = snapshot.messages.compactMap(\.msgId).min()
            let rawNewest = snapshot.messages.compactMap(\.msgId).max()
            let displayOldest = messages.compactMap(\.msgId).min()
            let displayNewest = messages.compactMap(\.msgId).max()
            let trimmedEarlierRows = rawOldest != nil && rawOldest != displayOldest
            let trimmedLaterRows = rawNewest != nil && rawNewest != displayNewest
            let mutations = conversationSnapshot.mutations
            let transfers = conversationSnapshot.transfers
            let transfersByClientMessage = Dictionary(
                transfers.map { ($0.clientMsgId, $0) },
                uniquingKeysWith: { _, newer in newer }
            )
            let mutationsByMessage = Dictionary(
                mutations.map { ($0.msgId, $0) },
                uniquingKeysWith: { _, newer in newer }
            )
            let peerReadMsgId = conversationSnapshot.peerReadMsgId
            let messagesById = Dictionary(uniqueKeysWithValues: messages.compactMap { message in
                message.msgId.map { ($0, message) }
            })
            var preparedLines = messages.compactMap { message -> Line? in
                let mutation = message.msgId.flatMap { mutationsByMessage[$0] }
                guard Self.shouldDisplayInTimeline(
                    messageState: message.state,
                    pendingMutationOperation: mutation?.operation
                ) else { return nil }
                let replyPreview = message.replyToMsgId.map { targetId in
                    guard let target = messagesById[targetId] else { return String(localized: "Earlier message") }
                    return target.state == "deleted_for_all" ? String(localized: "Earlier message") : target.text
                }
                return line(
                    from: message,
                    peerReadMsgId: peerReadMsgId,
                    replyPreview: replyPreview,
                    mutation: mutation,
                    mediaTransfer: transfersByClientMessage[message.clientMsgId]
                )
            }
            let presentationInputs = preparedLines.map {
                TimelinePresentationInput(
                    id: $0.id,
                    mine: $0.mine,
                    senderId: $0.senderAccountId,
                    timestamp: $0.timestamp
                )
            }
            let presentation = await Task.detached(priority: .userInitiated) {
                TimelinePresentationBuilder.build(presentationInputs)
            }.value
            let presentationByID = Dictionary(uniqueKeysWithValues: presentation.map { ($0.id, $0) })
            for index in preparedLines.indices {
                guard let metadata = presentationByID[preparedLines[index].id] else { continue }
                preparedLines[index].presentationDayLabel = metadata.dayLabel
                preparedLines[index].presentationTimestampLabel = metadata.timestampLabel
                preparedLines[index].presentationMediaTimestampLabel = metadata.mediaTimestampLabel
                preparedLines[index].presentationIsFirstInGroup = metadata.isFirstInGroup
                preparedLines[index].presentationIsLastInGroup = metadata.isLastInGroup
            }
            let historyState = conversationSnapshot.historyState
            guard activeDialogId == dialogId,
                  dialogSelectionGeneration == selectionGeneration,
                  timelineLoadGeneration == loadGeneration else { return }

            loadedLocalMessages = messages
            lines = preparedLines
            conversationOpenState = preparedLines.isEmpty ? .empty : .ready
            recordConversationLocalReady(dialogId: dialogId)
            canLoadLater = snapshot.hasLaterLocalMessages
                || trimmedLaterRows
                || timelineHasMoreForwardByDialog[dialogId] == true
            canLoadEarlier = snapshot.hasEarlierLocalMessages
                || trimmedEarlierRows
                || historyState.map { !$0.historyComplete } == true
                || (snapshot.oldestServerMsgId != nil && historyState == nil)
            cacheCurrentLines(for: dialogId)
            finishConversationOpenWaiters(dialogId: dialogId)
            if openPrefetchGeneration != selectionGeneration {
                openPrefetchGeneration = selectionGeneration
                await enqueueArrivalMediaDownloads(window: messages)
            }
        } catch {
            if activeDialogId == dialogId,
               dialogSelectionGeneration == selectionGeneration,
               timelineLoadGeneration == loadGeneration {
                conversationOpenState = .failedLocal
                status = "Local load failed: \(error.localizedDescription)"
                conversationOpenStartedAt.removeValue(forKey: dialogId)
                finishConversationOpenWaiters(dialogId: dialogId)
            }
        }
    }

    func finishConversationOpenWaiters(dialogId: String) {
        let waiters = conversationOpenWaiters.removeValue(forKey: dialogId) ?? []
        waiters.forEach { $0.resume() }
    }

    func recordConversationLocalReady(dialogId: String) {
        guard let startedAt = conversationOpenStartedAt.removeValue(forKey: dialogId) else { return }
        LocalFirstMetrics.duration("Chat tap to local snapshot", since: startedAt)
    }

    nonisolated static func shouldDisplayInTimeline(
        messageState: String,
        pendingMutationOperation: String?
    ) -> Bool {
        messageState != "deleted_for_all" && pendingMutationOperation != "delete"
    }

    nonisolated static func contiguousTimelineSlice(
        _ messages: [LocalMessage],
        anchorMsgId: Int64
    ) -> [LocalMessage] {
        guard let anchorIndex = messages.firstIndex(where: { $0.msgId == anchorMsgId }) else {
            return messages
        }
        var lowerBound = anchorIndex
        while lowerBound > messages.startIndex {
            let previousIndex = messages.index(before: lowerBound)
            guard let previous = messages[previousIndex].msgId,
                  let current = messages[lowerBound].msgId,
                  previous + 1 == current else { break }
            lowerBound = previousIndex
        }
        var upperBound = anchorIndex
        while upperBound < messages.index(before: messages.endIndex) {
            let nextIndex = messages.index(after: upperBound)
            guard let current = messages[upperBound].msgId,
                  let next = messages[nextIndex].msgId,
                  current + 1 == next else { break }
            upperBound = nextIndex
        }
        return Array(messages[lowerBound...upperBound])
    }

    private func line(
        from message: LocalMessage,
        peerReadMsgId: Int64,
        replyPreview: String?,
        mutation: PendingMessageMutation? = nil,
        mediaTransfer: MediaTransferRecord? = nil
    ) -> Line {
        let senderIsCurrentAccount = message.senderAccountId == storedSession?.session.accountId
        let mine = message.kind == "service"
            ? VoiceCallServicePresentation.callerIsCurrentAccount(
                body: message.text,
                currentAccountId: storedSession?.session.accountId
            ) ?? senderIsCurrentAccount
            : senderIsCurrentAccount
        let deliveryState: Line.Delivery
        if let mediaTransfer, mediaTransfer.terminal {
            deliveryState = .failed(mediaTransfer.lastError ?? String(localized: "Attachment failed"))
        } else if mutation != nil {
            deliveryState = .sending
        } else if mine, let msgId = message.msgId, msgId <= peerReadMsgId {
            deliveryState = .seen
        } else {
            deliveryState = delivery(from: message.localState)
        }
        var reactions = message.reactions
        if mutation?.operation == "reaction", let accountId = storedSession?.session.accountId {
            reactions.removeAll { $0.accountId == accountId }
            if let emoji = mutation?.emoji {
                reactions.append(CloudReaction(accountId: accountId, emoji: emoji))
            }
        }
        let presentedText: String
        if mutation?.operation == "edit", let body = mutation?.body {
            presentedText = body
        } else {
            presentedText = message.text
        }
        return Line(
            id: message.localId,
            dialogId: message.dialogId,
            msgId: message.msgId,
            clientMsgId: message.clientMsgId,
            senderAccountId: message.senderAccountId,
            senderDisplayName: message.senderDisplayName,
            text: presentedText,
            kind: message.kind,
            serviceType: message.serviceType,
            serviceData: message.serviceData,
            linkPreview: message.linkPreview,
            mine: mine,
            delivery: deliveryState,
            timestamp: message.serverTs,
            replyToMsgId: message.replyToMsgId,
            replyPreview: replyPreview,
            reactions: Self.reactionBadges(reactions),
            myReaction: reactions.first(where: { $0.accountId == storedSession?.session.accountId })?.emoji,
            forwardedFromAccountId: message.forwardedFromAccountId,
            forwardedFromDialogId: message.forwardedFromDialogId,
            forwardedFromMsgId: message.forwardedFromMsgId,
            isForwarded: message.isForwarded,
            editVersion: message.editVersion,
            isEdited: (message.editVersion > 0 || mutation?.operation == "edit") && message.state == "visible",
            isDeleted: message.state == "deleted_for_all",
            media: message.media,
            mediaGroupId: message.mediaGroupId,
            mediaGroupIndex: message.mediaGroupIndex,
            mediaGroupCount: message.mediaGroupCount,
            transferProgress: mediaTransfer.map {
                $0.state == "ready_to_send" ? 1 : Double($0.uploadOffset) / Double(max(1, $0.byteSize))
            },
            transferStage: mediaTransfer.map {
                if $0.state == "ready_to_send" { return .finalizing }
                if $0.retryCount > 0 || $0.lastError != nil { return .retrying }
                if $0.uploadOffset == 0 { return .preparing }
                return .uploading
            },
            transferError: mediaTransfer?.lastError,
            pendingMutation: mutation
        )
    }

    func dialog(from local: LocalDialog) -> Dialog {
        let isSavedMessages = local.type == "saved"
        let title = isSavedMessages
            ? String(localized: "Saved Messages")
            : displayTitle(local.title, fallback: shortDialogId(local.dialogId))
        let lastText = local.lastText?.trimmingCharacters(in: .whitespacesAndNewlines)
        let previewKind = ChatListPreviewKind(messageKind: local.lastKind)
        let subtitle: String
        if local.lastKind == "service", let lastText, !lastText.isEmpty {
            subtitle = VoiceCallServicePresentation.parse(
                body: lastText,
                callerIsCurrentAccount: local.lastSenderAccountId == storedSession?.session.accountId,
                currentAccountId: storedSession?.session.accountId
            ).title
        } else if let lastText, !lastText.isEmpty {
            subtitle = lastText
        } else if local.lastState == "visible" {
            subtitle = previewKind.title.isEmpty ? String(localized: "Attachment") : previewKind.title
        } else {
            subtitle = "No messages yet"
        }
        return Dialog(
            id: local.dialogId,
            title: title,
            photo: local.photo,
            type: local.type,
            subtitle: subtitle,
            updatedAt: local.lastServerTs ?? local.updatedAt,
            isPending: local.lastLocalState == "sending" || local.accessState == "pending",
            unreadCount: isSavedMessages ? 0 : local.unreadCount,
            isPinned: local.isPinned,
            pinnedAt: local.pinnedAt,
            isMuted: isSavedMessages ? false : local.isMuted,
            isArchived: isSavedMessages ? false : local.isArchived,
            mentionCount: isSavedMessages ? 0 : local.mentionCount,
            previewKind: previewKind,
            lastMessageMine: local.lastSenderAccountId == storedSession?.session.accountId,
            peerAccountId: local.peerAccountId,
            peerBio: local.peerBio,
            peerBirthday: local.peerBirthday,
            profileColorIndex: local.peerColorIndex,
            memberCount: local.memberCount,
            selfRole: local.selfRole,
            notificationMode: isSavedMessages ? "all" : local.notificationMode,
            accessState: local.accessState,
            lastMsgId: local.lastMsgId
        )
    }

    func displayTitle(_ candidate: String?, fallback: String) -> String {
        let trimmed = candidate?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? fallback : trimmed
    }

    static func profileDetails(from displayName: String) -> StoredProfileDetails {
        let parts = displayName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
        return StoredProfileDetails(
            username: nil,
            firstName: parts.first ?? "",
            lastName: parts.dropFirst().joined(separator: " "),
            bio: "",
            birthday: nil,
            colorIndex: 0
        )
    }

    static func profileDetails(
        from profile: CloudProfile,
        pendingSync: Bool
    ) -> StoredProfileDetails {
        StoredProfileDetails(
            username: profile.username,
            firstName: profile.firstName,
            lastName: profile.lastName,
            bio: profile.bio,
            birthday: profile.birthday.flatMap(profileDate),
            colorIndex: profile.colorIndex,
            serverUpdatedAt: profile.updatedAt,
            pendingSync: pendingSync
        )
    }

    private static func profileDate(_ value: String) -> Date? {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: value)
    }

    static func cloudProfile(from contact: ContactLookupResponse) -> CloudProfile? {
        guard
            let accountId = contact.accountId,
            let firstName = contact.firstName,
            let lastName = contact.lastName,
            let displayName = contact.displayName,
            let bio = contact.bio,
            let colorIndex = contact.colorIndex,
            let updatedAt = contact.updatedAt
        else { return nil }
        return CloudProfile(
            accountId: accountId, username: contact.username, firstName: firstName, lastName: lastName,
            displayName: displayName, bio: bio, birthday: contact.birthday,
            colorIndex: colorIndex, photo: contact.photo,
            photoRevision: contact.photoRevision ?? 0, updatedAt: updatedAt
        )
    }

    static func cloudProfile(from update: CloudUpdate, ownAccountId: String) -> CloudProfile? {
        guard
            update.type == "profile.updated",
            update.subjectAccountId == ownAccountId,
            let firstName = update.firstName,
            let lastName = update.lastName,
            let displayName = update.displayName,
            let bio = update.bio,
            let colorIndex = update.colorIndex,
            let updatedAt = update.profileUpdatedAt
        else { return nil }
        return CloudProfile(
            accountId: ownAccountId, username: update.username, firstName: firstName, lastName: lastName,
            displayName: displayName, bio: bio, birthday: update.birthday,
            colorIndex: colorIndex, photo: update.photo,
            photoRevision: update.photoRevision ?? 0, updatedAt: updatedAt
        )
    }

    static func cleanedProfileText(
        _ value: String,
        limit: Int,
        preservesNewlines: Bool = false
    ) -> String {
        let normalized = preservesNewlines
            ? value.replacingOccurrences(of: "\r\n", with: "\n")
            : value.replacingOccurrences(of: "\n", with: " ")
        return String(normalized.prefix(limit)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func cleanedUsername(_ value: String?) -> String? {
        let cleaned = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "@"))
        return cleaned.isEmpty ? nil : String(cleaned.prefix(32))
    }

    func shortDialogId(_ dialogId: String) -> String {
        String(dialogId.prefix(8))
    }

    private func delivery(from localState: String) -> Line.Delivery {
        switch localState {
        case "sending": return .sending
        case "failed": return .failed("failed")
        default: return .sent
        }
    }
}
