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
    /// How long an unused built image is kept before housekeeping removes it.
    ///
    /// Long enough that a project releasing fortnightly still gets a cache hit.
    static let imageRetentionDays = 30

    /// Repositories discovered from the App installation.
    ///
    /// Used when `github.repos` is empty; empty itself until the first
    /// successful discovery.
    var discoveredRepos: [String] = []
    /// When discovery last succeeded, for the refresh interval.
    var reposRefreshedAt: Date?

    /// The configuration in force.
    ///
    /// Mutable because `sapling config reload` swaps the reloadable half of it
    /// under a running daemon (`NodeAgent+Config.swift`). Everything here
    /// reads it at the point of use rather than caching it, which is what
    /// makes that safe — see `ConfigReload` for the fields it covers.
    var config: SaplingConfig
    /// The file `config` was loaded from, and the one a reload re-reads.
    let configURL: URL
    let store: SaplingStore
    let github: GitHubClient
    let macProvider: (any JobProvider)?
    let linuxProvider: (any JobProvider)?

    /// GitHub runner names all start with this, so orphan sweeping can tell
    /// Sapling's runners from any others in the repo.
    public static let runnerNamePrefix = "sap-"

    /// How long to leave a locally failed job alone before offering it again.
    ///
    /// Long enough that a job failing immediately — a missing base image, say —
    /// retries at a sane rate rather than every poll cycle.
    static let requeueCooldown: TimeInterval = 120

    /// How many times this node will start any one job before giving up.
    ///
    /// Requeueing had no ceiling, so a job GitHub keeps reporting as queued —
    /// against a base image that will never boot, say — was retried every
    /// cooldown until GitHub's own timeout hours later, cloning a VM each
    /// time. Three attempts is enough to ride out something transient and few
    /// enough to stop a broken node burning a morning.
    static let maxJobAttempts = 3

    /// How many times to ask GitHub for a job's conclusion before giving up on getting one.
    ///
    /// GitHub records the result a moment after the runner exits, so a single immediate check races that.
    let conclusionAttempts: Int
    /// Gap between those attempts.
    let conclusionRetryDelay: Duration

    /// Defaults for the two above, used everywhere except tests that would
    /// otherwise spend fifteen seconds waiting for a fake to say "no".
    static let defaultConclusionAttempts = 5
    static let defaultConclusionRetryDelay: Duration = .seconds(3)

    /// How long to keep asking while GitHub still has the job *in progress*.
    ///
    /// The runner exiting is not the job ending: post-steps and log upload run
    /// after it, and GitHub records the conclusion after those. Five attempts
    /// three seconds apart gave that fifteen seconds, which was not enough —
    /// jobs GitHub had concluded were filed here as "runner exited without the
    /// job completing", inflating the node's failure count with work that had
    /// in fact finished. Only spent when GitHub says the job is still going, so
    /// a genuinely absent answer still costs fifteen seconds.
    static let inProgressGrace: Duration = .seconds(180)

    /// Samples the hardware, so the UI can show what the node is doing.
    public let metrics = MetricsCollector()
    /// Samples each running job's own VM or container, against its limits.
    ///
    /// The node-wide meters say the machine is under pressure; these say which
    /// job is doing it.
    public let jobStats = JobStatsCollector()

    var pollTask: Task<Void, Never>?
    var metricsTask: Task<Void, Never>?
    var jobStatsTask: Task<Void, Never>?
    var housekeepingTask: Task<Void, Never>?
    var runningJobs: [String: Task<Void, Never>] = [:]
    /// Runner names minted for jobs that are still starting or running.
    ///
    /// Housekeeping sweeps offline runners to clear ones a crashed VM left
    /// behind, and a JIT runner that has been created but has not connected
    /// yet looks exactly like one of those. Without this it deleted runners it
    /// had minted seconds earlier.
    var inFlightRunners: Set<String> = []
    /// Runs already refused on provenance and already logged.
    ///
    /// Keyed `repo#runID`, and rebuilt each poll from what GitHub still has
    /// queued, so it cannot grow without bound on a busy public repository.
    var refusedForkRuns: Set<String> = []
    /// How many runs have been refused on provenance since the daemon started.
    var forkRunsRefused = 0
    var networkGuardApplied = false

    /// Creates an agent for the given configuration and store.
    ///
    /// - Parameters:
    ///   - config: The configuration to run with.
    ///   - store: Where job and node state is recorded.
    ///   - configURL: The file `config` came from, re-read on reload.
    public init(
        config: SaplingConfig,
        store: SaplingStore,
        configURL: URL = SaplingPaths.configFile
    ) {
        self.init(
            config: config,
            store: store,
            configURL: configURL,
            macProvider: config.macos.enabled ? TartProvider(config: config.macos) : nil,
            linuxProvider: config.linux.enabled ? ContainerProvider(config: config.linux) : nil
        )
    }

    /// Creates an agent with providers supplied directly.
    ///
    /// Exists so the cancellation path can be tested. Cancelling a running job
    /// is the one behaviour here that cannot be checked on the machine it
    /// matters on without burning two hours of real slot time, so it is worth
    /// a seam that lets a fake provider stand in for a VM.
    init(
        config: SaplingConfig,
        store: SaplingStore,
        configURL: URL = SaplingPaths.configFile,
        macProvider: (any JobProvider)?,
        linuxProvider: (any JobProvider)?,
        conclusionAttempts: Int = NodeAgent.defaultConclusionAttempts,
        conclusionRetryDelay: Duration = NodeAgent.defaultConclusionRetryDelay
    ) {
        self.conclusionAttempts = conclusionAttempts
        self.conclusionRetryDelay = conclusionRetryDelay
        self.config = config
        self.configURL = configURL
        self.store = store
        self.github = GitHubClient(config: config.github)
        self.macProvider = macProvider
        self.linuxProvider = linuxProvider
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
        metricsTask = Task { [weak self] in await self?.metrics.run() }
        jobStatsTask = Task { [weak self] in await self?.jobStats.run() }
        housekeepingTask = Task { [weak self] in await self?.housekeepingLoop() }
        let watching = await watchedRepos()
        Log.info(
            "node agent started as \(nodeID) — watching "
                + (watching.isEmpty ? "nothing yet" : watching.joined(separator: ", "))
                + (config.github.repos.isEmpty ? " (from the App installation)" : ""))
    }

    /// Stops polling, cancels running jobs, and marks the node offline.
    public func stop() async {
        pollTask?.cancel()
        metricsTask?.cancel()
        jobStatsTask?.cancel()
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
