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
            let record = Job(
                id: String(job.id),
                nodeID: nodeID,
                repo: repo,
                workflowRunID: String(job.runId),
                platform: platform,
                labels: job.labels,
                status: .queued,
                name: job.name,
                queuedAt: Date()
            )
            if try await store.insertJobIfNew(record) {
                Log.info("queued \(repo) #\(job.id) \"\(job.name)\" (\(platform.rawValue))")
            } else if try await store.requeueJob(
                id: record.id, failedBefore: Date().addingTimeInterval(-Self.requeueCooldown))
            {
                // GitHub still wants it run, so a local failure shouldn't
                // strand it until GitHub's own timeout hours from now.
                Log.info("re-queued \(repo) #\(job.id) after a local failure")
            }
        }
        return seen
    }

    /// Which platform, if any, can run a job with these labels.
    ///
    /// Matches GitHub's own rule: a runner is eligible when its label set is
    /// a superset of the job's — with `image:` selectors removed first, since
    /// they name a container image rather than a capability the node has to
    /// advertise. Leaving one in would make every job that asks for an image
    /// ineligible everywhere.
    func platform(matching labels: [String]) -> JobPlatform? {
        let requested = Set(RunnerImageSelector.split(labels).capabilities)
        if config.macos.enabled, requested.isSubset(of: Set(config.macos.labels)) {
            return .macos
        }
        if config.linux.enabled, requested.isSubset(of: Set(config.linux.labels)) {
            return .linux
        }
        return nil
    }

    func capacity(for platform: JobPlatform) -> Int {
        switch platform {
        case .macos: config.macos.effectiveMaxConcurrent
        case .linux: config.linux.effectiveMaxConcurrent
        }
    }

    func dispatchQueuedJobs() async throws {
        var inUse = try await store.slotsInUse()
        let queued = try await store.jobs(status: .queued, limit: 50)
            .sorted { ($0.queuedAt ?? .distantPast) < ($1.queuedAt ?? .distantPast) }

        for job in queued {
            let used = inUse[job.platform] ?? 0
            guard used < capacity(for: job.platform) else { continue }
            inUse[job.platform] = used + 1
            await dispatch(job)
        }
    }

    func dispatch(_ job: Job) async {
        // Claim the slot in the database before anything can await, so the
        // next poll cycle can't see this job as still queued.
        do {
            try await store.updateJobStatus(id: job.id, status: .provisioning, startedAt: Date())
            try await store.appendEvent(
                jobID: job.id, event: RunEventName.jobClaimed, detail: config.node.name)
        } catch {
            Log.error("could not claim job \(job.id): \(error.localizedDescription)")
            return
        }

        let task = Task { [weak self] in
            guard let self else { return }
            await self.execute(job)
            await self.finishTracking(jobID: job.id)
        }
        runningJobs[job.id] = task
    }

    func finishTracking(jobID: String) {
        runningJobs[jobID] = nil
    }
}
