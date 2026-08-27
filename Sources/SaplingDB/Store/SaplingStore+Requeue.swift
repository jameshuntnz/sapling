import Foundation
import GRDB
import SaplingCore

/// Deciding whether a job gets another go on this node, and counting them.
///
/// Split out from the rest of the job store because the attempt ceiling is
/// the whole reason any of it is more complicated than a status write.
extension SaplingStore {
    /// What happened when a job was offered another attempt.
    public enum RequeueOutcome: Sendable, Equatable {
        /// Back in the queue, and which attempt the next start will be.
        case requeued(attempt: Int)
        /// Out of attempts, reported the once so the caller can log it without
        /// repeating itself on every poll for the hours GitHub keeps offering
        /// the job.
        case exhausted(attempts: Int)
        /// Nothing to do: wrong state, still in cooldown, or already given up.
        case notEligible
    }

    /// Take ownership of a queued job and count the attempt.
    ///
    /// One write, so the next poll cycle cannot see the job as still queued,
    /// and so the attempt ceiling counts starts rather than inferring them.
    ///
    /// - Parameter id: The job to claim.
    /// - Returns: Which attempt this start is, counting from one.
    /// - Throws: If the database cannot be written.
    @discardableResult
    public func claimJob(id: String) async throws -> Int {
        try await writer.write { db in
            guard var record = try JobRecord.fetchOne(db, key: id) else { return 0 }
            record.attempts += 1
            record.status = JobStatus.provisioning.rawValue
            record.startedAt = Date()
            record.updatedAt = Date()
            try record.update(db)
            return record.attempts
        }
    }

    /// Put a job back in the queue after this node failed to run it.
    ///
    /// GitHub is the authority on whether a job still needs running. When it
    /// still reports one as queued but this node recorded a failure — a VM
    /// that wouldn't boot, an egress filter that couldn't be applied — the job
    /// would otherwise sit unclaimed until GitHub's own timeout, because
    /// discovery skips every id it has already seen.
    ///
    /// - Parameters:
    ///   - id: The job to requeue.
    ///   - cutoff: Only requeue if it finished before this instant. A
    ///     cooldown, so a job failing instantly can't spin.
    ///   - maxAttempts: How many times in total this node may start the job.
    /// - Returns: Whether the job was requeued, and if not, why not.
    /// - Throws: If the database cannot be written.
    @discardableResult
    public func requeueJob(
        id: String, failedBefore cutoff: Date, maxAttempts: Int
    ) async throws -> RequeueOutcome {
        try await writer.write { db in
            guard var record = try JobRecord.fetchOne(db, key: id) else { return .notEligible }
            // A cancellation is GitHub's decision, not a local failure, so it
            // is never worth another attempt.
            guard let status = JobStatus(rawValue: record.status), status.isRetryable else {
                return .notEligible
            }
            let finishedAt = record.completedAt ?? record.updatedAt
            guard finishedAt <= cutoff else { return .notEligible }
            return try Self.requeue(&record, in: db, maxAttempts: maxAttempts)
        }
    }

    /// Hand a job straight back to the queue without a cooldown.
    ///
    /// For the case where this node's runner did nothing wrong and simply ran
    /// a different job: every job carries the same labels, so a JIT runner
    /// started for one takes whichever matching job GitHub hands it. The job
    /// we started it for is still waiting, and waiting out a failure cooldown
    /// to notice that only makes the queue slower.
    ///
    /// - Parameters:
    ///   - id: The job to return to the queue.
    ///   - maxAttempts: How many times in total this node may start the job.
    /// - Returns: Whether the job was requeued, and if not, why not.
    /// - Throws: If the database cannot be written.
    @discardableResult
    public func returnJobToQueue(id: String, maxAttempts: Int) async throws -> RequeueOutcome {
        try await writer.write { db in
            guard var record = try JobRecord.fetchOne(db, key: id) else { return .notEligible }
            guard JobStatus(rawValue: record.status) != .queued else { return .notEligible }
            return try Self.requeue(&record, in: db, maxAttempts: maxAttempts)
        }
    }

    /// Reset a job to `queued`, or record that it has run out of attempts.
    ///
    /// Giving up is marked by pushing `attempts` one past the ceiling. GitHub
    /// goes on offering a job for hours after this node has stopped trying, so
    /// without a marker that says "already gave up" the poll loop would report
    /// the same exhaustion every thirty seconds until GitHub's own timeout.
    private static func requeue(
        _ record: inout JobRecord, in db: Database, maxAttempts: Int
    ) throws -> RequeueOutcome {
        let gaveUp = maxAttempts + 1
        guard record.attempts < gaveUp else { return .notEligible }
        record.updatedAt = Date()

        guard record.attempts < maxAttempts else {
            record.attempts = gaveUp
            record.status = JobStatus.failed.rawValue
            record.exitReason =
                "gave up after \(maxAttempts) attempts on this node"
                + (record.exitReason.map { "; last failure: \($0)" } ?? "")
            record.completedAt = Date()
            try record.update(db)
            return .exhausted(attempts: maxAttempts)
        }

        record.status = JobStatus.queued.rawValue
        record.startedAt = nil
        record.completedAt = nil
        record.exitReason = nil
        try record.update(db)
        return .requeued(attempt: record.attempts + 1)
    }
}
