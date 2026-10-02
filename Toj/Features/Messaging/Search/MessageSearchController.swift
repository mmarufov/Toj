import Foundation
import Observation

/// Drives the search screen: debounce, cancellation, sectioning, and coverage.
///
/// Replaces a computed property that re-ran a linear scan over every dialog on every keystroke,
/// synchronously, on the main actor. The important properties here are the ones that were missing:
/// work is debounced, in-flight work is cancelled, and a slow response can never overwrite a newer
/// one.
///
/// The backend is a protocol so the controller's own logic — ordering, staleness, section
/// assembly — can be tested without a database. `CloudLocalStore` conforms in production.
@MainActor
@Observable
final class MessageSearchController {
    enum Phase: Equatable {
        case idle
        /// Typing settled, query running. Previous results stay on screen; blanking the list on
        /// every keystroke reads as breakage rather than progress.
        case searching
        case results
        case empty
        /// The index is unavailable or rebuilding. Chats and people still work.
        case degraded
    }

    /// Results grouped the way the screen renders them.
    struct Sections: Equatable {
        var chats: [CloudAppModel.Dialog] = []
        var messages: [MessageSearchHit] = []
        var isEmpty: Bool { chats.isEmpty && messages.isEmpty }
    }

    /// How long typing must settle before a query runs. Long enough to skip intermediate
    /// keystrokes, short enough to feel immediate.
    static let debounce = Duration.milliseconds(160)

    private(set) var phase: Phase = .idle
    private(set) var sections = Sections()
    private(set) var coverage: SearchIndexer.Coverage?
    private(set) var isLoadingMore = false

    var query: String = "" {
        didSet { if query != oldValue { scheduleSearch() } }
    }

    var scope: SearchScope = .chats {
        didSet { if scope != oldValue { scheduleSearch(immediately: true) } }
    }

    private let backend: MessageSearchBackend
    private let dialogsProvider: @MainActor () -> [CloudAppModel.Dialog]

    private var searchTask: Task<Void, Never>?
    /// Monotonic, so a response that outlives its query is discarded rather than applied. Without
    /// it a slow first request can land after a fast second and show results for text the user has
    /// already replaced.
    private var generation = 0
    private var nextCursor: MessageSearchCursor?

    init(
        backend: MessageSearchBackend,
        dialogs: @escaping @MainActor () -> [CloudAppModel.Dialog]
    ) {
        self.backend = backend
        self.dialogsProvider = dialogs
    }

    // MARK: - Driving

    private func scheduleSearch(immediately: Bool = false) {
        searchTask?.cancel()
        generation &+= 1
        let generation = self.generation

        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty, !scope.browsesWithoutQuery {
            phase = .idle
            sections = Sections()
            nextCursor = nil
            return
        }

        phase = .searching
        searchTask = Task { [weak self] in
            if !immediately {
                try? await Task.sleep(for: Self.debounce)
                if Task.isCancelled { return }
            }
            await self?.run(generation: generation)
        }
    }

    private func run(generation: Int) async {
        // Index writes are cheap and bounded here; a message sent moments ago should be findable.
        await backend.drainBeforeSearch()
        guard generation == self.generation else { return }

        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let chats: [CloudAppModel.Dialog]
        switch scope {
        case .chats:
            chats = Self.matchingDialogs(dialogsProvider(), query: trimmed)
        case .people:
            chats = Self.matchingPeople(dialogsProvider(), query: trimmed)
        case .messages, .media, .links, .files:
            chats = []
        }

        var messages: [MessageSearchHit] = []
        var cursor: MessageSearchCursor?
        if let searchScope = scope.messageScope {
            let page = await backend.search(MessageSearchRequest(
                query: trimmed, scope: searchScope, limit: 40
            ))
            messages = page.hits
            cursor = page.cursor
        }

        let coverage = await backend.coverage()
        guard generation == self.generation else { return }

        self.coverage = coverage
        self.nextCursor = cursor
        self.sections = Sections(chats: chats, messages: messages)
        self.phase = Self.phase(for: sections, coverage: coverage)
    }

    private static func phase(for sections: Sections, coverage: SearchIndexer.Coverage?) -> Phase {
        if sections.isEmpty {
            // An unavailable index is a different answer from "no matches", and the screen says so.
            if let coverage, coverage.status == .unavailable { return .degraded }
            return .empty
        }
        return .results
    }

    /// Appends the next page. Silently ignores a request whose query has already moved on.
    func loadMore() {
        guard let cursor = nextCursor, !isLoadingMore, let searchScope = scope.messageScope else { return }
        let generation = self.generation
        isLoadingMore = true

        Task { [weak self] in
            guard let self else { return }
            let page = await backend.search(MessageSearchRequest(
                query: query.trimmingCharacters(in: .whitespacesAndNewlines),
                scope: searchScope, limit: 40, cursor: cursor
            ))
            guard generation == self.generation else {
                self.isLoadingMore = false
                return
            }
            self.sections.messages += page.hits
            self.nextCursor = page.cursor
            self.isLoadingMore = false
        }
    }

