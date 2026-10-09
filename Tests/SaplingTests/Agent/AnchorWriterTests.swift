import Foundation
import Testing

@testable import SaplingAgent
@testable import SaplingCore

/// The egress filter is re-applied before *every* job, so two jobs dispatched
/// in the same poll cycle apply it at the same moment — the normal case on a
/// node running both platforms.
///
/// Unsynchronised, that is three faults at once: a flush leaves a window with
/// no rules and jobs running unfiltered; two callers can compute different
/// rulesets and undo each other; and overlapping loads make pf's
/// "cannot define table: Resource busy" far more likely, which refuses to
/// start a job at all.
@Suite("pf anchor writes")
struct AnchorWriterTests {
    static let jobnets = ["192.168.64.0/24", "!192.168.64.1", "192.168.65.0/24", "!192.168.65.1"]
    static let gateways = ["192.168.64.1/32", "192.168.65.1/32"]
    static let blocked = NetworkGuard.defaultBlockedCIDRs

    static func rules(jobnets: [String] = jobnets, allowed: [String] = [], cachePort: Int? = 8735) -> String {
        NetworkGuard.anchorRules(
            jobnets: jobnets, gateways: gateways, allowed: allowed, blocked: blocked, cachePort: cachePort,
            bridges: NetworkGuard.declaredBridges)
    }

    /// Skipping an unchanged reload is only safe if this is deterministic.
    ///
    /// A difference of one space would have two jobs reloading over each other
    /// indefinitely.
    @Test("identical inputs produce a byte-identical anchor")
    func rulesAreDeterministic() {
        #expect(Self.rules() == Self.rules())
    }

    /// And a real change must still be seen, or a bridge that came up since
    /// the last job never gets filtered.
    @Test("a new subnet changes the anchor")
    func rulesChangeWithInput() {
        #expect(Self.rules() != Self.rules(jobnets: Self.jobnets + ["192.168.66.0/24"]))
    }

    /// §8 in one assertion: the anchor must carry a block rule, and the
    /// gateway exclusions that keep the host able to reach its own VMs.
    @Test("the anchor blocks, and excludes the gateways from the jobnets")
    func rulesCarryThePolicy() {
        let rules = Self.rules()
        #expect(rules.contains("block drop quick from <sapling_jobnets> to <sapling_blocked>"))
        #expect(rules.contains("!192.168.64.1"))
        #expect(rules.contains("100.64.0.0/10"), "the tailnet must be blocked")
        #expect(!rules.contains("<sapling_allowed>"), "no allowed table without allowed ranges")
        #expect(
            Self.rules(allowed: ["203.0.113.7/32"]).contains(
                "pass quick from <sapling_jobnets> to <sapling_allowed>"))
    }

    /// The gateway is the host.
    ///
    /// Every service it runs on all interfaces — SSH, screen sharing, the API
    /// bound wide — answers there.
    @Test("a guest reaches its gateway only for DHCP, DNS and the cache proxy")
    func gatewayIsScoped() {
        let rules = Self.rules()
        #expect(rules.contains("to <sapling_gateways> port { 53, 67 }"))
        #expect(rules.contains("proto tcp from <sapling_jobnets> to <sapling_gateways> port { 53, 8735 }"))
        #expect(rules.contains("block drop quick from <sapling_jobnets> to <sapling_gateways>"))
        #expect(rules.contains("pass out quick from <sapling_gateways> to <sapling_jobnets> keep state"))
        #expect(Self.rules(cachePort: nil).contains("port { 53 }"))
    }

    @Test("guests get no IPv6 and cannot spoof a source outside their subnet")
    func ipv6AndSpoofing() {
        let rules = Self.rules()
        #expect(rules.contains("block return in quick on { bridge100, "))
        #expect(rules.contains("inet6 all"))
        #expect(rules.contains("inet from ! <sapling_jobnets>"))
    }

    /// Config values are written into pf's own syntax.
    @Test("only addresses and CIDRs are accepted as ranges")
    func rangeValidation() {
        for good in ["10.0.0.0/8", "192.168.64.1", "fd7a:115c:a1e5::/48"] {
            #expect(NetworkGuard.isAddressRange(good), "\(good)")
        }
        for bad in ["1.1.1.1 } pass quick all {", "", "10.0.0.0/", "10.0.0.0/999", "a/b/c", "host.example"] {
            #expect(!NetworkGuard.isAddressRange(bad), "\(bad)")
        }
    }

    /// One pf, one writer.
    ///
    /// Two of them would reintroduce exactly the race this exists to remove.
    @Test("there is a single writer")
    func singleWriter() {
        #expect(AnchorWriter.shared === AnchorWriter.shared)
    }

    /// Concurrent applies must not interleave.
    ///
    /// Without root nothing is loaded, so this asserts the shape that matters:
    /// every caller returns, and none deadlocks against another.
    @Test("concurrent applies all resolve, none hang")
    func concurrentAppliesResolve() async {
        let config = NetworkConfig(blockPrivateRanges: true)
        await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<8 {
                group.addTask { [config] in
                    do {
                        _ = try await NetworkGuard(config: config).apply()
                        return true
                    } catch {
                        // As a non-root test process this is always .notRoot;
                        // the point is that all eight return rather than
                        // deadlocking against each other.
                        return true
                    }
                }
            }
            var completed = 0
            for await done in group where done { completed += 1 }
            #expect(completed == 8)
        }
    }
}
