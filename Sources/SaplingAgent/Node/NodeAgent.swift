import Foundation
import SaplingCore
import SaplingDB

/// The node agent: polls GitHub, tracks slots, and drives one provider per
/// job (§5.1).
///
/// An actor because slot accounting is the one thing that genuinely must not
/// race — two concurrent claims both reading "1 of 2 macOS slots used" is
/// exactly how you end up violating Apple's 2-VM limit.
public actor NodeAgent {
    /// Stable identifier for this node.
    public nonisolated let nodeID: String
    let config: SaplingConfig
    let store: SaplingStore
    let github: GitHubClient
    let macProvider: TartProvider?
    let linuxProvider: ContainerProvider?

    /// GitHub runner names all start with this, so orphan sweeping can tell
    /// Sapling's runners from any others in the repo.
    public static let runnerNamePrefix = "sap-"

    /// How long to leave a locally failed job alone before offering it again.
    ///
    /// Long enough that a job failing immediately — a missing base image, say —
    /// retries at a sane rate rather than every poll cycle.
    static let requeueCooldown: TimeInterval = 120

    /// How many times to ask GitHub for a job's conclusion before concluding it never finished.
    ///
    /// GitHub records the result a moment after the runner exits, so a single immediate check races that.
    static let conclusionAttempts = 5
    /// Gap between those attempts.
    static let conclusionRetryDelay: Duration = .seconds(3)

    var pollTask: Task<Void, Never>?
    var housekeepingTask: Task<Void, Never>?
    var runningJobs: [String: Task<Void, Never>] = [:]
    var networkGuardApplied = false

    /// Creates an agent for the given configuration and store.
    public init(config: SaplingConfig, store: SaplingStore) {
        self.config = config
        self.store = store
        self.github = GitHubClient(config: config.github)
        self.macProvider = config.macos.enabled ? TartProvider(config: config.macos) : nil
        self.linuxProvider = config.linux.enabled ? ContainerProvider(config: config.linux) : nil
        self.nodeID = Self.stableNodeID(name: config.node.name)
    }

    /// Derive a stable id from the node name so a restart doesn't orphan the
    /// node's job history.
    public static func stableNodeID(name: String) -> String {
        let normalized = name.lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "." }
        return normalized.isEmpty ? "node" : String(normalized)
    }

    // MARK: - Lifecycle

    /// Registers the node, runs preflight checks, and begins polling.
    ///
    /// - Throws: If the node cannot be registered. Provider and firewall
    ///   problems are logged and degraded rather than thrown, so a partial
    ///   environment still runs what it can.
    public func start() async throws {
        try SaplingPaths.ensureHomeDirectory()

        try await store.upsertNode(
            Node(
                id: nodeID,
                name: config.node.name,
                platform: "darwin/arm64",
                lastSeenAt: Date(),
                status: .online
            ))

        // Anything still mid-flight belongs to a previous process whose VMs
        // and containers are already gone.
        let stranded = try await store.reconcileOrphanedJobs(reason: "daemon restarted while job was running")
        if !stranded.isEmpty {
            Log.warn("failed \(stranded.count) job(s) stranded by a previous run")
        }

        await reapProviderOrphans()
        try await runPreflight()
        await applyNetworkGuard()
        await warnAboutPublicRepos()

        pollTask = Task { [weak self] in await self?.pollLoop() }
        housekeepingTask = Task { [weak self] in await self?.housekeepingLoop() }
        Log.info("node agent started as \(nodeID) — watching \(config.github.repos.joined(separator: ", "))")
    }

    /// Stops polling, cancels running jobs, and marks the node offline.
    public func stop() async {
        pollTask?.cancel()
        housekeepingTask?.cancel()
        for task in runningJobs.values { task.cancel() }
        runningJobs.removeAll()
        try? await store.setNodeStatus(id: nodeID, status: .offline)
    }

    /// Wait for in-flight jobs to finish, for `sapling drain`.
    public func waitForActiveJobs() async {
        for task in runningJobs.values {
            _ = await task.result
        }
    }

    /// Changes the node's availability.
    public func setStatus(_ status: NodeStatus) async throws {
        try await store.setNodeStatus(id: nodeID, status: status)
    }

    /// The node's availability as recorded in the store.
    public func currentStatus() async -> NodeStatus {
        (try? await store.node(id: nodeID))?.status ?? .offline
    }

    /// How many jobs this agent is currently running.
    public func activeJobCount() -> Int {
        runningJobs.count
    }
}