    func cancel() {
        searchTask?.cancel()
        searchTask = nil
    }

    // MARK: - Presentation helpers

    /// Ranges to highlight inside a hit, computed from the original text so display keeps its
    /// accents and letter forms.
    func highlightRanges(in hit: MessageSearchHit) -> [Range<String.Index>] {
        SearchTextNormalizer.highlightRanges(
            of: query.trimmingCharacters(in: .whitespacesAndNewlines), in: displayText(for: hit)
        )
    }

    /// Prefer the field that actually matched. Filename-only results used to render an empty
    /// caption, which made a successful Files search look like a broken blank row.
    func displayText(for hit: MessageSearchHit) -> String {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = hit.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let files = hit.fileNames.trimmingCharacters(in: .whitespacesAndNewlines)
        let fileMatched = !query.isEmpty
            && !SearchTextNormalizer.highlightRanges(of: query, in: files).isEmpty

        if fileMatched || (scope == .files && !files.isEmpty) { return files }
        if !body.isEmpty { return body }
        if !files.isEmpty { return files }
        return String(localized: "Attachment")
    }

    /// Non-nil while history is still downloading, so the screen can say results are partial rather
    /// than letting the user conclude a message does not exist.
    var partialCoverageMessage: String? {
        guard let coverage, !coverage.isComplete, coverage.dialogsTotal > 0 else { return nil }
        if coverage.status == .unavailable { return String(localized: "Search is unavailable") }
        guard coverage.dialogsComplete < coverage.dialogsTotal else { return nil }
        return String(
            format: String(
                localized: "Searching %1$lld of %2$lld chats — still downloading history"
            ),
            Int64(coverage.dialogsComplete), Int64(coverage.dialogsTotal)
        )
    }

    /// Dialog title and preview matching, folded the same way message text is so a Russian-keyboard
    /// query reaches a Tajik chat name too.
    static func matchingDialogs(
        _ dialogs: [CloudAppModel.Dialog], query: String
    ) -> [CloudAppModel.Dialog] {
        guard !query.isEmpty else { return [] }
        let needles = SearchTextNormalizer.tokens(SearchTextNormalizer.foldedForm(query))
        guard !needles.isEmpty else { return [] }

        return dialogs.filter { dialog in
            guard !dialog.isArchived else { return false }
            let haystack = SearchTextNormalizer.foldedForm("\(dialog.title) \(dialog.subtitle)")
            let tokens = SearchTextNormalizer.tokens(haystack)
            return needles.allSatisfy { needle in tokens.contains { $0.hasPrefix(needle) } }
        }
    }

    /// People scope is the direct-conversation subset and searches identity, not the last-message
    /// preview. Group and Saved Messages rows stay in Chats, while archived direct conversations
    /// remain hidden consistently with the main list.
    static func matchingPeople(
        _ dialogs: [CloudAppModel.Dialog], query: String
    ) -> [CloudAppModel.Dialog] {
        guard !query.isEmpty else { return [] }
        let needles = SearchTextNormalizer.tokens(SearchTextNormalizer.foldedForm(query))
        guard !needles.isEmpty else { return [] }

        return dialogs.filter { dialog in
            guard dialog.type == "direct", !dialog.isArchived else { return false }
            let tokens = SearchTextNormalizer.tokens(
                SearchTextNormalizer.foldedForm(dialog.title)
            )
            return needles.allSatisfy { needle in tokens.contains { $0.hasPrefix(needle) } }
        }
    }
}

/// What the controller needs from storage. A protocol so controller logic is testable without a
/// database, and so the search screen never reaches into `CloudLocalStore` directly.
protocol MessageSearchBackend: Sendable {
    func search(_ request: MessageSearchRequest) async -> MessageSearchPage
    func coverage() async -> SearchIndexer.Coverage?
    func drainBeforeSearch() async
}

/// Production backend: the local store for queries, the coordinator for lifecycle.
struct LocalMessageSearchBackend: MessageSearchBackend {
    let store: CloudLocalStore
    let coordinator: SearchCoordinator

    func search(_ request: MessageSearchRequest) async -> MessageSearchPage {
        // A failed search is an empty search. Nothing the user can do about a query error, and an
        // error state here would be indistinguishable from "no results" anyway.
        (try? await store.searchMessages(request)) ?? MessageSearchPage(hits: [], cursor: nil)
    }

    func coverage() async -> SearchIndexer.Coverage? {
        try? await coordinator.coverage()
    }

    func drainBeforeSearch() async {
        await coordinator.drainBeforeSearch()
    }
}

extension SearchScope {
    /// The message-index scope, or `nil` for scopes served entirely from memory.
    var messageScope: MessageSearchScope? {
        switch self {
        case .chats, .people: nil
        case .messages: .messages
        case .media: .media
        case .files: .files
        case .links: .links
        }
    }

    /// Scopes that show content before the user types — shared media, all links, all files.
    var browsesWithoutQuery: Bool {
        switch self {
        case .media, .files, .links: true
        case .chats, .people, .messages: false
        }
    }
}
