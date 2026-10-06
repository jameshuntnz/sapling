import Foundation
import GRDB
import SaplingCore

extension SaplingStore {
    /// Appends one entry to a job's event log.
    public func appendEvent(_ event: RunEvent) async throws {
        try await writer.write { db in
            var record = RunEventRecord(event)
            try record.insert(db)
        }
    }

    /// Appends an event to a job's log, building the record for you.
    public func appendEvent(jobID: String, event: String, detail: String? = nil) async throws {
        try await appendEvent(RunEvent(jobID: jobID, event: event, detail: detail))
    }

    /// Reads a job's event log, oldest first.
    ///
    /// - Parameters:
    ///   - jobID: The job whose log to read.
    ///   - afterID: Return only events newer than this row id, so a tailing
    ///     client fetches just what's new.
    ///   - limit: Maximum rows to return.
    /// - Returns: The job's events, oldest first.
    /// - Throws: If the database cannot be read.
    public func events(jobID: String, afterID: Int64? = nil, limit: Int = 1000) async throws -> [RunEvent] {
        try await writer.read { db in
            if let afterID {
                return
                    try RunEventRecord
                    .filter(Column("job_id") == jobID && Column("id") > afterID)
                    .order(Column("id"))
                    .limit(limit)
                    .fetchAll(db)
                    .map(\.model)
            }
            return
                try RunEventRecord
                .filter(Column("job_id") == jobID)
                .order(Column("id"))
                .limit(limit)
                .fetchAll(db)
                .map(\.model)
        }
    }

    /// The newest events of a job's log, oldest first.
    ///
    /// What a viewer wants first. Reading from the start stopped at the limit,
    /// so a chatty runner — one dumps its whole job message as ~3,000 lines —
    /// hid everything that happened after its first minute, including the
    /// outcome.
    ///
    /// - Parameters:
    ///   - jobID: The job whose log to read.
    ///   - beforeID: Return only events older than this row id, to page back.
    ///   - limit: Maximum rows to return.
    /// - Returns: Up to `limit` events, oldest first, and whether any older
    ///   ones remain.
    /// - Throws: If the database cannot be read.
    public func latestEvents(
        jobID: String, beforeID: Int64? = nil, limit: Int = 1000
    ) async throws -> (events: [RunEvent], hasEarlier: Bool) {
        try await writer.read { db in
            var request = RunEventRecord.filter(Column("job_id") == jobID)
            if let beforeID { request = request.filter(Column("id") < beforeID) }
            let newestFirst = try request.order(Column("id").desc).limit(limit).fetchAll(db)
            guard let oldest = newestFirst.last?.id else { return ([], false) }
            let hasEarlier =
                try RunEventRecord
                .filter(Column("job_id") == jobID && Column("id") < oldest)
                .fetchCount(db) > 0
            return (newestFirst.reversed().map(\.model), hasEarlier)
        }
    }

    /// Deletes the event logs of jobs that finished before a cutoff, then
    /// gives the space back to the filesystem.
    ///
    /// The job rows stay — outcomes and history are cheap — only the logs
    /// go, which are almost all of the database: one chatty runner writes
    /// thousands of lines per job, and nothing else ever removed them.
    ///
    /// - Parameter cutoff: Jobs completed before this lose their logs.
    /// - Returns: How many events were deleted.
    /// - Throws: If the database cannot be written.
    @discardableResult
    public func trimEvents(completedBefore cutoff: Date) async throws -> Int {
        let deleted = try await writer.write { db in
            try db.execute(
                sql: """
                    DELETE FROM runs WHERE job_id IN (
                        SELECT id FROM jobs WHERE completed_at IS NOT NULL AND completed_at < ?
                    )
                    """,
                arguments: [cutoff])
            return db.changesCount
        }
        // Outside any transaction, which SQLite requires of VACUUM. Without it
        // the deleted pages stay in the file and the disk sees nothing back.
        try await writer.writeWithoutTransaction { db in try db.execute(sql: "VACUUM") }
        return deleted
    }
}
