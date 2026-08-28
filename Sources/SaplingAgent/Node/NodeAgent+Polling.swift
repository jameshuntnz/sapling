import Foundation
import SaplingCore
import SaplingDB

/// Discovering work on GitHub, and deciding what this node may run.
///
/// Discovery and dispatch are deliberately separate: a cordoned node still
/// records what's queued so the UI stays useful while work is held back.
extension NodeAgent {
    func pollLoop() async {
        let interval = Duration.seconds(max(5, config.github.pollIntervalSeconds))
        while !Task.isCancelled {
            do {
                try await pollOnce()
                try await store.setState(
                    SaplingStore.StateKey.lastPollAt, ISO8601DateFormatter().string(from: Date()))
                try await store.setState(SaplingStore.StateKey.lastPollError, nil)
            } catch {
                Log.error("poll failed: \(error.localizedDescription)")
                try? await store.setState(SaplingStore.StateKey.lastPollError, error.localizedDescription)
            }
            try? await store.touchNode(id: nodeID)
            try? await Task.sleep(for: interval)
        }
    }

    func pollOnce() async throws {
        let status = await currentStatus()

        // Discover work even while cordoned, so the UI still shows what is
        // waiting — just don't dispatch any of it.
        var stillQueued: [String: Set<String>] = [:]
        var discoveryError: (any Error)?
        for repo in await watchedRepos() {
            do {
                stillQueued[repo] = try await discoverQueuedJobs(in: repo)
            } catch {
                // One unreachable repo shouldn't stop us polling the others,
                // and a repo that didn't answer is simply left out of
                // `stillQueued` so nothing judges its jobs abandoned.
                discoveryError = error
            }
        }

        // Runs even when discovery partly failed: a job GitHub cancelled is
        // holding a VM right now, and a flaky poll is no reason to leave it
        // holding one for another two hours.
        await reconcileAbandonedJobs(stillQueued: stillQueued)

        if let discoveryError { throw discoveryError }
        guard status.acceptsNewJobs else { return }
        try await dispatchQueuedJobs()
    }

    /// Record everything GitHub reports queued for one repo.
    ///
    /// - Parameter repo: The repository to poll.
    /// - Returns: The ids GitHub reported as queued, which is also the
    ///   evidence that anything *not* in it has stopped waiting.
    /// - Throws: If GitHub cannot be reached, or the store cannot be written.
    private func discoverQueuedJobs(in repo: String) async throws -> Set<String> {
        var seen: Set<String> = []
        for job in try await github.queuedJobs(repo: repo) {
            seen.insert(String(job.id))
            guard let platform = platform(matching: job.labels) else { continue }

            // Refused here rather than queued. A request this node can never
            // satisfy is not a job waiting for capacity, it is a job waiting
            // forever, and a queue that silently holds one is worse than a
            // workflow that fails saying why.
            let sized = JobSizing.memoryGB(
                labels: job.labels, platform: platform, config: config)
            if let reason = JobSizing.unschedulableReason(
                memoryGB: sized,
                budgetGB: memoryBudgetGB,
                ceilingGB: platform == .macos ? config.macos.maxMemoryGB : config.linux.maxMemoryGB)
            {
                await refuse(job: job, repo: repo, platform: platform, reason: reason)
                continue
            }

            let record = Job(
                id: String(job.id),
                nodeID: nodeID,
                repo: repo,
                workflowRunID: String(job.runId),
                platform: platform,
                labels: job.labels,
                status: .queued,
                name: job.name,
                queuedAt: Date(),
                memoryGB: sized
            )
            if try await store.insertJobIfNew(record) {
                Log.info("queued \(repo) #\(job.id) \"\(job.name)\" (\(platform.rawValue))")
                continue
            }
            // GitHub still wants it run, so a local failure shouldn't strand it
            // until GitHub's own timeout hours from now — but only so often.
            switch try await store.requeueJob(
                id: record.id,
                failedBefore: Date().addingTimeInterval(-Self.requeueCooldown),
                maxAttempts: Self.maxJobAttempts
            ) {
            case .requeued(let attempt):
                Log.info("re-queued \(repo) #\(job.id) after a local failure (attempt \(attempt))")
            case .exhausted(let attempts):
                Log.error(
                    "giving up on \(repo) #\(job.id) after \(attempts) failed attempts on this node")
                await handleExhaustedJob(record)
            case .notEligible:
                break
            }
        }
        return seen
    }

    /// Records a job this node can never run, and tells GitHub if it safely can.
    ///
    /// Written to the store as failed rather than only logged: a refusal a
    /// person has to find in the daemon log is a job that, from every angle
    /// they actually look at, simply never ran.
    ///
    /// GitHub cannot be told directly. Every workflow-job endpoint in its REST
    /// API is a read, so the only lever is cancelling the whole run — which
    /// `handleExhaustedJob` already does, and only when no sibling is working
    /// in that run. Reused rather than reinvented, because the sibling check is
    /// the part that makes it safe.
    ///
    /// Acted on once, on first sighting. GitHub keeps reporting the job queued
    /// until its own timeout, and re-cancelling a run every poll would be noise
    /// at best.
    func refuse(job: WorkflowJob, repo: String, platform: JobPlatform, reason: String) async {
        Log.error("refusing \(repo) #\(job.id): \(reason)")
        let record = Job(
            id: String(job.id),
            nodeID: nodeID,
            repo: repo,
            workflowRunID: String(job.runId),
            platform: platform,
            labels: job.labels,
            status: .failed,
            name: job.name,
            queuedAt: Date(),
            completedAt: Date(),
            exitReason: reason
        )
        guard (try? await store.insertJobIfNew(record)) == true else { return }
        await recordEvent(record.id, RunEventName.jobFailed, reason)
        await handleExhaustedJob(record)
    }

    /// Which platform, if any, can run a job with these labels.
    ///
    /// Matches GitHub's own rule: a runner is eligible when its label set is
    /// a superset of the job's — with `image:` and `mem:` selectors removed
    /// first, since they name what the job wants rather than a capability the
    /// node has to advertise. Leaving either in would make every job that asks
    /// for an image or a memory size ineligible everywhere.
    func platform(matching labels: [String]) -> JobPlatform? {
        let requested = Set(RunnerImageSelector.parse(labels).capabilities)
        if config.macos.enabled, requested.isSubset(of: Set(config.macos.labels)) {
            return .macos
        }
        if config.linux.enabled, requested.isSubset(of: Set(config.linux.labels)) {
            return .linux
        }
        return nil
    }

    func dispatch(_ job: Job, memoryGB: Int) async {
        // Claim the slot in the database before anything can await, so the
        // next poll cycle can't see this job as still queued.
        do {
            let attempt = try await store.claimJob(id: job.id)
            // Recorded with the claim, so the reservation and the slot are
            // taken in the same breath — a restart between the two would leave
            // a running job the budget cannot see.
            try await store.setJobMemoryGB(id: job.id, memoryGB: memoryGB)
            try await store.appendEvent(
                jobID: job.id,
                event: RunEventName.jobClaimed,
                detail: attempt > 1 ? "\(config.node.name) (attempt \(attempt))" : config.node.name
            )
        } catch {
            Log.error("could not claim job \(job.id): \(error.localizedDescription)")
            return
        }

        var sized = job
        sized.memoryGB = memoryGB
        let task = Task { [weak self] in
            guard let self else { return }
            await self.execute(sized)
            await self.finishTracking(jobID: job.id)
        }
        runningJobs[job.id] = task
    }

    func finishTracking(jobID: String) {
        runningJobs[jobID] = nil
    }
}
