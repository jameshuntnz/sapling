import Foundation
import SaplingAgent
import SaplingCore
import SaplingDB

/// Assembles the answers the REST API serves.
///
/// Reads exclusively from the store — the agent writes state as it happens,
/// and nothing here inspects live processes (§5.1). That keeps the API
/// correct even while the agent is busy, and identical whether it's serving
/// the CLI or the menu bar app.
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
        let nodeID = agent?.nodeID ?? NodeAgent.stableNodeID(name: config.node.name)
        let node =
            try await store.node(id: nodeID)
            ?? Node(
                id: nodeID,
                name: config.node.name,
                platform: "darwin/arm64",
                lastSeenAt: nil,
                status: .offline
            )

        let inUse = try await store.slotsInUse()
        let slots = [
            SlotUsage(
                platform: .macos,
                inUse: inUse[.macos] ?? 0,
                capacity: config.macos.effectiveMaxConcurrent
            ),
            SlotUsage(
                platform: .linux,
                inUse: inUse[.linux] ?? 0,
                capacity: config.linux.effectiveMaxConcurrent
            ),
        ]

        let dayAgo = Date().addingTimeInterval(-86400)
        let lastPollRaw = try await store.state(SaplingStore.StateKey.lastPollAt)
        // Configured repos win; otherwise report what discovery actually
        // resolved, which is the honest answer to "what is this node watching".
        let watched: [String]
        if !config.github.repos.isEmpty {
            watched = config.github.repos
        } else {
            let raw = try await store.state(SaplingStore.StateKey.watchedRepos) ?? "[]"
            watched = (try? JSONDecoder().decode([String].self, from: Data(raw.utf8))) ?? []
        }

        return StatusResponse(
            version: SaplingVersion.current,
            node: node,
            slots: slots,
            queuedJobs: try await store.countJobs(status: .queued),
            runningJobs: (inUse[.macos] ?? 0) + (inUse[.linux] ?? 0),
            completedLast24h: try await store.countJobs(status: .completed, since: dayAgo),
            failedLast24h: try await store.countJobs(status: .failed, since: dayAgo),
            watchedRepos: watched,
            lastPollAt: lastPollRaw.flatMap { ISO8601DateFormatter().date(from: $0) },
            lastPollError: try await store.state(SaplingStore.StateKey.lastPollError),
            metrics: await agent?.metrics.current()
        )
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
        do {
            let update = try await SelfUpdater(config: config).check()
            return UpdateCheckResponse(
                current: SaplingVersion.current,
                channel: config.update.channel,
                available: update?.version,
                tag: update?.tag,
                publishedAt: update?.publishedAt)
        } catch {
            return UpdateCheckResponse(
                current: SaplingVersion.current,
                channel: config.update.channel,
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
        let updater = SelfUpdater(config: config)
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
                    + "\(config.update.channel.rawValue) channel")
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
