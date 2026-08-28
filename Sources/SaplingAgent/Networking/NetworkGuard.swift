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
    ]

    let config: NetworkConfig

    /// Creates a guard for the given network configuration.
    public init(config: NetworkConfig) {
        self.config = config
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
        // The bridge gateway has to stay reachable or the VM loses DHCP, DNS,
        // and the host cache proxy along with its internet access.
        let allowed = gateways + config.allowedCIDRs

        let rules = Self.anchorRules(jobnets: jobnetEntries, allowed: allowed, blocked: blocked)

        // Serialised, because this runs before every job and two jobs
        // dispatched in the same poll cycle run it at once. See `AnchorWriter`
        // for what two unsynchronised callers do to a pf anchor.
        try await AnchorWriter.shared.load(
            rules: rules, path: Self.anchorPath, anchor: Self.anchorName)

        return Applied(jobSubnets: jobSubnets, gateways: gateways, blocked: blocked, allowed: allowed)
    }

    /// The anchor's contents, for a given set of tables.
    ///
    /// Split out because `AnchorWriter` skips a reload when the rules match
    /// what is already loaded, and that is only safe if identical inputs
    /// produce an identical string — two jobs starting together compute this
    /// independently, and a difference of one space would have them reloading
    /// over each other forever.
    static func anchorRules(jobnets: [String], allowed: [String], blocked: [String]) -> String {
        """
        # Generated by sapling \(SaplingVersion.current). Do not edit;
        # `sapling serve` rewrites this file on every start.
        table <sapling_jobnets> { \(jobnets.joined(separator: ", ")) }
        table <sapling_allowed> { \(allowed.joined(separator: ", ")) }
        table <sapling_blocked> { \(blocked.joined(separator: ", ")) }

        pass quick from <sapling_jobnets> to <sapling_allowed>
        block drop quick from <sapling_jobnets> to <sapling_blocked>

        """
    }

    /// What pf actually has loaded — or the fact that we could not find out.
    ///
    /// The third case is the point. `pfctl -sr` needs root and the CLI is not,
    /// so `sapling doctor` used to print "anchor wired; rules are written when
    /// the first job starts" whether the rules were loaded, absent, or
    /// unreadable. Reporting green on an unknown is worse than reporting
    /// nothing: it was still saying `ok` throughout an outage.
    public enum AnchorState: Sendable {
        /// The anchor is loaded and carries a block rule.
        case loaded([String])
        /// pf answered, and the anchor has no block rule in it.
        case empty
        /// pf could not be read, with the reason.
        case unverifiable(String)

        /// Whether the filter is known to be in force.
        public var isLoaded: Bool { if case .loaded = self { true } else { false } }
    }

    /// Read back what pf actually has loaded, rather than trusting that our
    /// write succeeded. `sapling doctor` uses this.
    public static func verify() async -> AnchorState {
        guard getuid() == 0 else {
            return .unverifiable("`pfctl -sr` needs root; run `sudo sapling doctor` to check the rules")
        }
        guard
            let result = try? await ProcessRunner.run(
                "pfctl", ["-a", anchorName, "-sr"], timeout: .seconds(20)),
            result.succeeded
        else {
            return .unverifiable("`pfctl -a \(anchorName) -sr` failed")
        }
        let rules = result.stdout
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        // An anchor that exists but has no block rule is worse than none at
        // all, because it looks configured.
        return rules.contains { $0.hasPrefix("block") } ? .loaded(rules) : .empty
    }

    /// Removes Sapling's rules from pf, leaving the anchor in place.
    public static func flush() async {
        _ = try? await ProcessRunner.run("pfctl", ["-a", anchorName, "-F", "rules"], timeout: .seconds(20))
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
        }
    }
}
