import Foundation
import SaplingCore
import SaplingDB

/// Running one job through a provider, and recording what happened.
extension NodeAgent {
    func execute(_ job: Job) async {
        let events = StoreEventSink(store: store, jobID: job.id, stats: jobStats)
        let runnerName =
            Self.runnerNamePrefix + job.platform.rawValue + "-"
            + String(UUID().uuidString.prefix(8)).lowercased()

        // Re-asserted before every job rather than once: a bridge that came up
        // since the last job may sit on a subnet the loaded rules don't cover,
        // and running a job unfiltered is the one outcome §8 rules out. If the
        // filter can't be applied, the job fails closed rather than running.
        if config.network.blockPrivateRanges {
            do {
                try await NetworkGuard(config: config.network).apply()
                networkGuardApplied = true
            } catch {
                networkGuardApplied = false
                let reason =
                    "refusing to start: egress filter could not be applied "
                    + "(\(error.localizedDescription))"
                await events.record(RunEventName.jobFailed, detail: reason)
                try? await store.updateJobStatus(
                    id: job.id, status: .failed, exitReason: reason, completedAt: Date())
                Log.error("job \(job.id): \(reason)")
                return
            }
        }

        do {
            // Resolved before the runner is registered: building an image can
            // take minutes, and a JIT runner minted first would be sitting in
            // the repo's runner list for all of it, eligible to pick up some
            // other queued job while this one is still waiting on its image.
            let image = try await resolveImage(for: job, events: events)

            // The runner must advertise every label the job asked for, every
            // selector included. GitHub dispatches to a runner only when the
            // runner's labels are a superset of the job's — so a runner
            // registered with just the node's labels is never given a job that
            // asked for `image:android`, and sits at "Listening for Jobs" until
            // the job timeout while holding a slot. Sapling strips selectors to
            // decide *its own* eligibility; GitHub still needs to see them.
            //
            // Taken wholesale rather than named one at a time. Listing them
            // individually is what broke: `mem:` was taught to the matcher and
            // not to this, and a job carrying it was never dispatched at all.
            let nodeLabels = job.platform == .macos ? config.macos.labels : config.linux.labels
            let labels = nodeLabels + RunnerImageSelector.selectors(in: job.labels)
            // Recorded before the runner exists, so housekeeping can never
            // sweep it during the seconds between minting and connecting.
            inFlightRunners.insert(runnerName)
            defer { inFlightRunners.remove(runnerName) }

            let jitConfig = try await github.jitConfig(
                repo: job.repo,
                runnerName: runnerName,
                labels: labels
            )

            try await store.updateJobStatus(id: job.id, status: .running)
            if let image { try? await store.setJobImageRef(id: job.id, imageRef: image) }

            let request = JobRunRequest(
                jobID: job.id,
                repo: job.repo,
                runnerName: runnerName,
                jitConfig: jitConfig,
                labels: labels,
                image: image,
                // Cache settings are not passed as variables. They used to be,
                // resolved against `interfaces.first.address` — whichever
                // bridge came up first — so a container on `192.168.64.x` and
                // a VM on `192.168.65.x` could not both be right, and which
                // platform got a working cache was decided by boot order. The
                // environment resolves its own gateway; see `CacheEndpoint`.
                cache: config.cache.enabled ? config.cache : nil,
                bootTimeout: .seconds(config.macos.bootTimeoutSeconds),
                jobTimeout: .seconds(
                    job.platform == .macos ? config.macos.jobTimeoutSeconds : config.linux.jobTimeoutSeconds),
                memoryGB: memoryGB(for: job)
            )

            let outcome: JobOutcome
            switch job.platform {
            case .macos:
                guard let macProvider else { throw ProviderError("macOS jobs are disabled on this node") }
                outcome = try await macProvider.run(request, events: events)
            case .linux:
                guard let linuxProvider else { throw ProviderError("Linux jobs are disabled on this node") }
                outcome = try await linuxProvider.run(request, events: events)
            }

            await finalize(job: job, outcome: outcome, events: events)
        } catch {
            // Cancellation is `abandon`'s to record, not ours. GRDB honours
            // task cancellation, so every store write from here would throw
            // `CancellationError` into a `try?` and silently do nothing —
            // leaving the job `running` and its slot held. `abandon` writes the
            // outcome from the poll task, which is not cancelled.
            if Task.isCancelled {
                Log.info("job \(job.id) stopped after GitHub withdrew it")
                return
            }
            await events.record(RunEventName.jobFailed, detail: error.localizedDescription)
            try? await store.updateJobStatus(
                id: job.id,
                status: .failed,
                exitReason: error.localizedDescription,
                completedAt: Date()
            )
            Log.error("job \(job.id) failed: \(error.localizedDescription)")
        }
    }

    /// Reconcile against GitHub before recording the result.
    ///
    /// A JIT runner picks up whichever queued job matches its labels, which
    /// isn't necessarily the one that prompted us to start it. The runner's
    /// exit code therefore tells us the runner finished, not whether *this*
    /// job passed — GitHub is the authority on that.
    func finalize(job: Job, outcome: JobOutcome, events: any EventSink) async {
        let status: JobStatus
        let reason: String?

        // A clean exit is not evidence the job ran. A runner that refuses to
        // work — a deprecated version, say — exits 0 having done nothing, and
        // trusting that reported success for work that never happened.
        switch await remoteConclusion(for: job) {
        case .success:
            status = .completed
            reason = nil
        case .concluded("cancelled"):
            status = .cancelled
            reason = "GitHub cancelled this job"
        case .concluded(let conclusion):
            status = .failed
            reason = "GitHub reported conclusion: \(conclusion)"
        case .stillQueued:
            // Not a failure: every job carries the same labels, so the runner
            // we started for this job took a different one that matched. This
            // job is still waiting on GitHub, so put it back rather than
            // recording a failure nothing actually did.
            await handOffToQueue(job: job, events: events)
            return
        case .unknown:
            status = .failed
            reason =
                outcome.message.map { "runner exited without the job completing: \($0)" }
                ?? "runner exited without the job completing"
        }

        await events.record(
            status == .completed ? RunEventName.jobCompleted : RunEventName.jobFailed,
            detail: reason
        )
        try? await store.updateJobStatus(
            id: job.id,
            status: status,
            exitReason: reason,
            completedAt: Date()
        )
        Log.info("job \(job.id) \(status.rawValue)\(reason.map { " (\($0))" } ?? "")")
    }

