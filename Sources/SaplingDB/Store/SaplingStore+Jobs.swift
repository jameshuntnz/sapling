import Foundation
import GRDB
import SaplingCore

extension SaplingStore {
    /// Inserts a job, or updates it if the id already exists.
    public func saveJob(_ job: Job) async throws {
        try await writer.write { db in
            try JobRecord(job).save(db)
        }
    }

    /// Insert only if this job id isn't already known.
    ///
    /// Returns true when the job was new — the poller relies on this to avoid re-
    /// claiming a job it has already seen in an earlier poll cycle.
    @discardableResult
    public func insertJobIfNew(_ job: Job) async throws -> Bool {
        try await writer.write { db in
            if try JobRecord.exists(db, key: job.id) { return false }
            try JobRecord(job).insert(db)
            return true
        }
    }

    /// Fetches one job, or `nil` if it isn't known.
    public func job(id: String) async throws -> Job? {
        try await writer.read { db in
            try JobRecord.fetchOne(db, key: id)?.model
        }
    }

    /// Lists jobs, most recently updated first.
    ///
    /// - Parameters:
    ///   - status: Only jobs in this state, or all jobs when `nil`.
    ///   - limit: Maximum rows to return.
    /// - Returns: Matching jobs, most recently updated first.
    /// - Throws: If the database cannot be read.
    public func jobs(status: JobStatus? = nil, limit: Int = 50) async throws -> [Job] {
        try await writer.read { db in
            var request = JobRecord.order(Column("updated_at").desc).limit(limit)
            if let status {
                request =
                    JobRecord
                    .filter(Column("status") == status.rawValue)
                    .order(Column("updated_at").desc)
                    .limit(limit)
            }
            return try request.fetchAll(db).map(\.model)
        }
    }

    /// Jobs currently holding a slot.
    public func activeJobs() async throws -> [Job] {
        let active = JobStatus.allCases.filter(\.occupiesSlot).map(\.rawValue)
        return try await writer.read { db in
            try JobRecord
                .filter(active.contains(Column("status")))
                .order(Column("updated_at").desc)
                .fetchAll(db)
                .map(\.model)
        }
    }

    /// Moves a job to a new state, leaving unspecified fields untouched.
    public func updateJobStatus(
        id: String,
        status: JobStatus,
        exitReason: String? = nil,
        startedAt: Date? = nil,
        completedAt: Date? = nil
    ) async throws {
        try await writer.write { db in
            guard var record = try JobRecord.fetchOne(db, key: id) else { return }
            record.status = status.rawValue
            if let exitReason { record.exitReason = exitReason }
            if let startedAt { record.startedAt = startedAt }
            if let completedAt { record.completedAt = completedAt }
            record.updatedAt = Date()
            try record.update(db)
        }
    }

    /// Records which image a job actually ran in.
    ///
    /// Kept separate from `updateJobStatus` because it is answered once, at
    /// dispatch, and never revised — a job that ran in an image did so in that
    /// image, whatever the config says later.
    /// Records the memory a job was admitted against, in GB.
    ///
    /// Records the memory a job was admitted against, in GB.
    ///
    /// Written when the slot is claimed, so a restart can total what running
    /// jobs hold rather than guess it.
    public func setJobMemoryGB(id: String, memoryGB: Int) async throws {
        try await writer.write { db in
            guard var record = try JobRecord.fetchOne(db, key: id) else { return }
            record.memoryGB = memoryGB
            try record.update(db)
        }
    }

    /// Records the most memory a job's environment ever held, in bytes.
    public func setJobPeakMemory(id: String, bytes: Int64) async throws {
        try await writer.write { db in
            guard var record = try JobRecord.fetchOne(db, key: id) else { return }
            record.peakMemoryBytes = bytes
            try record.update(db)
        }
    }

