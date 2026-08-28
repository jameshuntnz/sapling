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
                Log.error("refusing \(repo) #\(job.id): \(reason)")
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

    func capacity(for platform: JobPlatform) -> Int {
        switch platform {
        case .macos: config.macos.effectiveMaxConcurrent
        case .linux: config.linux.effectiveMaxConcurrent
        }
    }

    /// Jobs this node will run at once across both platforms.
    ///
    /// The per-platform counts say what each platform may run; this says what
    /// the machine may run in total. See `NodeConfig.maxConcurrent` for why
    /// both are needed — RAM is shared and the per-platform counts cannot say so.
    var nodeCapacity: Int {
        config.node.effectiveMaxConcurrent(
            macOS: config.macos.effectiveMaxConcurrent,
            linux: config.linux.effectiveMaxConcurrent)
    }

    /// The machine's memory, in GB.
    var totalMemoryGB: Int { Int(ProcessInfo.processInfo.physicalMemory / 1_073_741_824) }

    /// What jobs may collectively hold on this node, in GB.
    var memoryBudgetGB: Int { config.node.memoryBudgetGB(totalGB: totalMemoryGB) }

    /// Memory a job of these labels gets on this node, in GB.
    func memoryGB(for job: Job) -> Int? {
        job.memoryGB
            ?? JobSizing.memoryGB(labels: job.labels, platform: job.platform, config: config)
    }

    /// What a job of unknown size is charged against the budget, in GB.
    ///
    /// Per platform, because the two are nowhere near each other: charging a
    /// macOS VM the container default would book 1GB against a guest that takes
    /// eight, and the budget would admit work the machine cannot hold. Where it
    /// has to guess, it guesses high.
    func defaultMemoryGB(for platform: JobPlatform) -> Int {
        switch platform {
        case .macos:
            max(1, config.macos.memoryGB ?? MacOSConfig.baseImageDefaultMemoryGB)
        case .linux:
            max(1, config.linux.memoryGB ?? LinuxConfig.containerDefaultMemoryGB)
        }
    }

    func dispatchQueuedJobs() async throws {
        var inUse = try await store.slotsInUse()
        // Charged for jobs that predate sizing: the larger of the two defaults,
        // since which platform an unsized survivor belonged to is exactly what
        // is not known, and under-charging over-commits the machine.
        var committedGB = try await store.committedMemoryGB(
            fallbackGB: max(defaultMemoryGB(for: .macos), defaultMemoryGB(for: .linux)))
        let budgetGB = memoryBudgetGB
        let queued = try await store.jobs(status: .queued, limit: 50)
            .sorted { ($0.queuedAt ?? .distantPast) < ($1.queuedAt ?? .distantPast) }

        for job in queued {
            let used = inUse[job.platform] ?? 0
            guard used < capacity(for: job.platform) else { continue }
            // Checked against the live total rather than a running counter, so
            // a job dispatched earlier in this same loop counts against it.
            guard inUse.values.reduce(0, +) < nodeCapacity else { break }
            guard !blockedByOtherPlatform(job.platform, inUse: inUse) else { continue }

            let wanted = memoryGB(for: job) ?? defaultMemoryGB(for: job.platform)
            guard JobSizing.fits(memoryGB: wanted, committedGB: committedGB, budgetGB: budgetGB)
            else {
                // Head-of-line reservation. Skipping to a job that does fit
                // would let a stream of small jobs starve a large one
                // indefinitely, and the large one is usually the build that
                // matters. Waiting costs throughput; starving costs the job.
                break
            }

            inUse[job.platform] = used + 1
            committedGB += wanted
            await dispatch(job, memoryGB: wanted)
        }
    }

    /// Whether the other platform is busy and this node runs one at a time.
    ///
    /// The two platforms share vmnet, and on this hardware they do not share
    /// it well: started together, the VM never gets a bridge, times out, and
    /// its teardown destroys the container's. Holding the job back costs a few
    /// minutes; dispatching it costs the other job outright. See
    /// `NodeConfig.serializePlatforms` for the measurements.
    func blockedByOtherPlatform(_ platform: JobPlatform, inUse: [JobPlatform: Int]) -> Bool {
        guard config.node.serializePlatforms else { return false }
        return inUse.contains { $0.key != platform && $0.value > 0 }
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
