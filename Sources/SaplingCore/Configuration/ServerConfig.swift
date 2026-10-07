import Foundation

/// Which interface the control-plane API listens on.
public enum BindMode: Sendable, Equatable {
    case tailscale
    case loopback
    case explicit(String)
    case all

    /// The value as it appears in `config.toml`.
    public var rawValue: String {
        switch self {
        case .tailscale: "tailscale"
        case .loopback: "loopback"
        case .all: "all"
        case .explicit(let address): address
        }
    }

    /// Creates a server configuration.
    public init(rawValue: String) {
        switch rawValue.lowercased() {
        case "tailscale", "auto": self = .tailscale
        case "loopback", "localhost", "127.0.0.1": self = .loopback
        case "all", "0.0.0.0", "*": self = .all
        default: self = .explicit(rawValue)
        }
    }
}

/// The `[node]` section: how this machine identifies itself.
public struct NodeConfig: Codable, Sendable {
    /// Human-readable node name, also the basis of its stable id.
    public var name: String

    /// Run one platform at a time, whatever the per-platform slot counts say.
    ///
    /// **Off**, and it should stay off. Measured on a freshly rebooted node,
    /// three times: a container and a macOS VM started in the same instant
    /// both attach within three seconds — `bridge100` to the container,
    /// `bridge101` to the VM — and the VM has an address in nine. Concurrency
    /// works. A full PR check runs both platforms through it cleanly.
    ///
    /// Turning this on was a wrong turn worth recording. Every observed
    /// failure had a container and a VM running together, so simultaneity
    /// looked like the cause; it is not. The failures all happened on a node
    /// that had been up for hours, and the variable is uptime, not
    /// concurrency. Serialising traded away half the node's throughput to
    /// avoid a fault it does not prevent.
    ///
    /// Kept as a lever for an operator with a node misbehaving in a way
    /// nobody has diagnosed yet — not as a default, and not as a fix.
    public var serializePlatforms: Bool

    /// Ceiling on jobs running at once across *both* platforms.
    ///
    /// The per-platform `max_concurrent` values say what each platform may run;
    /// this says what the machine may run in total, and the two are enforced
    /// together. Set it to 2 on a node with two macOS slots and two Linux slots
    /// and any mix is allowed — two VMs, two containers, or one of each — but
    /// never three environments competing for the same RAM.
    ///
    /// This exists because RAM is the shared resource and the per-platform
    /// counts cannot express that. Sizing each platform to fit alone is how a
    /// machine ends up over-committed the moment both are busy: every half
    /// looks reasonable and the total does not fit.
    ///
    /// `nil` leaves the node uncapped, so the per-platform counts alone decide.
    public var maxConcurrent: Int?

    /// RAM to keep for the host, in GB: macOS, the daemon, the container system.
    ///
    /// Everything above this is the job budget, and admission stops when the
    /// next job's memory would cross it. Kept configurable because the right
    /// figure is a property of the machine — a node doing nothing else needs
    /// less than one that is also somebody's desktop.
    ///
    /// Two, not the four it once was: the four was quietly absorbing part of
    /// what each environment costs beyond its guest, and that is now charged
    /// per environment by `environmentOverheadGB` instead. The host itself is
    /// small — the daemon measured 39MB.
    public var memoryReserveGB: Int

    /// What each running environment costs the host beyond its guest, in GB.
    ///
    /// Charged on top of every job's size, because the host pays it whether or
    /// not anyone counts it. Measured on a 16GB node: a Tart VM's resident size
    /// is its guest plus 2.1–2.2GB from boot, and a `container` job given 3GB
    /// sat at 4.96GB. Charging only the guest booked a 6GB VM beside a 6GB
    /// container as 12GB against a 12GB budget while the machine paid about
    /// 16GB, and an iOS release that takes eight minutes alone took twenty.
    public var environmentOverheadGB: Int

