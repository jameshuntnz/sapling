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
    /// Triggers whose code is the branch itself.
    ///
    /// A comment, a review or a finished workflow can name the default branch
    /// while acting on a pull request's code.
    static let promotingEvents: Set<String> = ["push", "schedule", "workflow_dispatch"]

    /// Why a finished job's lease must not become the seed, or nil if it may.
    ///
    /// - Parameters:
    ///   - remote: GitHub's record of the job, fetched after it finished.
    ///   - run: GitHub's record of the job's run, if it could be fetched.
    ///   - repo: The watched repository.
    ///   - runnerName: The runner Sapling started, whose VM held the lease.
    ///   - defaultBranch: The repository's default branch, if known.
    ///   - onDefaultBranch: Whether the default branch contains the job's
    ///     commit. A tag can share the branch's name; only this tells them apart.
    /// - Returns: A reason for the log, or nil to promote.
    static func refusal(
        remote: WorkflowJob, run: WorkflowRun?, repo: String, runnerName: String,
        defaultBranch: String?, onDefaultBranch: Bool?
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
        guard let event = run?.event, promotingEvents.contains(event) else {
            return "a \(run?.event ?? "run of unknown trigger") does not update the cache"
        }
        guard let head = run?.headRepository?.fullName,
            head.compare(repo, options: .caseInsensitive) == .orderedSame
        else {
            return "the run's code did not come from \(repo)"
        }
        guard onDefaultBranch == true else {
            return "the job's commit is not on \(defaultBranch)"
        }
        return nil
    }
}
