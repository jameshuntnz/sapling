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

        return StatusResponse(
            version: SaplingVersion.current,
            node: node,
            slots: slots,
            queuedJobs: try await store.countJobs(status: .queued),
            runningJobs: (inUse[.macos] ?? 0) + (inUse[.linux] ?? 0),
            completedLast24h: try await store.countJobs(status: .completed, since: dayAgo),
            failedLast24h: try await store.countJobs(status: .failed, since: dayAgo),
            watchedRepos: config.github.repos,
            lastPollAt: lastPollRaw.flatMap { ISO8601DateFormatter().date(from: $0) },
            lastPollError: try await store.state(SaplingStore.StateKey.lastPollError)
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
