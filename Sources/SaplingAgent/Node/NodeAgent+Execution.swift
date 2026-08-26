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

        // The bridge interface only exists once something has run, so this is
        // the reliable point to (re)assert the egress filter.
        if config.network.blockPrivateRanges, !networkGuardApplied {
            if (try? await NetworkGuard(config: config.network).apply()) != nil {
                networkGuardApplied = true
            }
        }

        do {
            let labels = job.platform == .macos ? config.macos.labels : config.linux.labels
            let jitConfig = try await github.jitConfig(
                repo: job.repo,
                runnerName: runnerName,
                labels: labels
            )

            try await store.updateJobStatus(id: job.id, status: .running)

            let request = JobRunRequest(
                jobID: job.id,
                repo: job.repo,
                runnerName: runnerName,
                jitConfig: jitConfig,
                labels: labels,
                image: job.platform == .linux ? config.linux.defaultImage : nil,
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
        var status: JobStatus = outcome.succeeded ? .completed : .failed
        var reason = outcome.message

        if let jobID = Int64(job.id),
            let remote = try? await github.job(repo: job.repo, jobID: jobID),
            remote.isCompleted
        {
            switch remote.conclusion {
            case "success":
                status = .completed
                reason = nil
            case let conclusion?:
                status = .failed
                reason = "GitHub reported conclusion: \(conclusion)"
            case nil:
                break
            }
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
