import Foundation

/// The `[network]` section: what job environments are allowed to reach.
public struct NetworkConfig: Codable, Sendable {
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
    /// Both Tart and Apple's `container` use vmnet's shared range by default.
    /// Any bridge that is up gets merged in on top of this.
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
        jobSubnets: [String] = ["192.168.64.0/24"]
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
        jobSubnets = try c.decodeIfPresent([String].self, forKey: .jobSubnets) ?? ["192.168.64.0/24"]
    }
}

/// The `[cache]` section: the host-side pull-through package caches.
public struct CacheConfig: Codable, Sendable {
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
