import Foundation
import GRDB
import os
import Security

extension CloudLocalStore {
    func loadPresenceCache(observerAccountId: String) throws -> [LocalPresenceSnapshot] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT observer_account_id, subject_account_id, last_seen_at, revision
                FROM peer_presence_cache
                WHERE observer_account_id = ?
                ORDER BY subject_account_id
                """,
                arguments: [observerAccountId]
            )
            return rows.map { row in
                LocalPresenceSnapshot(
                    observerAccountId: row["observer_account_id"],
                    subjectAccountId: row["subject_account_id"],
                    lastSeenAt: row["last_seen_at"],
                    revision: row["revision"]
                )
            }
        }
    }

    func savePresenceSnapshot(_ snapshot: LocalPresenceSnapshot) throws {
        try savePresenceSnapshots([snapshot])
    }

    func savePresenceSnapshots(_ snapshots: [LocalPresenceSnapshot]) throws {
        guard !snapshots.isEmpty else { return }
        try dbQueue.write { db in
            for snapshot in snapshots {
                try db.execute(
                    sql: """
                    INSERT INTO peer_presence_cache (
                      observer_account_id, subject_account_id, last_seen_at, revision, updated_at
                    ) VALUES (?, ?, ?, ?, datetime('now'))
                    ON CONFLICT(observer_account_id, subject_account_id) DO UPDATE SET
                      last_seen_at = excluded.last_seen_at,
                      revision = excluded.revision,
                      updated_at = excluded.updated_at
                    WHERE excluded.revision > peer_presence_cache.revision
                       OR (excluded.revision = peer_presence_cache.revision
                           AND excluded.last_seen_at IS NOT peer_presence_cache.last_seen_at)
                    """,
                    arguments: [
                        snapshot.observerAccountId,
                        snapshot.subjectAccountId,
                        snapshot.lastSeenAt,
                        snapshot.revision,
                    ]
                )
            }
        }
    }

    func removePresenceCache(observerAccountId: String, subjectAccountIds: [String]) throws {
        guard !subjectAccountIds.isEmpty else { return }
        try dbQueue.write { db in
            let placeholders = Array(repeating: "?", count: subjectAccountIds.count).joined(separator: ",")
            try db.execute(
                sql: """
                DELETE FROM peer_presence_cache
                WHERE observer_account_id = ?
                  AND subject_account_id IN (\(placeholders))
                """,
                arguments: StatementArguments([observerAccountId] + subjectAccountIds)
            )
        }
    }
}
