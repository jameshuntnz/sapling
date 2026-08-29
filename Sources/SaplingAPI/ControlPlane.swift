import Foundation
import SaplingAgent
import SaplingCore
import SaplingDB

/// Assembles the answers the REST API serves.
///
/// Reads from the store — the agent writes state as it happens, and nothing
/// here inspects live processes (§5.1). That keeps the API correct even while
/// the agent is busy, and identical whether it's serving the CLI or the menu
/// bar app.
///
/// `jobResources` is the one exception, and is deliberate: what a job's own VM
/// is using cannot be written down as it happens without a row every five
/// seconds per job, so it is asked of the agent's sampler and is the only
/// answer here that a node without a running agent cannot give.
struct ControlPlane: Sendable {
    let store: SaplingStore
    let config: SaplingConfig
    let agent: NodeAgent?

    init(store: SaplingStore, config: SaplingConfig, agent: NodeAgent?) {
        self.store = store
        self.config = config
        self.agent = agent
    }

    func status() async throws -> StatusResponse {
        let live = await effectiveConfig()
        let nodeID = agent?.nodeID ?? NodeAgent.stableNodeID(name: live.node.name)
        let node =
            try await store.node(id: nodeID)
            ?? Node(
                id: nodeID,
                name: live.node.name,
                platform: "darwin/arm64",
                lastSeenAt: nil,
                status: .offline
            )

        let inUse = try await store.slotsInUse()
        let slots = [
            SlotUsage(
                platform: .macos,
                inUse: inUse[.macos] ?? 0,
                capacity: live.macos.effectiveMaxConcurrent
            ),
            SlotUsage(
                platform: .linux,
                inUse: inUse[.linux] ?? 0,
                capacity: live.linux.effectiveMaxConcurrent
            ),
        ]
        let nodeCapacity = live.node.effectiveMaxConcurrent(
            macOS: live.macos.effectiveMaxConcurrent,
            linux: live.linux.effectiveMaxConcurrent)

        // Charged the larger default for a job recorded before sizes existed:
        // which platform an unsized survivor belonged to is exactly what is not
        // known, and under-reporting free memory is the safer way to be wrong.
        let totalGB = Int(ProcessInfo.processInfo.physicalMemory / 1_073_741_824)
        let fallbackGB = max(
            live.macos.memoryGB ?? MacOSConfig.baseImageDefaultMemoryGB,
            live.linux.memoryGB ?? LinuxConfig.containerDefaultMemoryGB)
        let committedGB = (try? await store.committedMemoryGB(fallbackGB: fallbackGB)) ?? 0

        let dayAgo = Date().addingTimeInterval(-86400)
        let lastPollRaw = try await store.state(SaplingStore.StateKey.lastPollAt)
        // Configured repos win; otherwise report what discovery actually
        // resolved, which is the honest answer to "what is this node watching".
        let watched: [String]
        if !live.github.repos.isEmpty {
            watched = live.github.repos
        } else {
            let raw = try await store.state(SaplingStore.StateKey.watchedRepos) ?? "[]"
            watched = (try? JSONDecoder().decode([String].self, from: Data(raw.utf8))) ?? []
        }

        return StatusResponse(
            version: SaplingVersion.current,
            node: node,
            slots: slots,
            nodeCapacity: nodeCapacity,
            memoryBudgetGB: live.node.memoryBudgetGB(totalGB: totalGB),
            committedMemoryGB: committedGB,
            queuedJobs: try await store.countJobs(status: .queued),
            runningJobs: (inUse[.macos] ?? 0) + (inUse[.linux] ?? 0),
            completedLast24h: try await store.countJobs(status: .completed, since: dayAgo),
            failedLast24h: try await store.countJobs(status: .failed, since: dayAgo),
            cancelledLast24h: try await store.countJobs(status: .cancelled, since: dayAgo),
            watchedRepos: watched,
            lastPollAt: lastPollRaw.flatMap { ISO8601DateFormatter().date(from: $0) },
            lastPollError: try await store.state(SaplingStore.StateKey.lastPollError),
            forkRunsRefused: Int(
                try await store.state(SaplingStore.StateKey.forkRunsRefused) ?? "") ?? 0,
            metrics: await agent?.metrics.current()
        )
    }

    /// The configuration actually in force.
    ///
    /// Asked of the agent rather than held here, because `sapling config
    /// reload` changes it under a running daemon and a second copy would go
    /// stale the moment it did. Falls back to the configuration this control
    /// plane was constructed with when there is no agent in this process —
    /// `sapling demo`, and the tests.
    func effectiveConfig() async -> SaplingConfig {
        await agent?.currentConfig() ?? config
    }

    func nodes() async throws -> [Node] {
        try await store.allNodes()
    }

    func jobs(status: JobStatus?, limit: Int) async throws -> [Job] {
        try await store.jobs(status: status, limit: min(max(1, limit), 500))
    }

    func job(id: String) async throws -> JobDetailResponse? {
        guard let job = try await store.job(id: id) else { return nil }
        let events = try await store.events(jobID: id)
        return JobDetailResponse(job: job, events: events)
    }

    /// `after` lets the log viewer tail without re-fetching the whole log.
    func logs(jobID: String, after: Int64?) async throws -> LogsResponse? {
        guard try await store.job(id: jobID) != nil else { return nil }
        let events = try await store.events(jobID: jobID, afterID: after)
        return LogsResponse(jobID: jobID, events: events)
    }

