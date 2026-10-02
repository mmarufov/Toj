import Foundation
import Observation
import UIKit

extension CloudAppModel {
    // MARK: - In-chat search

    /// Find-in-conversation state: the matches and where the user is within them.
    struct InChatSearchState: Equatable {
        var query: String = ""
        /// Newest first, matching how results are ordered everywhere else.
        var matches: [Int64] = []
        /// Index into `matches`, or nil before the first jump.
        var currentIndex: Int?

        var isEmpty: Bool { matches.isEmpty }

        /// "3 of 47", one-based for display.
        var positionLabel: String? {
            guard let currentIndex, !matches.isEmpty else { return nil }
            return String(
                format: String(localized: "%1$lld of %2$lld"),
                Int64(currentIndex + 1), Int64(matches.count)
            )
        }
    }

    static let inChatSearchDebounce = Duration.milliseconds(160)

    func openInChatSearch() {
        inChatSearchGeneration &+= 1
        inChatSearchTask?.cancel()
        inChatSearchTask = nil
        inChatSearch = InChatSearchState()
    }

    func closeInChatSearch() {
        inChatSearchGeneration &+= 1
        inChatSearchTask?.cancel()
        inChatSearchTask = nil
        inChatSearch = nil
        focusedSearchMsgId = nil
    }

    /// Debounces and re-runs the in-chat query, then jumps to the newest match.
    ///
    /// SQL/FTS work runs in a detached worker. Cancellation is propagated to that worker, and both
    /// result publication and navigation validate the generation, query, and dialog. A slow query
    /// can therefore do neither of the two harmful stale things: replace newer matches or jump the
    /// conversation after the user has typed again/closed search/switched chats.
    func updateInChatSearch(query: String) async {
        guard var state = inChatSearch, let dialogId = activeDialogId else { return }
        inChatSearchGeneration &+= 1
        let generation = inChatSearchGeneration
        inChatSearchTask?.cancel()
        state.query = query
        state.matches = []
        state.currentIndex = nil
        inChatSearch = state
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let localStore else {
            inChatSearchTask = nil
            return
        }

        let coordinator = searchCoordinator
        let task = Task { [weak self, localStore, coordinator] in
            do {
                try await Task.sleep(for: Self.inChatSearchDebounce)
                try Task.checkCancellation()
                await coordinator?.drainBeforeSearch()
                try Task.checkCancellation()

                let queryTask = Task.detached(priority: .userInitiated) {
                    try Task.checkCancellation()
                    return try await localStore.searchInDialog(dialogId, query: trimmed)
                }
                let matches = try await withTaskCancellationHandler {
                    try await queryTask.value
                } onCancel: {
                    queryTask.cancel()
                }
                try Task.checkCancellation()

                guard let self,
                      self.inChatSearchGeneration == generation,
                      self.activeDialogId == dialogId,
                      self.inChatSearch?.query == query
                else { return }
                self.inChatSearch?.matches = matches
                self.inChatSearch?.currentIndex = matches.isEmpty ? nil : 0
                if let first = matches.first {
                    await self.jumpToSearchMatch(
                        first, expectedSearchGeneration: generation
                    )
                }
            } catch is CancellationError {
                return
            } catch {
                guard let self,
                      self.inChatSearchGeneration == generation,
                      self.activeDialogId == dialogId,
                      self.inChatSearch?.query == query
                else { return }
                self.inChatSearch?.matches = []
                self.inChatSearch?.currentIndex = nil
            }
        }
        inChatSearchTask = task
        await task.value
        if inChatSearchGeneration == generation { inChatSearchTask = nil }
    }

    /// Moves through matches. Wraps, because a find bar that dead-ends at the last match makes the
    /// user re-type to get back to the first.
    func stepInChatSearch(forward: Bool) async {
        guard var state = inChatSearch, !state.matches.isEmpty else { return }
        let generation = inChatSearchGeneration
        let count = state.matches.count
        let current = state.currentIndex ?? 0
        // `matches` is newest-first, so "next" walks toward older messages.
        let next = forward ? (current + 1) % count : (current - 1 + count) % count
        state.currentIndex = next
        inChatSearch = state
        await jumpToSearchMatch(
            state.matches[next], expectedSearchGeneration: generation
        )
    }

    /// Scrolls to a match, pulling the surrounding window from the server if it is not local yet.
    func jumpToSearchMatch(
        _ msgId: Int64, expectedSearchGeneration: UInt64? = nil
    ) async {
        guard let dialogId = activeDialogId else { return }
        if let expectedSearchGeneration {
            guard expectedSearchGeneration == inChatSearchGeneration,
                  inChatSearch != nil
            else { return }
        }
        focusedSearchMsgId = msgId

        let isLocal = loadedLocalMessages.contains { $0.msgId == msgId }
        if !isLocal {
            // The match is outside the loaded window. Hydrating first means the jump lands on the
            // message rather than on whatever happens to be loaded.
            await hydrateOpeningAnchor(dialogId: dialogId, candidateMsgId: msgId)
        }
        guard activeDialogId == dialogId else { return }
        if let expectedSearchGeneration {
            guard expectedSearchGeneration == inChatSearchGeneration,
                  inChatSearch != nil
            else { return }
        }
        openingTimelineAnchor = .saved(msgId: msgId)
        timelineIsAtBottom = false
    }

    /// Ends the flash. Called by the view once the animation completes so a later visit to the same
    /// conversation does not replay it.
    func clearSearchFocus() {
        focusedSearchMsgId = nil
    }

    // MARK: - Search lifecycle

    /// Points the search coordinator at the current account and store, replacing any predecessor.
    ///
    /// `cancelAndWait` before constructing the replacement is the load-bearing part: without it the
    /// outgoing generation's drain overlaps the incoming one's bootstrap, and both write.
    func refreshSearchCoordinator() async {
        guard let localStore, let accountId = storedSession?.session.accountId else {
            await searchCoordinator?.cancelAndWait()
            searchCoordinator = nil
            return
        }
        if let existing = searchCoordinator, existing.serves(accountId: accountId, store: localStore) {
            return
        }
        await searchCoordinator?.cancelAndWait()
        let coordinator = SearchCoordinator(store: localStore, accountId: accountId)
        searchCoordinator = coordinator
        await coordinator.start()
    }

    /// Binds and fully drains the coordinator, for tests that need a deterministic index.
    ///
    /// Production never waits on the index: `refreshSearchCoordinator` starts a background loop and
    /// returns. A test that asserted on search results without a settling point would be timing
    /// dependent, which is worse than slow.
    func refreshSearchCoordinatorForTesting() async {
        guard let localStore else { return }
        await searchCoordinator?.cancelAndWait()
        let accountId = storedSession?.session.accountId ?? "test-account"
        let coordinator = SearchCoordinator(store: localStore, accountId: accountId)
        searchCoordinator = coordinator
        await coordinator.start()
        try? await coordinator.waitUntilIdle()
    }

    func cancelSearchCoordinatorForTesting() async {
        await searchCoordinator?.cancelAndWait()
        searchCoordinator = nil
    }

    /// Search is available while the coordinator serves the current account/store generation.
    /// Unlike every other capability this is decided locally rather than advertised by the server.
    var searchCapability: MessagingCapabilities {
        guard let searchCoordinator, let localStore,
              let accountId = storedSession?.session.accountId,
              searchCoordinator.serves(accountId: accountId, store: localStore)
        else { return [] }
        return .localSearch
    }
}
