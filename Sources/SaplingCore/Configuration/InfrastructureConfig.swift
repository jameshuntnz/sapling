import Foundation

/// The `[network]` section: what job environments are allowed to reach.
public struct NetworkConfig: Codable, Sendable {
    /// The subnets vmnet allocates for VM and container networking.
    ///
    /// Eight is well beyond what a two-macOS-slot node will use, and each
    /// unused entry is a table row that never matches.
    public static let defaultJobSubnets = (64...71).map { "192.168.\($0).0/24" }

    /// §8: a compromised job should reach the internet but not the LAN.
    ///
    /// The Mac mini also hosts deployment infrastructure, so this defaults on and
    /// the daemon refuses to start jobs if enforcement can't be applied.
    public var blockPrivateRanges: Bool
    /// Additional ranges to deny, on top of the built-in private ranges.
    public var extraBlockedCIDRs: [String]
    /// Escape hatch for a specific host a job legitimately needs (a local
    /// registry mirror, say).
    ///
    /// Takes precedence over the blocked ranges.
    public var allowedCIDRs: [String]
    /// Subnets that job environments live on.
    ///
    /// Declared rather than discovered: the host bridge only exists while a VM
    /// or container is actually running, so waiting to observe one would leave
    /// the filter absent at exactly the moment a job's traffic starts flowing.
    ///
    /// vmnet hands out `192.168.64.0/24`, then `.65`, `.66` and upward as more
    /// networks come up, and which provider lands on which is not fixed —
    /// Apple's `container` and Tart routinely differ, and differ again across
    /// reboots. So the default covers the range vmnet allocates from rather
    /// than a single subnet; a subnet with no interface behind it costs
    /// nothing in pf. Any bridge that is up gets merged in on top.
    public var jobSubnets: [String]

    enum CodingKeys: String, CodingKey {
        case blockPrivateRanges = "block_private_ranges"
        case extraBlockedCIDRs = "extra_blocked_cidrs"
        case allowedCIDRs = "allowed_cidrs"
        case jobSubnets = "job_subnets"
    }

    /// Creates an infrastructure configuration.
    public init(
        blockPrivateRanges: Bool = true,
        extraBlockedCIDRs: [String] = [],
        allowedCIDRs: [String] = [],
        jobSubnets: [String] = NetworkConfig.defaultJobSubnets
    ) {
        self.blockPrivateRanges = blockPrivateRanges
        self.extraBlockedCIDRs = extraBlockedCIDRs
        self.allowedCIDRs = allowedCIDRs
        self.jobSubnets = jobSubnets
    }

    /// Creates an infrastructure configuration.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        blockPrivateRanges = try c.decodeIfPresent(Bool.self, forKey: .blockPrivateRanges) ?? true
        extraBlockedCIDRs = try c.decodeIfPresent([String].self, forKey: .extraBlockedCIDRs) ?? []
        allowedCIDRs = try c.decodeIfPresent([String].self, forKey: .allowedCIDRs) ?? []
        jobSubnets = try c.decodeIfPresent([String].self, forKey: .jobSubnets) ?? Self.defaultJobSubnets
    }
}

/// The `[cache]` section: the host-side pull-through package caches.
public struct CacheConfig: Codable, Sendable {
    /// Path the proxy answers on to prove it is listening on an address.
    ///
    /// A job environment resolves its own gateway and asks here before
    /// exporting any cache variables: a `GOPROXY` pointing at an address
    /// nothing answers on is worse than no `GOPROXY` at all.
    public static let healthPath = "_sapling/health"

    /// Whether to run the cache proxy at all.
    public var enabled: Bool
    /// Port the cache proxy listens on, bound to the VM bridge gateway.
    public var port: Int
    /// Which pull-through proxies to run.
    ///
    /// See §12 — starting with Go and Cargo follows ephemerd's precedent; npm/pip
    /// are wired but off by default until there's a real workload asking for
    /// them.
    public var proxies: [String]
    /// Size ceiling; least-recently-used entries are pruned past it.
    public var maxSizeGB: Int

    enum CodingKeys: String, CodingKey {
        case enabled, port, proxies
        case maxSizeGB = "max_size_gb"
    }

    /// Creates an infrastructure configuration.
    public init(
        enabled: Bool = true, port: Int = 8735, proxies: [String] = ["go", "cargo"], maxSizeGB: Int = 20
    ) {
        self.enabled = enabled
        self.port = port
        self.proxies = proxies
        self.maxSizeGB = maxSizeGB
    }

    /// Creates an infrastructure configuration.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        port = try c.decodeIfPresent(Int.self, forKey: .port) ?? 8735
        proxies = try c.decodeIfPresent([String].self, forKey: .proxies) ?? ["go", "cargo"]
        maxSizeGB = try c.decodeIfPresent(Int.self, forKey: .maxSizeGB) ?? 20
    }
}

/// The `[update]` section: where the daemon looks for new versions of itself.
public struct UpdateConfig: Codable, Sendable {
    /// Repository publishing Sapling's releases, as `owner/repo`.
    public var repository: String
    /// Which release stream this node follows.
    ///
    /// A node on `stable` ignores rc and dev builds entirely; one on `dev`
    /// takes whatever is newest. Derived from each release's own version, so
    /// a release mislabelled in GitHub's UI cannot put a dev build on a
    /// production node.
    public var channel: ReleaseChannel
    /// How often to look for a new version.
    ///
    /// Zero disables checking.
    public var checkIntervalHours: Int
    /// Install a new version as soon as one is found.
    ///
    /// Off by default. Even when on, an update is only applied while the node
    /// is idle — replacing the daemon mid-job would orphan a running VM.
    public var autoApply: Bool

    enum CodingKeys: String, CodingKey {
        case repository, channel
        case checkIntervalHours = "check_interval_hours"
        case autoApply = "auto_apply"
    }

    /// Creates an update configuration.
    public init(
        repository: String = "jameshuntnz/sapling",
        channel: ReleaseChannel = .stable,
        checkIntervalHours: Int = 6,
        autoApply: Bool = false
    ) {
        self.repository = repository
        self.channel = channel
        self.checkIntervalHours = checkIntervalHours
        self.autoApply = autoApply
    }

    /// Reads an update configuration, defaulting anything absent.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        repository = try c.decodeIfPresent(String.self, forKey: .repository) ?? "jameshuntnz/sapling"
        channel = try c.decodeIfPresent(ReleaseChannel.self, forKey: .channel) ?? .stable
        checkIntervalHours = try c.decodeIfPresent(Int.self, forKey: .checkIntervalHours) ?? 6
        autoApply = try c.decodeIfPresent(Bool.self, forKey: .autoApply) ?? false
    }
}
