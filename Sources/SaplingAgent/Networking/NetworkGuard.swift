import Foundation
import SaplingCore

/// Default-deny egress from job environments to private address space (§8).
///
/// Jobs run trusted-but-not-audited code on a machine that also hosts
/// deployment infrastructure, so the property that matters is: a job can
/// reach the internet, and nothing else on the LAN, the tailnet, or the
/// host's own services.
///
/// Enforcement is a pf anchor. macOS's Virtualization.framework NAT routes
/// both Tart VM traffic and Apple `container` traffic through the host's IP
/// stack via `bridge*` interfaces, so pf on the host is the one place that
/// sees all of it.
public struct NetworkGuard: Sendable {
    /// Name of the pf anchor Sapling's rules live in.
    public static let anchorName = "sapling"
    /// Where the anchor's rule file is written.
    public static let anchorPath = "/etc/pf.anchors/sapling"

    /// Everything a job must not reach.
    ///
    /// CGNAT space (100.64/10) is in here deliberately — that's Tailscale, and a
    /// job has no business talking to the tailnet.
    public static let defaultBlockedCIDRs = [
        "10.0.0.0/8",
        "172.16.0.0/12",
        "192.168.0.0/16",
        "169.254.0.0/16",
        "100.64.0.0/10",
        "127.0.0.0/8",
        "0.0.0.0/8",
        "192.0.0.0/24",
        "198.18.0.0/15",
        "224.0.0.0/4",
        "240.0.0.0/4",
    ]

    /// Bridges named whether or not they are up yet, so guest IPv6 is refused
    /// from the first packet: vmnet numbers them from `bridge100`.
    static let declaredBridges = (100...107).map { "bridge\($0)" }

    let config: NetworkConfig
    let cachePort: Int?

    /// Creates a guard for the given network configuration.
    ///
    /// - Parameters:
    ///   - config: The `[network]` section.
    ///   - cachePort: The host cache proxy's port, which guests may reach on
    ///     their gateway, or nil when the proxy is off.
    public init(config: NetworkConfig, cachePort: Int? = nil) {
        self.config = config
        self.cachePort = cachePort
    }

    /// Creates the guard a node's configuration calls for.
    public init(node config: SaplingConfig) {
        self.init(config: config.network, cachePort: config.cache.enabled ? config.cache.port : nil)
    }

    /// What was actually loaded into pf, for logging and diagnostics.
    public struct Applied: Sendable {
        /// Subnets job environments live on.
        public let jobSubnets: [String]
        /// Bridge gateway addresses, which stay reachable.
        public let gateways: [String]
        /// Ranges job environments are denied.
        public let blocked: [String]
        /// Ranges permitted despite the block rules.
        public let allowed: [String]
    }

    /// Build and load the anchor.
    ///
    /// Requires root, which the daemon has as a LaunchDaemon (§10).
    @discardableResult
    public func apply() async throws -> Applied {
        guard config.blockPrivateRanges else {
            throw NetworkGuardError.disabled
        }
        guard getuid() == 0 else {
            throw NetworkGuardError.notRoot
        }

        // Declared subnets first, then whatever is currently up. The bridge is
        // torn down whenever no environment is running, so discovery alone
        // would leave the filter absent at the moment a job starts.
        let bridges = (try? await BridgeTable.current()) ?? []

        // Unioned with the built-in defaults, never replaced by config.
        //
        // `sapling install` writes every field to config.toml, defaults
        // included, which freezes them: a node installed when the default was
        // a single subnet kept that single subnet after the default widened,
        // and the improvement never arrived. That left macOS VMs — which vmnet
        // puts on a different subnet than containers — entirely unfiltered,
        // while the rules looked correct.
        //
        // For a security control the rule is that a stale config may add
        // coverage but never subtract it.
        let configured = config.jobSubnets + config.extraBlockedCIDRs + config.allowedCIDRs
        if let bad = configured.first(where: { !Self.isAddressRange($0) }) {
            throw NetworkGuardError.invalidRange(bad)
        }
        let gatewayPorts = try Self.gatewayPorts(config.gatewayTCPPorts)
        var jobSubnets = Array(Set(config.jobSubnets).union(NetworkConfig.defaultJobSubnets)).sorted()
        var gateways = jobSubnets.compactMap(BridgeTable.gatewayCIDR(forSubnet:))
        for bridge in bridges where !jobSubnets.contains(bridge.subnet) {
            jobSubnets.append(bridge.subnet)
            gateways.append("\(bridge.address)/32")
        }
        guard !jobSubnets.isEmpty else {
            throw NetworkGuardError.noJobNetworks
        }
        // Each subnet, with its gateway explicitly excluded.
        //
        // The gateway is the *host's* address on that bridge, so it falls
        // inside the subnet — and without the exclusion the host's own traffic
        // to a VM matches "from <jobnets> to <blocked>" and is dropped. The
        // symptom is the agent unable to SSH into the VM it just booted, which
        // reads as a broken base image and is not.
        let jobnetEntries = jobSubnets.flatMap { subnet -> [String] in
            guard let gateway = BridgeTable.gatewayCIDR(forSubnet: subnet) else { return [subnet] }
            return [subnet, "!\(gateway.replacingOccurrences(of: "/32", with: ""))"]
        }
        let blocked = Self.defaultBlockedCIDRs + config.extraBlockedCIDRs
        let allowed = config.allowedCIDRs
        let interfaces = Array(Set(Self.declaredBridges + bridges.map(\.name))).sorted()

        let rules = Self.anchorRules(
            jobnets: jobnetEntries, gateways: gateways, allowed: allowed, blocked: blocked,
            cachePort: cachePort, gatewayPorts: gatewayPorts, bridges: interfaces)

        // Serialised, because this runs before every job and two jobs
        // dispatched in the same poll cycle run it at once. See `AnchorWriter`
        // for what two unsynchronised callers do to a pf anchor.
        try await AnchorWriter.shared.load(
            rules: rules, path: Self.anchorPath, anchor: Self.anchorName)

        return Applied(jobSubnets: jobSubnets, gateways: gateways, blocked: blocked, allowed: allowed)
    }

