import GRDB
import XCTest
@testable import Toj

/// The lifecycle layer: generation scoping, bounded foreground draining, background progress,
/// maintenance, cancellation, and the audit converging against a real revocation.
final class SearchCoordinatorTests: XCTestCase {
    private var directory: URL!
    private var store: CloudLocalStore!
    private var coordinator: SearchCoordinator!

    override func setUp() async throws {
        try await super.setUp()
        directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = try makeStore()
        coordinator = SearchCoordinator(store: store, accountId: "acct-1")
    }

    override func tearDown() async throws {
        await coordinator?.cancelAndWait()
        coordinator = nil
        store = nil
        if let directory { try? FileManager.default.removeItem(at: directory) }
        try await super.tearDown()
    }

    private func makeStore() throws -> CloudLocalStore {
        try CloudLocalStore(
            path: directory.appending(path: "cloud.sqlite").path,
            key: Data(repeating: 0x11, count: 32)
        )
    }

    // MARK: - Generation scoping

    /// The store identity is part of the generation, not just the account. Recovering a quarantined
    /// replica produces a new store for the *same* account, and work queued against the old one
    /// must not resume against the new.
    func testGenerationDistinguishesAccountAndStore() async throws {
        XCTAssertTrue(coordinator.serves(accountId: "acct-1", store: store))
        XCTAssertFalse(coordinator.serves(accountId: "acct-2", store: store))

        let replacement = try makeStore()
        XCTAssertFalse(
            coordinator.serves(accountId: "acct-1", store: replacement),
            "a new store for the same account is a different generation"
        )
    }

