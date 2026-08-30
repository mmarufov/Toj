import Foundation
import GRDB
import os

/// `AsyncValueObservation` is not declared Sendable even though GRDB's values sequence is safe to
/// consume from one detached task. Keep the unchecked boundary narrow, matching the store's other
/// observation adapters.
nonisolated private final class SearchQueueObservationBox<Element>: @unchecked Sendable {
    let values: AsyncValueObservation<Element>

    init(_ values: AsyncValueObservation<Element>) {
        self.values = values
    }
}

/// Owns the search index's lifecycle for one account on one store.
///
/// Lives outside `CloudAppModel` deliberately: that type is already 10k lines, and none of this
/// needs the main actor. What it does need is a **generation** — an account id plus the store
/// instance it belongs to. Sign out and back in, or recover a quarantined replica, and the old
/// coordinator's in-flight drain is writing to a database that no longer represents the signed-in
/// user. Every unit of work re-checks its generation before touching anything, and ``cancelAndWait``
/// gives the caller a point where the previous generation is provably finished.
///
/// ## Shape of the work
///
/// - ``start()`` bootstraps and kicks off background draining.
/// - ``drainBeforeSearch()`` is the bounded foreground path: it runs on a keystroke, so it is
///   capped and gives up rather than blocking.
/// - The background loop drains the live queue to empty, then advances the backfill one page at a
///   time, yielding between units so a send never waits behind history from 2019.
/// - ``runMaintenance()`` folds in the audit and the tombstone merge, for a BGTask to call.
actor SearchCoordinator {
    /// Identifies the account-and-store pair this coordinator serves.
    ///
    /// The store identity matters as much as the account: recovering a quarantined replica produces
    /// a new `CloudLocalStore` for the *same* account, and work queued against the old one must not
    /// resume against the new.
    struct Generation: Equatable, Sendable {
        let accountId: String
        let storeId: ObjectIdentifier
    }

    /// How long the foreground drain may spend before a search proceeds without it.
    ///
    /// A search must feel immediate. Missing a message that landed milliseconds ago is a smaller
    /// failure than a search box that stalls.
    static let foregroundDrainBudget = 200

    /// Pause between background units, so indexing never monopolises the writer.
    static let backgroundIdleNanoseconds: UInt64 = 50_000_000  // 50ms

    private let store: CloudLocalStore
    private let indexer: SearchIndexer
    private let generation: Generation
    private let signposter = OSSignposter(subsystem: "com.toj.Toj", category: "SearchCoordinator")

    private var backgroundTask: Task<Void, Never>?
    private var queueObservationTask: Task<Void, Never>?
    /// Set by every queue observation, including one that races with the loop deciding it is idle.
    /// The actor clears it only when beginning another unit of work.
    private var backgroundWakeRequested = false
    private var isCancelled = false

    init(store: CloudLocalStore, accountId: String) {
        self.store = store
        self.indexer = SearchIndexer(store: store)
        self.generation = Generation(accountId: accountId, storeId: ObjectIdentifier(store))
    }

    nonisolated var accountId: String { generation.accountId }

    /// Whether this coordinator still serves the given account and store.
    nonisolated func serves(accountId: String, store other: CloudLocalStore) -> Bool {
        generation == Generation(accountId: accountId, storeId: ObjectIdentifier(other))
    }

    // MARK: - Lifecycle

    /// Bootstraps the index and starts background draining.
    ///
    /// Safe to call more than once: a running background loop is left alone rather than duplicated.
    func start() async {
        guard !isCancelled else { return }
        await indexer.bootstrap()
        guard !isCancelled else { return }
        startQueueObservation()
        requestBackgroundDrain()
    }

    /// Stops scheduling new work. Returns immediately; in-flight work may still be finishing.
    func cancel() {
        isCancelled = true
        backgroundTask?.cancel()
        queueObservationTask?.cancel()
    }

    /// Stops and waits for the background loop to finish.
    ///
    /// The point of the pair is sequencing: a caller replacing this coordinator awaits this before
    /// constructing the next, so two generations never write concurrently. `cancel()` alone cannot
    /// promise that, and a caller that only calls it will interleave the old drain with the new
    /// bootstrap.
    func cancelAndWait() async {
        cancel()
        let drain = backgroundTask
        let observation = queueObservationTask
        await drain?.value
        await observation?.value
        backgroundTask = nil
        queueObservationTask = nil
        backgroundWakeRequested = false
    }

    // MARK: - Foreground

    /// Applies whatever the index owes before a search runs, within a bounded budget.
    ///
    /// Never throws: a search proceeds against a slightly stale index rather than failing.
    func drainBeforeSearch() async {
        guard !isCancelled else { return }
        // A deep queue deliberately does not drain on this foreground path. Still wake the utility
        // loop so it keeps making progress after the query returns.
        requestBackgroundDrain()
        do {
            try await indexer.drainIfShallow(maxDepth: Self.foregroundDrainBudget)
        } catch {
            // Already handled inside the indexer, which routes corruption to repair. Nothing here
            // can improve the situation, and the user is waiting.
        }
    }

    func coverage() async throws -> SearchIndexer.Coverage {
        try await indexer.coverage()
    }

#if DEBUG
    /// Synchronization point for lifecycle tests that need the initial empty drain to have fully
    /// retired before enqueueing new work. Production code never waits for background indexing.
    func waitForBackgroundTaskToRetireForTesting() async {
        await backgroundTask?.value
    }
#endif

    // MARK: - Background

    private func startQueueObservation() {
        guard queueObservationTask == nil else { return }
        let values = ValueObservation
            .tracking { db in
                try Int.fetchOne(db, sql: "SELECT count(*) FROM search_index_queue") ?? 0
            }
            .removeDuplicates()
            .values(
                in: store.dbQueue,
                scheduling: .async(onQueue: .global(qos: .utility)),
                bufferingPolicy: .bufferingNewest(1)
            )
        let box = SearchQueueObservationBox(values)
        queueObservationTask = Task.detached(priority: .utility) { [weak self] in
            do {
                for try await depth in box.values {
                    guard !Task.isCancelled else { return }
                    if depth > 0 { await self?.queueDidBecomeNonEmpty() }
                }
            } catch is CancellationError {
                return
            } catch {
                // A later foreground search still calls `requestBackgroundDrain`. Observation is a
                // wake-up accelerator, never a dependency of querying or replica correctness.
            }
        }
    }

    private func queueDidBecomeNonEmpty() {
        requestBackgroundDrain()
    }

    /// Records the wake even when a loop is still winding down. Because both the idle decision and
    /// this method are actor-isolated, a row cannot land in the gap between "queue empty" and task
    /// retirement without either the old loop seeing this flag or this method starting a new one.
    private func requestBackgroundDrain() {
        guard !isCancelled else { return }
        backgroundWakeRequested = true
        guard backgroundTask == nil else { return }
        backgroundTask = Task.detached(priority: .utility) { [weak self] in
            await self?.runBackgroundLoop()
        }
    }

    /// Drains the live queue to empty, then advances the backfill, yielding between units.
    ///
    /// Queue before backfill throughout: a message that just arrived should be findable before
    /// history nobody is currently searching.
    private func runBackgroundLoop() async {
        let interval = signposter.beginInterval("SearchBackgroundLoop")
        defer { signposter.endInterval("SearchBackgroundLoop", interval) }

        while !isCancelled, !Task.isCancelled {
            backgroundWakeRequested = false
            var didWork = false

            do {
                let outcome = try await indexer.drain()
                didWork = outcome.indexed + outcome.removed > 0
                if outcome.hasMore {
                    try? await Task.sleep(nanoseconds: Self.backgroundIdleNanoseconds)
                    continue
                }
            } catch {
                // Corruption is already routed to repair by the indexer; back off so a permanently
                // failing drain does not spin.
                try? await Task.sleep(nanoseconds: Self.backgroundIdleNanoseconds * 10)
                continue
            }

            do {
                if try await indexer.backfillStep() { didWork = true }
            } catch {
                try? await Task.sleep(nanoseconds: Self.backgroundIdleNanoseconds * 10)
                continue
            }

            if !didWork {
                if backgroundWakeRequested { continue }
                // Retire the task while still isolated to the actor. A queued observation after
                // this assignment sees nil and starts the same coordinator again.
                backgroundTask = nil
                return
            }
            try? await Task.sleep(nanoseconds: Self.backgroundIdleNanoseconds)
        }
        backgroundTask = nil
    }

    /// Audit plus tombstone merge, for a background task to call on a long cadence.
    ///
    /// Separate from the drain loop because both are expensive and neither belongs on the path a
    /// user is waiting on.
    func runMaintenance() async {
        guard !isCancelled else { return }
        do {
            _ = try await indexer.audit()
            guard !isCancelled else { return }
            try await indexer.runMaintenance()
            // The audit enqueues what it repaired, so drain it rather than leaving the work to
            // whenever the next message happens to arrive.
            _ = try? await indexer.drain()
        } catch {
            // Maintenance is opportunistic by definition.
        }
    }

    /// Runs the same bounded maintenance only when its persisted daily cadence is due.
    /// `audit()` caps each drift class and `runMaintenance()` performs one bounded FTS merge plus
    /// one queue batch, so a BGTask expiration never strands an unbounded transaction.
    func runScheduledMaintenance() async {
        guard !isCancelled else { return }
        do {
            guard try await indexer.maintenanceIsDue() else { return }
        } catch {
            return
        }
        await runMaintenance()
        requestBackgroundDrain()
    }

    /// Drives the index to completion. Test-facing: production never blocks on this.
    func waitUntilIdle(maximumIterations: Int = 5_000) async throws {
        for _ in 0..<maximumIterations {
            let outcome = try await indexer.drain()
            let more = try await indexer.backfillStep()
            if !more, !outcome.hasMore, outcome.indexed == 0, outcome.removed == 0 { return }
        }
    }
}