    /// What one job's own VM or container is using, against what it was given.
    ///
    /// Only the node running the job can answer this — the figures come from
    /// the host process behind the environment and are not in the store, so
    /// this is the one endpoint that reads from the agent rather than the
    /// database. A job whose environment has gone still answers, with the
    /// peaks it reached.
    ///
    /// - Parameters:
    ///   - id: The job to report on.
    ///   - limit: Most recent N samples, or all held when `nil`.
    /// - Returns: The job's figures, or `nil` if there is no such job.
    /// - Throws: If the store cannot be read.
    func jobResources(id: String, limit: Int?) async throws -> JobResourcesResponse? {
        guard let job = try await store.job(id: id) else { return nil }
        var response = JobResourcesResponse(jobID: id, platform: job.platform)
        if let agent {
            response = await agent.jobStats.resources(
                jobID: id, platform: job.platform, limit: limit)
        }

        response.requestGB = job.memoryGB
        response.requestFromLabel = RunnerImageSelector.parse(job.labels).memoryGB != nil

        // Advice comes from this job's own history, not the live run: one kill
        // can be a bad day on a loaded node, and the question being answered —
        // is this label the right size — is about the shape of many.
        if let request = job.memoryGB, let name = job.name {
            let reasons = (try? await store.recentExitReasons(repo: job.repo, name: name)) ?? []
            response.advice = MemorySizing.advise(
                requestGB: request, outcomes: reasons.map(FailureKind.of))
        }
        return response
    }

    func createJoinToken(controlPlaneURL: String) async throws -> JoinTokenResponse {
        let token = try await store.createJoinToken()
        return JoinTokenResponse(
            token: token.token,
            expiresAt: token.expiresAt,
            controlPlaneURL: controlPlaneURL
        )
    }

    /// Recent hardware samples, for a chart.
    ///
    /// - Parameter limit: Most recent N samples, or all held when `nil`.
    /// - Returns: Samples oldest first, and the gap between them.
    public func metricsHistory(limit: Int?) async -> MetricsHistoryResponse {
        let samples = await agent?.metrics.recent(limit: limit) ?? []
        return MetricsHistoryResponse(
            samples: samples,
            intervalSeconds: Int(MetricsCollector.interval.components.seconds))
    }

    // MARK: - Updates

    /// Look for a newer version on the configured channel.
    ///
    /// A failed check is reported in the response rather than thrown: not
    /// being able to reach GitHub is worth showing, not worth a 500.
    ///
    /// - Returns: What is available, and what is running now.
    public func checkForUpdate() async -> UpdateCheckResponse {
        let live = await effectiveConfig()
        do {
            let update = try await SelfUpdater(config: live).check()
            return UpdateCheckResponse(
                current: SaplingVersion.current,
                channel: live.update.channel,
                available: update?.version,
                tag: update?.tag,
                publishedAt: update?.publishedAt)
        } catch {
            return UpdateCheckResponse(
                current: SaplingVersion.current,
                channel: live.update.channel,
                error: error.localizedDescription)
        }
    }

    /// Install the newest version on the configured channel.
    ///
    /// The daemon restarts into the new binary, so this replies before
    /// restarting and the connection then drops — which is success, not a
    /// failure, and the caller should treat it as such.
    ///
    /// - Parameter force: Update even while jobs are running.
    /// - Returns: What is being applied, or why nothing is.
    public func applyUpdate(force: Bool) async -> UpdateApplyResponse {
        let live = await effectiveConfig()
        let updater = SelfUpdater(config: live)
        let update: AvailableUpdate?
        do {
            // With force, take the newest release on the channel whether or not
            // it outranks what is running. Without it, only a genuine upgrade.
            update = force ? try await updater.newestRelease() : try await updater.check()
        } catch {
            return UpdateApplyResponse(
                applying: false, message: "could not check for updates: \(error.localizedDescription)")
        }
        guard let update else {
            return UpdateApplyResponse(
                applying: false,
                message: "already on \(SaplingVersion.current), the newest on the "
                    + "\(live.update.channel.rawValue) channel")
        }

        let running = await agent?.activeJobCount() ?? 0
        do {
            // Verified and installed before replying, so a failure is reported
            // rather than silently swallowed by the restart.
            try await updater.apply(update, runningJobs: running, force: force)
            return UpdateApplyResponse(
                applying: true, version: update.version,
                message: "installed \(update.version); the daemon is restarting")
        } catch {
            return UpdateApplyResponse(applying: false, message: error.localizedDescription)
        }
    }

    // MARK: - Control

    func drain() async throws -> ControlResponse {
        try await setStatus(.draining)
        let active = await agent?.activeJobCount() ?? 0
        return ControlResponse(
            status: .draining,
            message: active == 0
                ? "not accepting new jobs; nothing is running"
                : "not accepting new jobs; waiting on \(active) running job(s)"
        )
    }

    func cordon() async throws -> ControlResponse {
        try await setStatus(.cordoned)
        return ControlResponse(status: .cordoned, message: "job acceptance paused")
    }

    func uncordon() async throws -> ControlResponse {
        try await setStatus(.online)
        return ControlResponse(status: .online, message: "accepting jobs")
    }

    private func setStatus(_ status: NodeStatus) async throws {
        if let agent {
            try await agent.setStatus(status)
        } else {
            try await store.setNodeStatus(id: NodeAgent.stableNodeID(name: config.node.name), status: status)
        }
    }
}