    /// Put a job back in the queue because our runner ran a different one.
    ///
    /// Bounded by the same attempt ceiling as any other requeue: if this node
    /// somehow never manages to run this particular job, it should stop trying
    /// rather than provision a VM for it indefinitely.
    private func handOffToQueue(job: Job, events: any EventSink) async {
        let detail = "the runner took a different queued job; returning this one to the queue"
        switch (try? await store.returnJobToQueue(id: job.id, maxAttempts: Self.maxJobAttempts))
            ?? .notEligible
        {
        case .requeued(let attempt):
            await events.record(RunEventName.jobRequeued, detail: detail)
            Log.info("job \(job.id) returned to the queue (attempt \(attempt) next)")
        case .exhausted(let attempts):
            Log.error("giving up on job \(job.id) after \(attempts) attempts on this node")
            await handleExhaustedJob(job)
        case .notEligible:
            break
        }
    }

}

extension NodeAgent {
    /// What GitHub says became of a job.
    enum RemoteConclusion: Equatable {
        case success
        /// GitHub finished the job, with this conclusion.
        case concluded(String)
        /// GitHub still has the job waiting for a runner, so whatever our
        /// runner did, it wasn't this.
        case stillQueued
        /// No answer: GitHub unreachable, or the job never concluded.
        case unknown
    }

    /// Ask GitHub how the job ended, allowing for its result lagging slightly
    /// behind the runner exiting.
    ///
    /// GitHub is the authority for two separate reasons. A JIT runner picks up
    /// whichever queued job matches its labels, not necessarily the one that
    /// prompted the launch — so the exit code describes the runner, not this
    /// job. And a runner can exit cleanly without doing any work at all, which
    /// an exit code cannot distinguish from success.
    /// - Parameters:
    ///   - job: The job to ask about.
    ///   - attempts: How many times to ask before giving up.
    ///   - retryDelay: Gap between attempts.
    ///   - grace: Extra time allowed while GitHub still reports the job *in
    ///     progress*. Defaults to none when `retryDelay` is zero, so a test
    ///     asking once still asks once.
    /// - Returns: What GitHub says became of the job.
    func remoteConclusion(
        for job: Job,
        attempts: Int? = nil,
        retryDelay: Duration? = nil,
        grace: Duration? = nil
    ) async -> RemoteConclusion {
        let attempts = attempts ?? conclusionAttempts
        let retryDelay = retryDelay ?? conclusionRetryDelay
        let grace = grace ?? (retryDelay == .zero ? .zero : Self.inProgressGrace)
        guard let jobID = Int64(job.id) else { return .unknown }

        let started = ContinuousClock.now
        var lastSeenQueued = false
        var lastSeenRunning = false
        var attempt = 0

        while true {
            if attempt > 0 {
                try? await Task.sleep(for: retryDelay)
            }
            attempt += 1

            if let remote = try? await github.job(repo: job.repo, jobID: jobID) {
                if remote.isCompleted {
                    switch remote.conclusion {
                    case "success": return .success
                    case let conclusion?: return .concluded(conclusion)
                    case nil: return .unknown
                    }
                }
                // Still waiting for a runner after our runner has exited means
                // our runner ran something else. Still *running* means the
                // opposite — GitHub has it, and simply hasn't finished with it.
                lastSeenQueued = remote.isQueued
                lastSeenRunning = !remote.isQueued
            }

            if attempt >= attempts {
                // The base attempts cover GitHub lagging a second or two behind
                // a runner exiting. This covers something else: the runner has
                // exited and the job is still finishing on GitHub's side, with
                // post-steps and log upload to go. Fifteen seconds did not
                // cover it — an iOS job GitHub concluded as `failure`, and a
                // release that published successfully, were both recorded here
                // as "runner exited without the job completing". Those are the
                // failures that make a working node look broken.
                guard lastSeenRunning, ContinuousClock.now - started < grace else { break }
            }
        }
        return lastSeenQueued ? .stillQueued : .unknown
    }

    /// The image this job runs in, or `nil` for macOS jobs which have none.
    ///
    /// A job that names no image never costs an API call — the node's default
    /// is returned directly. Only an `image:` selector triggers the lookup of
    /// the commit the image must be built from.
    func resolveImage(for job: Job, events: any EventSink) async throws -> String? {
        guard job.platform == .linux else { return nil }

        let selector = RunnerImageSelector.split(job.labels).image
        guard let selector else { return config.linux.defaultImage }

        // head_sha isn't carried on the queued-job record, and re-reading the
        // job is cheaper than a column that would be wrong after a re-run.
        let headSha = try? await github.job(repo: job.repo, jobID: Int64(job.id) ?? -1).headSha
        let builder = RunnerImageBuilder(config: config.linux, github: github)
        return try await builder.resolve(
            imageName: selector, repo: job.repo, ref: headSha, events: events)
    }
}
