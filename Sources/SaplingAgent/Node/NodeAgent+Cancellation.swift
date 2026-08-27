import Foundation
import SaplingCore
import SaplingDB

/// Letting go of work GitHub has withdrawn.
///
/// A cancelled job is not a job that fails — it is a job that never arrives.
/// The JIT runner boots, registers, prints "Listening for Jobs", and then waits
/// for an assignment GitHub will never send, holding one of two macOS slots
/// until the job timeout expires two hours later. Nothing in the runner's own
/// output suggests anything is wrong, and its exit code never comes, so asking
/// GitHub is the only way to find out.
extension NodeAgent {
    /// Conclusions that mean no runner assignment is ever coming.
    ///
    /// Deliberately narrow. A job GitHub has concluded as `success` or
    /// `failure` is one whose runner is already exiting under its own power,
    /// and killing that VM mid-exit would truncate the log upload — `finalize`
    /// handles those. These two produce no assignment at all.
    static let abandonedConclusions: Set<String> = ["cancelled", "skipped"]

    /// Ask GitHub about everything this node is holding, and release whatever
    /// GitHub has taken back.
    ///
    /// - Parameter stillQueued: The job ids GitHub reported queued this cycle,
    ///   per repo. Only repos that actually answered appear, so a failed poll
    ///   can never make a live job look abandoned.
    func reconcileAbandonedJobs(stillQueued: [String: Set<String>]) async {
        await releaseAbandonedRunningJobs()
        await retireAbandonedQueuedJobs(stillQueued: stillQueued)
    }

    /// Jobs this node is actively running that GitHub has cancelled.
    private func releaseAbandonedRunningJobs() async {
        let active = (try? await store.activeJobs()) ?? []
        for job in active {
            // `.cleanup` means teardown is already under way — including from
            // an earlier pass through here, which is what stops this asking
            // GitHub about the same job on every cycle.
            guard job.status != .cleanup, runningJobs[job.id] != nil else { continue }
            guard let reason = await abandonmentReason(for: job) else { continue }
            await abandon(job, reason: reason)
        }
    }

    /// Why GitHub will never assign this job, or `nil` if it still might.
    private func abandonmentReason(for job: Job) async -> String? {
        guard let jobID = Int64(job.id) else { return nil }
        do {
            let remote = try await github.job(repo: job.repo, jobID: jobID)
            guard remote.isCompleted, let conclusion = remote.conclusion,
                Self.abandonedConclusions.contains(conclusion)
            else { return nil }
            return "GitHub \(conclusion) this job — releasing the runner"
        } catch let error as GitHubError where error.statusCode == 404 {
            return "this job no longer exists on GitHub — releasing the runner"
        } catch {
            // A poll that couldn't reach GitHub tells us nothing about the job.
            return nil
        }
    }

    /// Stop a running job, and account for it from outside its own task.
    ///
    /// The bookkeeping deliberately does not live in `execute`'s catch block.
    /// GRDB honours task cancellation, so a cancelled job task cannot write to
    /// the store at all — every `try?` around `updateJobStatus` would swallow a
    /// `CancellationError` and leave the job `running` with its slot held
    /// forever, which is a slower version of the bug this path exists to fix.
    /// The poll task is not cancelled, so the recording happens here.
    private func abandon(_ job: Job, reason: String) async {
        guard let task = runningJobs[job.id] else { return }
        Log.warn("job \(job.id): \(reason)")
        try? await store.appendEvent(
            jobID: job.id, event: RunEventName.jobCancelled, detail: reason)

        // Still holds its slot: the VM is not gone until teardown says so, and
        // handing the slot over early is how a third VM gets cloned.
        try? await store.updateJobStatus(id: job.id, status: .cleanup)
        task.cancel()

        // Detached so the poll loop isn't blocked behind a VM shutdown, and so
        // this survives whatever happens to the cycle that started it.
        Task.detached { [store] in
            await task.value
            // Only if it is still the job we cancelled. A runner that happened
            // to finish in the same instant has already recorded its own real
            // outcome through `finalize`, and that one is the truthful answer.
            guard (try? await store.job(id: job.id))?.status == .cleanup else { return }
            try? await store.updateJobStatus(
                id: job.id, status: .failed, exitReason: reason, completedAt: Date())
            Log.info("job \(job.id) released after cancellation")
        }
    }

    /// Jobs still waiting here that GitHub finished without us.
    ///
    /// Worth its own pass: dispatching one of these provisions an entire VM for
    /// a job that no longer exists, which then waits out the full job timeout.
    /// Cheaper to notice before the clone than after.
    private func retireAbandonedQueuedJobs(stillQueued: [String: Set<String>]) async {
        let queued = (try? await store.jobs(status: .queued, limit: 100)) ?? []
        for job in queued {
            // Only judge a job against a repo that answered this cycle.
            guard let live = stillQueued[job.repo], !live.contains(job.id) else { continue }
            guard let reason = await retirementReason(for: job) else { continue }
            Log.info("dropping queued job \(job.id): \(reason)")
            try? await store.appendEvent(
                jobID: job.id, event: RunEventName.jobCancelled, detail: reason)
            try? await store.updateJobStatus(
                id: job.id, status: .failed, exitReason: reason, completedAt: Date())
        }
    }

    /// Why this queued job should never be dispatched, or `nil` to keep it.
    ///
    /// Broader than `abandonmentReason`: nothing has been provisioned yet, so
    /// any finished job is one there is no point starting a VM for.
    private func retirementReason(for job: Job) async -> String? {
        guard let jobID = Int64(job.id) else { return nil }
        do {
            let remote = try await github.job(repo: job.repo, jobID: jobID)
            guard remote.isCompleted else { return nil }
            return "GitHub \(remote.conclusion ?? "finished") this job before it started here"
        } catch let error as GitHubError where error.statusCode == 404 {
            return "this job no longer exists on GitHub"
        } catch {
            return nil
        }
    }
}
