import Foundation
import SaplingCore
import SaplingDB

/// Running one job through a provider, and recording what happened.
extension NodeAgent {
    func execute(_ job: Job) async {
        let events = StoreEventSink(store: store, jobID: job.id)
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

            let labels = job.platform == .macos ? config.macos.labels : config.linux.labels
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
                environment: await jobEnvironment(for: job.platform),
                bootTimeout: .seconds(config.macos.bootTimeoutSeconds),
                jobTimeout: .seconds(
                    job.platform == .macos ? config.macos.jobTimeoutSeconds : config.linux.jobTimeoutSeconds)
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
        case .failure(let conclusion):
            status = .failed
            reason = "GitHub reported conclusion: \(conclusion)"
        case .notFinished:
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

    func jobEnvironment(for platform: JobPlatform) async -> [String: String] {
        guard config.cache.enabled else { return [:] }
        // Jobs reach the host through the bridge gateway; the cache proxy
        // binds there, and it's the one private address they're allowed.
        guard let gateway = await cacheGatewayHint() else { return [:] }
        let base = "http://\(gateway):\(config.cache.port)"
        var env: [String: String] = [:]
        if config.cache.proxies.contains("go") {
            env["GOPROXY"] = "\(base)/go,direct"
            env["GOSUMDB"] = "sum.golang.org"
        }
        if config.cache.proxies.contains("cargo") {
            env["CARGO_REGISTRIES_CRATES_IO_PROTOCOL"] = "sparse"
            env["SAPLING_CARGO_MIRROR"] = "\(base)/cargo"
        }
        if config.cache.proxies.contains("npm") {
            env["NPM_CONFIG_REGISTRY"] = "\(base)/npm"
        }
        return env
    }

    func cacheGatewayHint() async -> String? {
        let interfaces = try? await NetworkGuard.discoverBridgeInterfaces()
        return interfaces?.first?.address
    }
}

extension NodeAgent {
    /// What GitHub says became of a job.
    enum RemoteConclusion {
        case success
        case failure(String)
        /// GitHub has no result: the job did not run to completion here.
        case notFinished
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
    /// - Returns: What GitHub says became of the job.
    func remoteConclusion(
        for job: Job,
        attempts: Int = NodeAgent.conclusionAttempts,
        retryDelay: Duration = NodeAgent.conclusionRetryDelay
    ) async -> RemoteConclusion {
        guard let jobID = Int64(job.id) else { return .notFinished }

        for attempt in 0..<attempts {
            if attempt > 0 {
                try? await Task.sleep(for: retryDelay)
            }
            guard let remote = try? await github.job(repo: job.repo, jobID: jobID) else { continue }
            guard remote.isCompleted else { continue }

            switch remote.conclusion {
            case "success": return .success
            case let conclusion?: return .failure(conclusion)
            case nil: return .notFinished
            }
        }
        return .notFinished
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
