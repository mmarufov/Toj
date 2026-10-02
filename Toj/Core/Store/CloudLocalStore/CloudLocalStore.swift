import Foundation
import GRDB
import os
import Security

actor CloudLocalStore {
    /// Internal rather than private so the search index code can live in its own files instead of
    /// growing this one. `private` in Swift is file-scoped, and nothing outside the module sees it.
    ///
    /// `nonisolated` because `DatabasePool` is `Sendable` and does its own serialization: hopping
    /// the actor to reach it would buy nothing and force every caller into `await` for a property
    /// read. The pool's own read/write closures remain the synchronization point.
    nonisolated let dbQueue: DatabasePool
    nonisolated private static let signposter = OSSignposter(
        subsystem: "com.toj.Toj",
        category: "LocalStore"
    )

    nonisolated static func `default`() throws -> CloudLocalStore {
        let key = try LocalDatabaseKeyStore.currentEnvironment().loadOrCreateKey()
        let appDirectory = try defaultApplicationDirectory()
        let path = appDirectory.appending(path: "cloud.sqlite").path

        try applyFileSecurity(to: appDirectory)
        return try CloudLocalStore(path: path, key: key)
    }

    /// Permanently destroys the default encrypted replica, its recovery copies, and its key.
    /// Callers must release every open `CloudLocalStore` before invoking this method.
    nonisolated static func destroyDefaultStore() throws {
        let fileManager = FileManager.default
        let appDirectory = try defaultApplicationDirectory()
        let databasePath = appDirectory.appending(path: "cloud.sqlite").path
        var firstError: Error?

        for suffix in ["", "-wal", "-shm"] {
            let url = URL(fileURLWithPath: databasePath + suffix)
            guard fileManager.fileExists(atPath: url.path) else { continue }
            do {
                try fileManager.removeItem(at: url)
            } catch {
                if firstError == nil { firstError = error }
            }
        }

        let quarantine = appDirectory.appending(path: "Quarantine", directoryHint: .isDirectory)
        if fileManager.fileExists(atPath: quarantine.path) {
            do {
                try fileManager.removeItem(at: quarantine)
            } catch {
                if firstError == nil { firstError = error }
            }
        }

        // Delete the key even if a filesystem cleanup failed: any leftover encrypted bytes must
        // become permanently unreadable after an explicit logout.
        do {
            try LocalDatabaseKeyStore.currentEnvironment().deleteKey()
        } catch {
            if firstError == nil { firstError = error }
        }
        if let firstError { throw firstError }
    }

    /// Preserves an unreadable default replica for diagnostics/recovery. The caller must first
    /// authenticate the cloud session and must not hold an open store. Opening never invokes this
    /// API automatically.
    @discardableResult
    nonisolated static func quarantineDefaultStore(now: Date = Date()) throws -> URL? {
        let path = try defaultApplicationDirectory().appending(path: "cloud.sqlite").path
        return try quarantineStore(at: path, now: now)
    }

    /// Path-injectable variant used by recovery tooling and tests.
    @discardableResult
    nonisolated static func quarantineStore(at path: String, now: Date = Date()) throws -> URL? {
        let fileManager = FileManager.default
        let existingSuffixes = ["", "-wal", "-shm"].filter {
            fileManager.fileExists(atPath: path + $0)
        }
        guard !existingSuffixes.isEmpty else { return nil }

        let databaseURL = URL(fileURLWithPath: path)
        let quarantineRoot = databaseURL.deletingLastPathComponent()
            .appending(path: "Quarantine", directoryHint: .isDirectory)
        try fileManager.createDirectory(
            at: quarantineRoot,
            withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
        )
        try applyFileSecurity(to: quarantineRoot)

        let identifier = "\(quarantineTimestamp(now))-\(UUID().uuidString.lowercased())"
        let staging = quarantineRoot.appending(path: ".staging-\(identifier)", directoryHint: .isDirectory)
        let destination = quarantineRoot.appending(path: "cloud-\(identifier)", directoryHint: .isDirectory)
        try fileManager.createDirectory(
            at: staging,
            withIntermediateDirectories: false,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
        )

        var movedSuffixes: [String] = []
        do {
            for suffix in existingSuffixes {
                let source = URL(fileURLWithPath: path + suffix)
                let target = staging.appending(path: source.lastPathComponent)
                try fileManager.moveItem(at: source, to: target)
                movedSuffixes.append(suffix)
                try applyFileSecurity(to: target)
            }
            try applyFileSecurity(to: staging)
            try fileManager.moveItem(at: staging, to: destination)
            try applyFileSecurity(to: destination)
            return destination
        } catch {
            for suffix in movedSuffixes.reversed() {
                let fileName = URL(fileURLWithPath: path + suffix).lastPathComponent
                let quarantined = staging.appending(path: fileName)
                if fileManager.fileExists(atPath: quarantined.path) {
                    try? fileManager.moveItem(at: quarantined, to: URL(fileURLWithPath: path + suffix))
                }
            }
            try? fileManager.removeItem(at: staging)
            throw error
        }
    }

    init(path: String, key: Data) throws {
        var configuration = Configuration()
        configuration.prepareDatabase { db in
            try db.usePassphrase(key)
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }
        configuration.journalMode = .wal
        // A background runtime and a foreground scene can briefly overlap during process
        // restoration. Wait for the current WAL writer instead of surfacing SQLITE_BUSY and
        // abandoning an otherwise valid atomic job claim.
        configuration.busyMode = .timeout(5)
        let openInterval = Self.signposter.beginInterval("DatabaseOpen")
        let pool: DatabasePool
        do {
            pool = try DatabasePool(path: path, configuration: configuration)
            Self.signposter.endInterval("DatabaseOpen", openInterval)
        } catch {
            Self.signposter.endInterval("DatabaseOpen", openInterval)
            throw error
        }
        dbQueue = pool
        let migrationInterval = Self.signposter.beginInterval("DatabaseMigration")
        do {
            try Self.migrate(dbQueue)
            Self.signposter.endInterval("DatabaseMigration", migrationInterval)
        } catch {
            Self.signposter.endInterval("DatabaseMigration", migrationInterval)
            throw error
        }
        try Self.applyFileSecurity(toSQLiteFilesAt: path)
    }

    /// Runs the potentially expensive whole-store integrity scan after the cached launch snapshot
    /// has already been published. Opening SQLCipher and running migrations still validate the key
    /// and schema synchronously; this scan is deliberately not on the launch critical path.
    func verifyIntegrity() throws {
        let interval = Self.signposter.beginInterval("DatabaseIntegrity")
        defer { Self.signposter.endInterval("DatabaseIntegrity", interval) }
        if try runQuickCheck() { return }
        guard try recoverByDiscardingSearchIndex() else {
            throw LocalStoreOpenError.integrityCheckFailed
        }
    }

    private func runQuickCheck() throws -> Bool {
        try dbQueue.read { db in
            try String.fetchAll(db, sql: "PRAGMA quick_check(1)") == ["ok"]
        }
    }

    /// Drops the search index and re-checks, so damage confined to it does not condemn the replica.
    ///
    /// `quick_check` walks every b-tree in the file, and the FTS5 shadow tables are ordinary
    /// b-trees. Without this, a corrupt *derived* index fails integrity, the caller quarantines,
    /// and the user loses every chat they have — over data rebuildable from `messages` in the
    /// background. So the cheap, reversible thing is tried first: discard the index, ask again, and
    /// only condemn the replica if it still fails.
    ///
    /// Returns whether the replica is usable. Any failure here is reported as "not recovered"
    /// rather than thrown, because this path is already handling corruption and a second error
    /// changes nothing about what the caller must do.
    private func recoverByDiscardingSearchIndex() throws -> Bool {
        do {
            try dbQueue.write { db in
                // A deliberate discard, not a search failure: recorded as such so the indexer's
                // failure accounting is not poisoned by successful recoveries.
                try SearchIndexSchema.discardIndex(db, reason: "integrity recovery")
            }
        } catch {
            return false
        }
        return (try? runQuickCheck()) ?? false
    }

    func databaseJournalMode() throws -> String {
        try dbQueue.read { db in
            try String.fetchOne(db, sql: "PRAGMA journal_mode") ?? ""
        }
    }

    nonisolated static func sqliteTimestamp(_ date: Date) -> String {
        makeSQLiteDateFormatter().string(from: date)
    }

    nonisolated static func nextLocalMutationOrder(_ db: Database) throws -> Int64 {
        let order = try Int64.fetchOne(
            db,
            sql: "SELECT next_order FROM local_mutation_sequence WHERE singleton = 1"
        ) ?? 1
        try db.execute(
            sql: """
            INSERT INTO local_mutation_sequence (singleton, next_order)
            VALUES (1, ?)
            ON CONFLICT(singleton) DO UPDATE SET next_order = excluded.next_order
            """,
            arguments: [order + 1]
        )
        return order
    }

    nonisolated static func preferenceTimestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    nonisolated static func makeSQLiteDateFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }

    nonisolated private static func defaultApplicationDirectory() throws -> URL {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = support.appending(
            path: LocalDatabaseKeyStore.usesTelegramFastUITestFixture ? "TojUITest" : "Toj",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
        )
        return directory
    }

    nonisolated private static func quarantineTimestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }

    nonisolated private static func applyFileSecurity(to url: URL) throws {
        let fileManager = FileManager.default
        try fileManager.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: url.path
        )
        var protectedURL = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try protectedURL.setResourceValues(values)
    }

    nonisolated private static func applyFileSecurity(toSQLiteFilesAt path: String) throws {
        let fileManager = FileManager.default
        for suffix in ["", "-wal", "-shm"] {
            let candidate = path + suffix
            if fileManager.fileExists(atPath: candidate) {
                try applyFileSecurity(to: URL(fileURLWithPath: candidate))
            }
        }
    }

    func deleteReplicaData(_ db: Database, includeMediaTransfers: Bool) throws {
        try db.execute(sql: "DELETE FROM draft_attachments")
        try db.execute(sql: "DELETE FROM pending_draft_mutations")
        try db.execute(sql: "DELETE FROM pending_media_group_sends")
        try db.execute(sql: "DELETE FROM drafts")
        try db.execute(sql: "DELETE FROM message_reactions")
        try db.execute(sql: "DELETE FROM message_media")
        try db.execute(sql: "DELETE FROM messages")
        try db.execute(sql: "DELETE FROM pending_dialog_preference_mutations")
        try db.execute(sql: "DELETE FROM dialog_preferences")
        try db.execute(sql: "DELETE FROM dialog_members")
        try db.execute(sql: "DELETE FROM dialog_unread_summaries")
        try db.execute(sql: "DELETE FROM dialog_summaries")
        try db.execute(sql: "DELETE FROM profiles")
        try db.execute(sql: "DELETE FROM peer_presence_cache")
        try db.execute(sql: "DELETE FROM dialogs")
        try db.execute(sql: "DELETE FROM pending_outbox")
        try db.execute(sql: "DELETE FROM pending_read_receipts")
        try db.execute(sql: "DELETE FROM chat_viewport_state")
        try db.execute(sql: "DELETE FROM dialog_history_state")
        try db.execute(sql: "DELETE FROM message_mentions")
        try db.execute(sql: "DELETE FROM group_member_hydration")
        try db.execute(sql: "DELETE FROM pending_group_creations")
        try db.execute(sql: "DELETE FROM pending_group_mutations")
        try db.execute(sql: "DELETE FROM pending_purges")
        try db.execute(sql: "DELETE FROM pending_access_purges")
        try db.execute(sql: "DELETE FROM revoked_dialogs")
        try db.execute(sql: "DELETE FROM dialog_access_generations")
        try db.execute(sql: "DELETE FROM bootstrap_baseline_dialogs")
        try db.execute(sql: "DELETE FROM bootstrap_staged_messages")
        try db.execute(sql: "DELETE FROM bootstrap_staged_members")
        try db.execute(sql: "DELETE FROM bootstrap_staged_profiles")
        try db.execute(sql: "DELETE FROM bootstrap_staged_dialogs")
        try db.execute(sql: "DELETE FROM bootstrap_state")
        // Derived from `messages`, but it holds message text of its own: leaving it behind would
        // keep a signed-out account's words searchable.
        try SearchIndexSchema.discardIndex(db, reason: "replica wipe")
        if includeMediaTransfers {
            try db.execute(sql: "DELETE FROM pending_message_mutations")
            try db.execute(sql: "DELETE FROM media_transfers")
            try db.execute(sql: "DELETE FROM media_download_jobs")
            try db.execute(sql: "DELETE FROM media_cache_entries")
        }
    }
}