    /// Peak memory from recent completed runs of the same job, in bytes.
    ///
    /// Keyed on repository and job name, which is what a `mem:` label is
    /// attached to — the same workflow job across runs, rather than the same
    /// run id, which never repeats.
    ///
    /// - Parameters:
    ///   - repo: Repository in `owner/repo` form.
    ///   - name: The job's name from the workflow file.
    ///   - limit: How many recent runs to consider.
    /// - Returns: Peaks, most recent first.
    /// - Throws: If the database cannot be read.
    public func recentPeakMemory(repo: String, name: String, limit: Int = 10) async throws
        -> [Int64]
    {
        try await writer.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT peak_memory_bytes FROM jobs
                    WHERE repo = ? AND name = ? AND peak_memory_bytes IS NOT NULL
                    ORDER BY updated_at DESC LIMIT ?
                    """,
                arguments: [repo, name, limit]
            ).compactMap { $0["peak_memory_bytes"] as Int64? }
        }
    }

    /// Records the image a job actually ran in.
    public func setJobImageRef(id: String, imageRef: String) async throws {
        try await writer.write { db in
            guard var record = try JobRecord.fetchOne(db, key: id) else { return }
            record.imageRef = imageRef
            record.updatedAt = Date()
            try record.update(db)
        }
    }

    /// Image refs used by jobs updated since a cutoff.
    ///
    /// Drives image retention: anything not in this set is a build nothing has
    /// needed lately.
    public func recentJobImageRefs(since cutoff: Date) async throws -> [String] {
        try await writer.read { db in
            try JobRecord
                .filter(Column("updated_at") >= cutoff)
                .fetchAll(db)
                .compactMap(\.imageRef)
        }
    }

    /// Memory reserved by every job currently holding a slot, in GB.
    ///
    /// The scheduler's real budget line.
    ///
    /// Summed from the database rather than tracked in memory so it survives a
    /// daemon restart: jobs outlive the process that started them, and
    /// admitting work against memory a survivor is still holding is how a node
    /// over-commits itself after a crash.
    ///
    /// - Parameter fallbackGB: Charged for jobs recorded before sizes existed.
    /// - Returns: Total GB reserved across both platforms.
    /// - Throws: If the database cannot be read.
    public func committedMemoryGB(fallbackGB: Int) async throws -> Int {
        let active = JobStatus.allCases.filter(\.occupiesSlot).map(\.rawValue)
        return try await writer.read { db in
            let placeholders = active.map { _ in "?" }.joined(separator: ",")
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT memory_gb FROM jobs WHERE status IN (\(placeholders))",
                arguments: StatementArguments(active)
            )
            return rows.reduce(0) { total, row in
                total + ((row["memory_gb"] as Int?) ?? fallbackGB)
            }
        }
    }

    /// Count of slot-holding jobs per platform, the number the scheduler
    /// checks before claiming anything new.
    public func slotsInUse() async throws -> [JobPlatform: Int] {
        let active = JobStatus.allCases.filter(\.occupiesSlot).map(\.rawValue)
        return try await writer.read { db in
            let placeholders = active.map { _ in "?" }.joined(separator: ",")
            let rows = try Row.fetchAll(
                db,
                sql:
                    "SELECT platform, COUNT(*) AS n FROM jobs WHERE status IN (\(placeholders)) GROUP BY platform",
                arguments: StatementArguments(active)
            )
            var out: [JobPlatform: Int] = [:]
            for row in rows {
                guard let platform = JobPlatform(rawValue: row["platform"]) else { continue }
                out[platform] = row["n"]
            }
            return out
        }
    }

    /// Counts jobs in a state, optionally only those updated since a time.
    public func countJobs(status: JobStatus, since: Date? = nil) async throws -> Int {
        try await writer.read { db in
            if let since {
                return try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM jobs WHERE status = ? AND updated_at >= ?",
                    arguments: [status.rawValue, since]
                ) ?? 0
            }
            return try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM jobs WHERE status = ?",
                arguments: [status.rawValue]
            ) ?? 0
        }
    }

    /// After an unclean shutdown, jobs are left mid-flight in the database while
    /// their VMs and containers are gone.
    ///
    /// Nothing will ever finish them, so fail them explicitly at startup rather
    /// than letting them hold slots forever.
    @discardableResult
    public func reconcileOrphanedJobs(reason: String) async throws -> [Job] {
        let active = JobStatus.allCases.filter(\.occupiesSlot).map(\.rawValue)
        return try await writer.write { db in
            let placeholders = active.map { _ in "?" }.joined(separator: ",")
            let stranded = try JobRecord.fetchAll(
                db,
                sql: "SELECT * FROM jobs WHERE status IN (\(placeholders))",
                arguments: StatementArguments(active)
            )
            let now = Date()
            for var record in stranded {
                record.status = JobStatus.failed.rawValue
                record.exitReason = reason
                record.completedAt = now
                record.updatedAt = now
                try record.update(db)
                try db.execute(
                    sql: "INSERT INTO runs (job_id, ts, event, detail) VALUES (?, ?, ?, ?)",
                    arguments: [record.id, now, RunEventName.jobFailed, reason]
                )
            }
            return stranded.map(\.model)
        }
    }

    /// Keep the database from growing without bound on a 256GB box.
    @discardableResult
    public func pruneJobs(olderThan cutoff: Date) async throws -> Int {
        try await writer.write { db in
            try db.execute(
                sql: "DELETE FROM jobs WHERE status IN (?, ?, ?) AND updated_at < ?",
                arguments: [
                    JobStatus.completed.rawValue, JobStatus.failed.rawValue,
                    JobStatus.cancelled.rawValue, cutoff,
                ]
            )
            return db.changesCount
        }
    }
}
