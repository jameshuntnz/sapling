import Foundation
import SaplingCore

/// Giving a job its build cache, and deciding what happens to it afterwards.
///
/// Nothing here may fail a job. A cache is an optimisation: a lease that cannot
/// be prepared means a cold build, and a promotion that cannot happen means the
/// next build is no warmer than this one.
extension NodeAgent {
    /// The directory to mount into this job's environment, or nil for none.
    func leaseBuildCache(for job: Job, events: any EventSink) async -> URL? {
        guard config.buildCache.enabled, job.platform == .macos, let name = job.name else {
            return nil
        }
        do {
            let lease = try await buildCache.prepareLease(repo: job.repo, jobName: name, jobID: job.id)
            await events.log("build cache mounted as $SAPLING_BUILD_CACHE")
            return lease
        } catch {
            await events.log("no build cache for this job: \(error.localizedDescription)")
            return nil
        }
    }

    /// Promote the lease if the job earned it, otherwise throw it away.
    ///
    /// - Parameters:
    ///   - lease: The directory the job had mounted.
    ///   - job: The job it was prepared for.
    ///   - runnerName: The runner whose VM mounted it.
    ///   - events: Where the decision is recorded.
    func settleBuildCache(lease: URL, job: Job, runnerName: String, events: any EventSink) async {
        let refusal: String?
        if let jobID = Int64(job.id), let remote = try? await github.job(repo: job.repo, jobID: jobID) {
            let defaultBranch = try? await github.defaultBranch(repo: job.repo)
            let run = try? await github.run(repo: job.repo, runID: remote.runId)
            var merged: Bool?
            if let defaultBranch, let sha = remote.headSha {
                merged = try? await github.branch(defaultBranch, contains: sha, repo: job.repo)
            }
            refusal = BuildCachePolicy.refusal(
                remote: remote, run: run, repo: job.repo, runnerName: runnerName,
                defaultBranch: defaultBranch, onDefaultBranch: merged)
        } else {
            refusal = "GitHub could not be asked how the job ended"
        }

        guard refusal == nil, let name = job.name else {
            await buildCache.discard(lease: lease)
            await events.log("build cache not kept: \(refusal ?? "the job has no name")")
            return
        }
        do {
            try await buildCache.promote(lease: lease, repo: job.repo, jobName: name)
            await events.log("build cache kept for the next \"\(name)\"")
        } catch {
            await buildCache.discard(lease: lease)
            await events.log("build cache not kept: \(error.localizedDescription)")
        }
        let ceiling = Int64(max(0, config.buildCache.maxSizeGB)) * 1_073_741_824
        let pruned = await buildCache.prune(maxBytes: ceiling)
        if !pruned.isEmpty {
            Log.info(
                "pruned build cache to \(config.buildCache.maxSizeGB)GB: \(pruned.joined(separator: ", "))")
        }
    }
}
