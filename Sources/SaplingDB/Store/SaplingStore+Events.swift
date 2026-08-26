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
}
