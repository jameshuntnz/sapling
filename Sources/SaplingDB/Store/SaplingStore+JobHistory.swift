import Foundation
import GRDB
import SaplingCore

/// What earlier runs of the same workflow job did.
///
/// Kept apart from the job store proper because it answers a different
/// question: not "what is this job doing" but "what does this job usually do",
/// which is what makes a `mem:` label answerable from evidence rather than
/// guessed. Keyed on repository and job name — the run id never repeats, so it
/// cannot join a job to its own past.
extension SaplingStore {
    /// Why recent completed runs of the same job ended, most recent first.
    ///
    /// Keyed on repository and job name, which is what a `mem:` label is
    /// attached to — the same workflow job across runs, rather than the run id,
    /// which never repeats.
    ///
    /// - Parameters:
    ///   - repo: Repository in `owner/repo` form.
    ///   - name: The job's name from the workflow file.
    ///   - limit: How many recent runs to consider.
    /// - Returns: Exit reasons, most recent first, for runs that finished.
    /// - Throws: If the database cannot be read.
    public func recentExitReasons(repo: String, name: String, limit: Int = 10) async throws
        -> [String?]
    {
        try await writer.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT exit_reason FROM jobs
                    WHERE repo = ? AND name = ? AND completed_at IS NOT NULL
                    ORDER BY updated_at DESC LIMIT ?
                    """,
                arguments: [repo, name, limit]
            ).map { $0["exit_reason"] as String? }
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
}
