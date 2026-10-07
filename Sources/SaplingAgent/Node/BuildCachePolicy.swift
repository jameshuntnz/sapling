import Foundation

/// Which jobs may write the build cache.
///
/// Every job *reads* a seed that only the default branch wrote. Only a job that
/// succeeded on the default branch, on the runner Sapling started for it, may
/// replace that seed. Everything else is thrown away when it finishes.
///
/// The reason is what the cache feeds. A release builds from it, and on this
/// node the release is what the daemon later installs as itself. A pull
/// request that could write the cache could put something in a release that
/// never went through review. Code on the default branch already has, so the
/// cache is exactly as trusted as the branch it came from — and a pull request
/// still starts warm, from its base's output.
///
/// The runner check matters because a JIT runner takes whichever queued job
/// matches its labels. The VM Sapling prepared for a default-branch job can end
/// up running some other branch's job, and that job's output must not be
/// promoted under the default branch's name.
enum BuildCachePolicy {
    /// Why a finished job's lease must not become the seed, or nil if it may.
    ///
    /// - Parameters:
    ///   - remote: GitHub's record of the job, fetched after it finished.
    ///   - runnerName: The runner Sapling started, whose VM held the lease.
    ///   - defaultBranch: The repository's default branch, if known.
    /// - Returns: A reason for the log, or nil to promote.
    static func refusal(
        remote: WorkflowJob, runnerName: String, defaultBranch: String?
    ) -> String? {
        guard remote.isCompleted, remote.conclusion == "success" else {
            return "the job did not succeed"
        }
        guard remote.runnerName == runnerName else {
            return "the job ran on \(remote.runnerName ?? "another runner"), not this lease's VM"
        }
        guard let defaultBranch else {
            return "GitHub did not say which branch is the default"
        }
        guard remote.headBranch == defaultBranch else {
            return
                "only \(defaultBranch) may update the cache; this ran on \(remote.headBranch ?? "no branch")"
        }
        return nil
    }
}
