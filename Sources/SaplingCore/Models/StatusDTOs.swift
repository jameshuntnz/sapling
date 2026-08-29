import Foundation

// What `GET /api/v1/status` answers with: what the node is, what it is
// holding, and what it has turned away.

/// Slot accounting for one platform.
///
/// `capacity` for macOS is hard-capped at 2 by Apple's virtualization
/// licensing and is not configurable upward.
public struct SlotUsage: Codable, Sendable, Hashable {
    /// Which platform these slots belong to.
    public var platform: JobPlatform
    /// How many slots currently hold a job.
    public var inUse: Int
    /// How many slots exist, after clamping to any hard limit.
    public var capacity: Int

    /// Creates a slot usage summary.
    public init(platform: JobPlatform, inUse: Int, capacity: Int) {
        self.platform = platform
        self.inUse = inUse
        self.capacity = capacity
    }

    /// Free slots, never negative.
    ///
    /// Clamped so a stale count can't report phantom capacity.
    public var available: Int { max(0, capacity - inUse) }
}

/// Response body for `GET /api/v1/status`.
public struct StatusResponse: Codable, Sendable {
    /// Daemon version, so a client can spot a version mismatch.
    public var version: String
    /// The node this control plane manages.
    public var node: Node
    /// Slot usage, one entry per platform.
    ///
    /// Each entry's `capacity` is that platform's own ceiling. When
    /// `nodeCapacity` is lower than their sum the platforms share one pool, so
    /// the entries describe what each *may* run rather than what can run at
    /// once — read `nodeCapacity` for the machine's real limit.
    public var slots: [SlotUsage]
    /// Jobs this node runs at once across both platforms.
    ///
    /// Reported separately because the per-platform capacities can sum to more
    /// than the machine allows: with two macOS slots, two Linux slots and a
    /// node cap of two, any mix runs but never more than two at a time.
    public var nodeCapacity: Int
    /// Memory jobs may collectively hold on this node, in GB.
    ///
    /// The limit that actually decides what starts. Slot counts bound what
    /// memory cannot see — disk, CPU, the container system's own ceilings — so
    /// a node can be half-idle by slot and completely full by memory, which is
    /// the state a reader most needs told.
    public var memoryBudgetGB: Int
    /// Memory reserved by jobs currently holding a slot, in GB.
    public var committedMemoryGB: Int

    /// Memory not yet promised to a job, in GB.
    public var freeMemoryGB: Int { max(0, memoryBudgetGB - committedMemoryGB) }
    /// Jobs discovered but not yet started.
    public var queuedJobs: Int
    /// Jobs currently holding a slot.
    public var runningJobs: Int
    /// Jobs that finished successfully in the last 24 hours.
    public var completedLast24h: Int
    /// Jobs that failed in the last 24 hours.
    public var failedLast24h: Int
    /// Jobs GitHub cancelled in the last 24 hours.
    ///
    /// Counted apart from failures because they are not the node's doing, and
    /// folding them together makes a working node look like a broken one.
    public var cancelledLast24h: Int
    /// Repositories being polled, in `owner/repo` form.
    public var watchedRepos: [String]
    /// When GitHub was last polled successfully.
    public var lastPollAt: Date?
    /// Why the last poll failed, if it did.
    public var lastPollError: String?
    /// Workflow runs refused since the daemon started because their code came
    /// from a fork rather than from the repository being watched.
    public var forkRunsRefused: Int
    /// What the hardware is doing, when the node is reporting it.
    public var metrics: NodeMetrics?

    /// Creates a status summary.
    public init(
        version: String,
        node: Node,
        slots: [SlotUsage],
        nodeCapacity: Int = 0,
        memoryBudgetGB: Int = 0,
        committedMemoryGB: Int = 0,
        queuedJobs: Int,
        runningJobs: Int,
        completedLast24h: Int,
        failedLast24h: Int,
        cancelledLast24h: Int = 0,
        watchedRepos: [String],
        lastPollAt: Date?,
        lastPollError: String?,
        forkRunsRefused: Int = 0,
        metrics: NodeMetrics? = nil
    ) {
        self.version = version
        self.node = node
        self.slots = slots
        self.nodeCapacity = nodeCapacity
        self.memoryBudgetGB = memoryBudgetGB
        self.committedMemoryGB = committedMemoryGB
        self.queuedJobs = queuedJobs
        self.runningJobs = runningJobs
        self.completedLast24h = completedLast24h
        self.failedLast24h = failedLast24h
        self.cancelledLast24h = cancelledLast24h
        self.watchedRepos = watchedRepos
        self.lastPollAt = lastPollAt
        self.lastPollError = lastPollError
        self.forkRunsRefused = forkRunsRefused
        self.metrics = metrics
    }
}
