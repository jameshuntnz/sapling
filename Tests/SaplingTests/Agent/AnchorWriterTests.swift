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
    static let allowed = ["192.168.64.1/32", "192.168.65.1/32"]
    static let blocked = NetworkGuard.defaultBlockedCIDRs

    /// Skipping an unchanged reload is only safe if this is deterministic.
    ///
    /// A difference of one space would have two jobs reloading over each other
    /// indefinitely.
    @Test("identical inputs produce a byte-identical anchor")
    func rulesAreDeterministic() {
        let first = NetworkGuard.anchorRules(
            jobnets: Self.jobnets, allowed: Self.allowed, blocked: Self.blocked)
        let second = NetworkGuard.anchorRules(
            jobnets: Self.jobnets, allowed: Self.allowed, blocked: Self.blocked)
        #expect(first == second)
    }

    /// And a real change must still be seen, or a bridge that came up since
    /// the last job never gets filtered.
    @Test("a new subnet changes the anchor")
    func rulesChangeWithInput() {
        let base = NetworkGuard.anchorRules(
            jobnets: Self.jobnets, allowed: Self.allowed, blocked: Self.blocked)
        let widened = NetworkGuard.anchorRules(
            jobnets: Self.jobnets + ["192.168.66.0/24"], allowed: Self.allowed, blocked: Self.blocked)
        #expect(base != widened)
    }

    /// §8 in one assertion: the anchor must carry a block rule, and the
    /// gateway exclusions that keep the host able to reach its own VMs.
    @Test("the anchor blocks, permits the gateways, and excludes them from the jobnets")
    func rulesCarryThePolicy() {
        let rules = NetworkGuard.anchorRules(
            jobnets: Self.jobnets, allowed: Self.allowed, blocked: Self.blocked)
        #expect(rules.contains("block drop quick from <sapling_jobnets> to <sapling_blocked>"))
        #expect(rules.contains("pass quick from <sapling_jobnets> to <sapling_allowed>"))
        #expect(rules.contains("!192.168.64.1"))
        #expect(rules.contains("192.168.64.1/32"))
        #expect(rules.contains("100.64.0.0/10"), "the tailnet must be blocked")
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