    /// An address or CIDR, and nothing that could close a pf table and open
    /// a rule.
    static func isAddressRange(_ value: String) -> Bool {
        let parts = value.split(separator: "/", omittingEmptySubsequences: false)
        guard (1...2).contains(parts.count), !parts[0].isEmpty else { return false }
        if parts.count == 2 {
            guard let prefix = Int(parts[1]), (0...128).contains(prefix) else { return false }
        }
        return parts[0].allSatisfy { $0.isHexDigit || $0 == "." || $0 == ":" }
    }

    /// Configured gateway ports, checked before they are written into pf.
    ///
    /// SSH is refused outright: blocking it from guests is the point of
    /// scoping the gateway at all.
    static func gatewayPorts(_ ports: [Int]) throws -> [Int] {
        if let bad = ports.first(where: { !(1...65535).contains($0) || $0 == 22 }) {
            throw NetworkGuardError.invalidGatewayPort(bad)
        }
        return ports
    }

    /// The anchor's contents, for a given set of tables.
    ///
    /// Split out because `AnchorWriter` skips a reload when the rules match
    /// what is already loaded, and that is only safe if identical inputs
    /// produce an identical string — two jobs starting together compute this
    /// independently, and a difference of one space would have them reloading
    /// over each other forever.
    static func anchorRules(
        jobnets: [String], gateways: [String], allowed: [String], blocked: [String], cachePort: Int?,
        gatewayPorts: [Int] = [], bridges: [String]
    ) -> String {
        var ports = [53] + (cachePort.map { [$0] } ?? [])
        for port in gatewayPorts where !ports.contains(port) { ports.append(port) }
        let tcpPorts = ports.map(String.init).joined(separator: ", ")
        let onBridges = "on { \(bridges.joined(separator: ", ")) }"
        let allowedRule =
            allowed.isEmpty
            ? ""
            : """
            table <sapling_allowed> { \(allowed.joined(separator: ", ")) }
            pass quick from <sapling_jobnets> to <sapling_allowed>

            """
        return """
            # Generated by sapling \(SaplingVersion.current). Do not edit;
            # `sapling serve` rewrites this file on every start.
            table <sapling_jobnets> { \(jobnets.joined(separator: ", ")) }
            table <sapling_gateways> { \(gateways.joined(separator: ", ")) }
            table <sapling_blocked> { \(blocked.joined(separator: ", ")) }

            # A guest speaks only from its own subnet, so it cannot borrow the
            # gateway's address or one the tables never mention. DHCP starts
            # from no address at all.
            pass in quick \(onBridges) proto udp from 0.0.0.0 port 68 to 255.255.255.255 port 67
            block drop in quick \(onBridges) inet from ! <sapling_jobnets>
            # The host's own connections into a guest, chiefly SSH. Their state
            # carries the replies past the blocks below.
            pass out quick from <sapling_gateways> to <sapling_jobnets> keep state
            # What a guest needs from its gateway, and nothing else the host serves.
            pass quick proto udp from <sapling_jobnets> to <sapling_gateways> port { 53, 67 }
            pass quick proto tcp from <sapling_jobnets> to <sapling_gateways> port { \(tcpPorts) }
            pass quick inet proto icmp from <sapling_jobnets> to <sapling_gateways>
            \(allowedRule)block drop quick from <sapling_jobnets> to <sapling_gateways>
            block drop quick from <sapling_jobnets> to <sapling_blocked>
            # Every rule above is IPv4; a guest gets no IPv6 at all.
            block return in quick \(onBridges) inet6 all

            """
    }
}

/// Why egress filtering could not be applied.
public enum NetworkGuardError: Error, LocalizedError, Sendable {
    /// Filtering is switched off in config.
    case disabled
    /// The process is not root, so pf cannot be written.
    case notRoot
    /// Neither config nor the host offered a subnet to filter.
    case noJobNetworks
    /// pf rejected the anchor, or a command failed.
    case loadFailed(String)
    /// A configured range is not an address or CIDR.
    case invalidRange(String)
    /// A configured gateway port is out of range or is SSH.
    case invalidGatewayPort(Int)

    /// An explanation naming the cause and, where there is one, the fix.
    public var errorDescription: String? {
        switch self {
        case .disabled:
            "network.block_private_ranges is off, so no egress filtering was applied"
        case .notRoot:
            "egress filtering needs root — run the daemon as a LaunchDaemon, not by hand"
        case .noJobNetworks:
            "no bridge interface found yet; it appears once the first VM or container starts"
        case .loadFailed(let detail):
            "could not load the pf anchor: \(detail)"
        case .invalidRange(let value):
            "\"\(value)\" in [network] is not an address or CIDR"
        case .invalidGatewayPort(let port):
            "\(port) in network.gateway_tcp_ports is not allowed: ports are 1–65535, and never 22"
        }
    }
}