    /// Job memory budget in GB, stated outright instead of derived.
    ///
    /// Set this when the machine's total is the wrong basis: a node sharing the
    /// host with something else, or a build agent whose RAM says nothing about
    /// what it should hand to jobs. `nil` derives it from physical memory.
    ///
    /// It also keeps the scheduler testable. Deriving the budget from
    /// `ProcessInfo.physicalMemory` made admission a property of whichever
    /// machine ran the suite — green on a 32GB laptop, red in a 6GB CI VM,
    /// with the code identical.
    public var memoryBudgetOverrideGB: Int?

    /// Memory available to jobs on a machine of this size, in GB.
    ///
    /// - Parameter totalGB: The machine's physical memory.
    /// - Returns: What jobs may collectively hold, never negative.
    public func memoryBudgetGB(totalGB: Int) -> Int {
        if let memoryBudgetOverrideGB { return max(0, memoryBudgetOverrideGB) }
        return max(0, totalGB - memoryReserveGB)
    }

    /// What a job of this size is charged against the budget, in GB.
    ///
    /// - Parameter memoryGB: The guest size the job runs with.
    /// - Returns: That size plus the environment's own overhead.
    public func chargeGB(memoryGB: Int) -> Int {
        memoryGB + max(0, environmentOverheadGB)
    }

    /// Jobs this node will run at once, after clamping.
    ///
    /// Falls back to the sum of the platform ceilings, which is the uncapped
    /// behaviour a node has when `max_concurrent` is absent.
    public func effectiveMaxConcurrent(macOS: Int, linux: Int) -> Int {
        guard let maxConcurrent else { return macOS + linux }
        return max(0, min(maxConcurrent, macOS + linux))
    }

    enum CodingKeys: String, CodingKey {
        case name
        case serializePlatforms = "serialize_platforms"
        case maxConcurrent = "max_concurrent"
        case memoryReserveGB = "memory_reserve_gb"
        case memoryBudgetOverrideGB = "memory_budget_gb"
        case environmentOverheadGB = "environment_overhead_gb"
    }

    /// Creates a server configuration.
    public init(
        name: String = Host.current().localizedName ?? "sapling-node",
        serializePlatforms: Bool = false,
        maxConcurrent: Int? = nil,
        memoryReserveGB: Int = 2,
        memoryBudgetOverrideGB: Int? = nil,
        environmentOverheadGB: Int = 2
    ) {
        self.name = name
        self.serializePlatforms = serializePlatforms
        self.maxConcurrent = maxConcurrent
        self.memoryReserveGB = memoryReserveGB
        self.memoryBudgetOverrideGB = memoryBudgetOverrideGB
        self.environmentOverheadGB = environmentOverheadGB
    }

    /// Creates a server configuration.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name =
            try c.decodeIfPresent(String.self, forKey: .name)
            ?? Host.current().localizedName
            ?? "sapling-node"
        serializePlatforms = try c.decodeIfPresent(Bool.self, forKey: .serializePlatforms) ?? false
        maxConcurrent = try c.decodeIfPresent(Int.self, forKey: .maxConcurrent)
        memoryReserveGB = try c.decodeIfPresent(Int.self, forKey: .memoryReserveGB) ?? 2
        memoryBudgetOverrideGB = try c.decodeIfPresent(Int.self, forKey: .memoryBudgetOverrideGB)
        environmentOverheadGB = try c.decodeIfPresent(Int.self, forKey: .environmentOverheadGB) ?? 2
    }
}

/// The `[server]` section: where the control-plane API listens.
public struct ServerConfig: Codable, Sendable {
    /// Bind mode as written in the config file.
    public var bind: String
    /// Port the API listens on.
    public var port: Int

    /// The parsed form of `bind`.
    public var bindMode: BindMode { BindMode(rawValue: bind) }

    enum CodingKeys: String, CodingKey { case bind, port }

    /// Creates a server configuration.
    public init(bind: String = "tailscale", port: Int = 8734) {
        self.bind = bind
        self.port = port
    }

    /// Creates a server configuration.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        bind = try c.decodeIfPresent(String.self, forKey: .bind) ?? "tailscale"
        port = try c.decodeIfPresent(Int.self, forKey: .port) ?? 8734
    }
}