    /// `cancelAndWait` exists so a caller can prove the previous generation is finished before the
    /// next starts. `cancel()` alone cannot promise that.
    func testCancelAndWaitLeavesNoWorkInFlight() async throws {
        for index in 1...50 {
            try await insert(Int64(index), "message \(index)")
        }
        await coordinator.start()
        await coordinator.cancelAndWait()

        // Nothing may advance after this point.
        let first = try await store.dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT count(*) FROM message_search_docs") ?? 0
        }
        try await Task.sleep(nanoseconds: 200_000_000)
        let second = try await store.dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT count(*) FROM message_search_docs") ?? 0
        }
        XCTAssertEqual(first, second, "a cancelled coordinator must be quiescent")
    }

    func testStartIsIdempotent() async throws {
        try await insert(1, "hello")
        await coordinator.start()
        await coordinator.start()
        await coordinator.start()
        try await coordinator.waitUntilIdle()
        let hits = try await store.searchMessages(MessageSearchRequest(query: "hello")).hits
        XCTAssertEqual(hits.count, 1, "repeated starts must not duplicate work")
    }

    // MARK: - Draining

    func testBackgroundLoopIndexesEverythingWithoutBeingDriven() async throws {
        for index in 1...30 {
            try await insert(Int64(index), "backlog \(index)")
        }
        await coordinator.start()

        try await eventually("all messages indexed") {
            let coverage = try await self.coordinator.coverage()
            return coverage.indexed == 30 && coverage.queueDepth == 0
        }
    }

    /// Regression for the completed-task tombstone: the original loop returned while leaving its
    /// non-nil `Task` in the coordinator, so every later restart request was mistaken for an
    /// already-running drain. This begins empty, lets that loop retire, then exceeds the foreground
    /// budget and relies only on the queue observation to wake the same coordinator.
    func testIdleCoordinatorWakesAndDrainsDeepQueueWithoutRecreation() async throws {
        await coordinator.start()
        try await eventually("initial empty index settles") {
            try await self.coordinator.coverage().isComplete
        }
        await coordinator.waitForBackgroundTaskToRetireForTesting()

        let total = SearchCoordinator.foregroundDrainBudget + 37
        try await insertRange(1...total, textPrefix: "wake")

        try await eventually("post-idle deep queue drains", timeout: 30) {
            let coverage = try await self.coordinator.coverage()
            return coverage.indexed == total && coverage.queueDepth == 0
        }
        let hits = try await store.searchMessages(MessageSearchRequest(query: "wake")).hits
        XCTAssertEqual(hits.count, 40, "the default result page is full after the automatic drain")
        XCTAssertTrue(coordinator.serves(accountId: "acct-1", store: store))
    }

    /// The foreground drain runs on a keystroke, so it is capped rather than exhaustive.
    func testForegroundDrainMakesAJustSentMessageFindable() async throws {
        await coordinator.start()
        try await coordinator.waitUntilIdle()

        try await insert(99, "justsent")
        await coordinator.drainBeforeSearch()

        let hits = try await store.searchMessages(MessageSearchRequest(query: "justsent")).hits
        XCTAssertEqual(hits.count, 1, "a message sent moments ago must be findable")
    }

    func testForegroundDrainIsBoundedAndDoesNotBlockOnADeepBacklog() async throws {
        await coordinator.start()
        await coordinator.cancelAndWait()   // stop the background loop so the backlog stays deep

        for index in 1...(SearchCoordinator.foregroundDrainBudget * 3) {
            try await insert(Int64(index), "deep \(index)")
        }

        let started = Date()
        await coordinator.drainBeforeSearch()
        XCTAssertLessThan(
            Date().timeIntervalSince(started), 1.0,
            "the foreground path must give up rather than drain an unbounded backlog"
        )
    }

    // MARK: - Offline relaunch

    /// The whole point of a local index: a relaunch with no network still searches, and does not
    /// redo work it already did.
    func testIndexSurvivesRelaunchAndDoesNotReindexFromScratch() async throws {
        for index in 1...20 {
            try await insert(Int64(index), "durable \(index)")
        }
        await coordinator.start()
        try await coordinator.waitUntilIdle()
        let indexedBefore = try await coordinator.coverage().indexed
        XCTAssertEqual(indexedBefore, 20)

        await coordinator.cancelAndWait()
        store = nil

        // Reopen the same file, exactly as a relaunch would.
        store = try makeStore()
        coordinator = SearchCoordinator(store: store, accountId: "acct-1")
        await coordinator.start()

        let coverage = try await coordinator.coverage()
        XCTAssertEqual(coverage.status, .ready)
        XCTAssertEqual(coverage.indexed, 20, "the index persisted; nothing was rebuilt")
        XCTAssertEqual(coverage.queueDepth, 0, "a relaunch must not re-enqueue what is already done")

        let hits = try await store.searchMessages(MessageSearchRequest(query: "durable")).hits
        XCTAssertEqual(hits.count, 20, "search works offline immediately after relaunch")
    }

    // MARK: - Maintenance and audit

    /// The exact convergence case: revoke through the production path, then audit. Revoked dialogs
    /// are supposed to have no docs, so an audit that counts them as missing re-enqueues precisely
    /// what revocation removed and never settles.
    func testAuditConvergesAfterRealRevocation() async throws {
        for index in 1...5 {
            try await insert(Int64(index), "groupcontent \(index)", dialogId: "d1")
        }
        try await insert(100, "other dialog", dialogId: "d2")
        await coordinator.start()
        try await coordinator.waitUntilIdle()

        let firstAudit = try await SearchIndexer(store: store).audit()
        XCTAssertTrue(firstAudit.isClean, "a freshly built index is clean: \(firstAudit)")

        try await store.revokeGroupAccess(dialogId: "d1", reason: "removed by owner")
        try await coordinator.waitUntilIdle()

        // Repeated audits must settle rather than oscillate.
        let indexer = SearchIndexer(store: store)
        for round in 1...3 {
            let report = try await indexer.audit()
            _ = try await indexer.drain()
            XCTAssertTrue(
                report.isClean,
                "audit round \(round) did not converge after revocation: \(report)"
            )
        }

        let revoked = try await store.searchMessages(MessageSearchRequest(query: "groupcontent")).hits
        XCTAssertTrue(revoked.isEmpty, "revoked content stays gone across audits")
        let survivor = try await store.searchMessages(MessageSearchRequest(query: "other")).hits
        XCTAssertEqual(survivor.count, 1, "the other dialog is untouched")
    }

    func testRegrantRestoresSearchabilityThroughTheCoordinator() async throws {
        try await insert(1, "regrantable", dialogId: "d1")
        await coordinator.start()
        try await coordinator.waitUntilIdle()

        try await store.revokeGroupAccess(dialogId: "d1", reason: "removed")
        try await coordinator.waitUntilIdle()
        let gone = try await store.searchMessages(MessageSearchRequest(query: "regrantable")).hits
        XCTAssertTrue(gone.isEmpty)

        try await store.dbQueue.write { db in
            try db.execute(sql: "UPDATE dialogs SET access_state = 'active' WHERE dialog_id = 'd1'")
        }
        try await coordinator.waitUntilIdle()

        let restored = try await store.searchMessages(MessageSearchRequest(query: "regrantable")).hits
        XCTAssertEqual(restored.count, 1, "a re-added member sees their history again")
    }

    func testMaintenanceRunsAuditAndLeavesTheIndexUsable() async throws {
        for index in 1...10 { try await insert(Int64(index), "maintained \(index)") }
        await coordinator.start()
        try await coordinator.waitUntilIdle()

        await coordinator.runMaintenance()

        let coverage = try await coordinator.coverage()
        XCTAssertEqual(coverage.status, .ready)
        let hits = try await store.searchMessages(MessageSearchRequest(query: "maintained")).hits
        XCTAssertEqual(hits.count, 10)
    }

    /// Coverage counts only indexable messages. Including revoked dialogs would leave the banner
    /// permanently short of complete.
    func testCoverageReachesCompleteWithARevokedDialogPresent() async throws {
        try await insert(1, "visible", dialogId: "d1")
        try await insert(2, "hidden", dialogId: "d2")
        await coordinator.start()
        try await coordinator.waitUntilIdle()

        try await store.revokeGroupAccess(dialogId: "d2", reason: "removed")
        try await coordinator.waitUntilIdle()

        let coverage = try await coordinator.coverage()
        XCTAssertEqual(coverage.total, 1, "revoked messages are not indexable and must not be counted")
        XCTAssertEqual(coverage.indexed, 1)
        XCTAssertTrue(coverage.isComplete, "coverage must be able to reach complete: \(coverage)")
    }

    // MARK: - Repair

    /// `rebuilding` is transient. A crash mid-repair leaves it set with nothing to advance it, and
    /// a bootstrap that honoured it would disable search forever.
    func testInterruptedRepairDoesNotLeaveTheIndexStuckInRebuilding() async throws {
        try await insert(1, "recovered")
        await coordinator.start()
        try await coordinator.waitUntilIdle()

        try await store.dbQueue.write { db in
            try db.execute(sql: """
                UPDATE search_index_state SET status = 'rebuilding' WHERE id = 1
                """)
        }

        let restarted = SearchCoordinator(store: store, accountId: "acct-1")
        await restarted.start()
        defer { Task { await restarted.cancelAndWait() } }

        let coverage = try await restarted.coverage()
        XCTAssertEqual(coverage.status, .ready, "a stranded rebuild must be rescued, not honoured")

        try await restarted.waitUntilIdle()
        let hits = try await store.searchMessages(MessageSearchRequest(query: "recovered")).hits
        XCTAssertEqual(hits.count, 1)
    }

    // MARK: - Helpers

    /// Polls rather than sleeping a fixed interval, so the test is deterministic in outcome without
    /// being tied to a machine's speed.
    private func eventually(
        _ what: String, timeout: TimeInterval = 10,
        _ condition: () async throws -> Bool,
        file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if try await condition() { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("timed out waiting for \(what)", file: file, line: line)
    }

    private func insert(
        _ msgId: Int64, _ text: String, dialogId: String = "d1"
    ) async throws {
        try await store.dbQueue.write { db in
            try db.execute(sql: """
                INSERT OR IGNORE INTO dialogs(dialog_id, type, title, last_msg_id, updated_at)
                VALUES (?, 'group', 'Test', 0, datetime('now'))
                """, arguments: [dialogId])
            try db.execute(sql: """
                INSERT INTO messages(local_id, dialog_id, msg_id, client_msg_id, sender_account_id,
                                     kind, text, is_forwarded, edit_version, state, server_ts,
                                     local_state)
                VALUES (?, ?, ?, ?, 'a1', 'text', ?, 0, 0, 'visible', '2026-07-12T09:00:00Z', 'sent')
                """, arguments: ["\(dialogId):\(msgId)", dialogId, msgId,
                                 "\(dialogId)-c\(msgId)", text])
        }
    }

    /// Commits the whole backlog atomically so the observation sees one deterministic empty-to-deep
    /// transition instead of racing hundreds of encrypted fixture writes.
    private func insertRange(
        _ range: ClosedRange<Int>, textPrefix: String, dialogId: String = "d1"
    ) async throws {
        try await store.dbQueue.write { db in
            try db.execute(sql: """
                INSERT OR IGNORE INTO dialogs(dialog_id, type, title, last_msg_id, updated_at)
                VALUES (?, 'group', 'Test', 0, datetime('now'))
                """, arguments: [dialogId])
            for index in range {
                let msgId = Int64(index)
                try db.execute(sql: """
                    INSERT INTO messages(local_id, dialog_id, msg_id, client_msg_id,
                                         sender_account_id, kind, text, is_forwarded, edit_version,
                                         state, server_ts, local_state)
                    VALUES (?, ?, ?, ?, 'a1', 'text', ?, 0, 0, 'visible',
                            '2026-07-12T09:00:00Z', 'sent')
                    """, arguments: ["\(dialogId):\(msgId)", dialogId, msgId,
                                     "\(dialogId)-c\(msgId)", "\(textPrefix) \(index)"])
            }
        }
    }
}
