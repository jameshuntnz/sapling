import Foundation
import Testing

@testable import SaplingAgent
@testable import SaplingCore

@Suite("Egress filter enforcement")
struct NetworkGuardEnforcementTests {
    /// Turning the filter off is a config choice with consequences, and the
    /// daemon has to be able to tell that apart from a failure to apply it.
    @Test("refuses to pretend it applied anything when disabled")
    func disabledIsDistinctFromApplied() async {
        var config = NetworkConfig()
        config.blockPrivateRanges = false
        await #expect(throws: NetworkGuardError.self) {
            _ = try await NetworkGuard(config: config).apply()
        }
        do {
            _ = try await NetworkGuard(config: config).apply()
        } catch let error as NetworkGuardError {
            guard case .disabled = error else {
                Issue.record("expected .disabled, got \(error)")
                return
            }
            #expect(error.errorDescription?.contains("block_private_ranges") == true)
        } catch {}
    }

    @Test("requires root, and says so")
    func requiresRoot() async {
        guard getuid() != 0 else { return }
        do {
            _ = try await NetworkGuard(config: NetworkConfig()).apply()
            Issue.record("applying pf rules without root should fail")
        } catch let error as NetworkGuardError {
            guard case .notRoot = error else {
                Issue.record("expected .notRoot, got \(error)")
                return
            }
            #expect(error.errorDescription?.contains("root") == true)
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    /// An anchor that exists but carries no block rule looks configured and
    /// protects nothing — that must read as "not loaded".
    @Test("verify treats a ruleless anchor as unprotected")
    func verifyRequiresABlockRule() async {
        let (loaded, _) = await NetworkGuard.verify()
        // No sapling anchor is installed on a dev machine.
        #expect(!loaded)
    }

    @Test("extra blocked and allowed ranges come from config")
    func configurableRanges() {
        var config = NetworkConfig()
        config.extraBlockedCIDRs = ["203.0.113.0/24"]
        config.allowedCIDRs = ["192.168.64.1/32"]
        #expect(config.blockPrivateRanges)
        #expect(config.extraBlockedCIDRs.contains("203.0.113.0/24"))
        #expect(config.allowedCIDRs.contains("192.168.64.1/32"))
    }
}

/// Re-asserting the filter before every job means the "nothing changed" path is the common one, not an edge
/// case.
///
/// Getting it wrong stopped the node working entirely: reloading an anchor whose tables are still referenced
/// fails with "Resource busy", and a job refuses to start when the filter can't be applied — so every job
/// after the first was declined.
@Suite("Egress filter reloading")
struct NetworkGuardReloadTests {
    @Test("requires root before touching pf at all")
    func requiresRootFirst() async {
        guard getuid() != 0 else { return }
        var config = NetworkConfig()
        config.jobSubnets = ["192.168.64.0/24"]

        do {
            _ = try await NetworkGuard(config: config).apply()
            Issue.record("applying pf rules without root should fail")
        } catch let error as NetworkGuardError {
            guard case .notRoot = error else {
                Issue.record("expected .notRoot, got \(error)")
                return
            }
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    /// The declared subnets are what make the filter applicable before any
    /// bridge exists, so an empty list has to be refused rather than silently
    /// producing rules that match nothing.
    @Test("refuses to build rules with no subnets to protect")
    func refusesEmptySubnets() async {
        guard getuid() != 0 else { return }
        var config = NetworkConfig()
        config.jobSubnets = []
        await #expect(throws: NetworkGuardError.self) {
            _ = try await NetworkGuard(config: config).apply()
        }
    }

    /// Each declared subnet needs its own gateway in the allowed table, or the
    /// environment on it loses DHCP, DNS and the cache proxy.
    @Test("derives a gateway for every declared subnet")
    func gatewayPerSubnet() {
        let subnets = NetworkConfig().jobSubnets
        let gateways = subnets.compactMap(NetworkGuard.gatewayCIDR(forSubnet:))
        #expect(gateways.count == subnets.count)
        #expect(gateways.contains("192.168.64.1/32"))
        #expect(gateways.contains("192.168.65.1/32"))
    }
}

/// `sapling install` writes every field to config.toml, defaults included, so a default that improves later
/// never reaches an existing node.
///
/// That is tolerable for a timeout and not for a security control: a node installed when the default was one
/// subnet kept one subnet, and its macOS VMs — which land on a different subnet than containers — ran
/// unfiltered while the rules read as correct.
@Suite("Job subnet coverage")
struct JobSubnetCoverageTests {
    /// Config may add coverage; it may never take the built-in range away.
    @Test("a stale config cannot subtract coverage")
    func staleConfigCannotSubtract() {
        let stale = ["192.168.64.0/24"]
        let effective = Set(stale).union(NetworkConfig.defaultJobSubnets)
        for subnet in NetworkConfig.defaultJobSubnets {
            #expect(effective.contains(subnet), "\(subnet) must survive a stale config")
        }
        // The one vmnet gave the macOS VM that slipped through.
        #expect(effective.contains("192.168.65.0/24"))
    }

    @Test("config can still add subnets of its own")
    func configCanAdd() {
        let custom = ["10.99.0.0/24"]
        let effective = Set(custom).union(NetworkConfig.defaultJobSubnets)
        #expect(effective.contains("10.99.0.0/24"))
        #expect(effective.count == NetworkConfig.defaultJobSubnets.count + 1)
    }

    @Test("every covered subnet gets a reachable gateway")
    func everySubnetHasAGateway() {
        let effective = Set(["10.99.0.0/24"]).union(NetworkConfig.defaultJobSubnets)
        let gateways = effective.compactMap(NetworkGuard.gatewayCIDR(forSubnet:))
        #expect(gateways.count == effective.count)
        #expect(gateways.contains("10.99.0.1/32"))
    }
}

/// The gateway is the host's own address on the bridge, so it sits inside the job subnet.
///
/// Left in the jobnets table, the host's traffic to a VM matches "from <jobnets> to <blocked>" and is dropped
/// — and the symptom is the agent unable to SSH into the VM it just booted, which reads as a broken base
/// image. It stalled two slots for the full boot timeout, twice.
@Suite("Gateway exclusion")
struct GatewayExclusionTests {
    /// Mirrors how the anchor's jobnets table is built.
    func entries(for subnets: [String]) -> [String] {
        subnets.flatMap { subnet -> [String] in
            guard let gateway = NetworkGuard.gatewayCIDR(forSubnet: subnet) else { return [subnet] }
            return [subnet, "!\(gateway.replacingOccurrences(of: "/32", with: ""))"]
        }
    }

    @Test("every subnet is paired with its gateway negated")
    func gatewayIsExcluded() {
        let built = entries(for: ["192.168.64.0/24", "192.168.65.0/24"])
        #expect(built == ["192.168.64.0/24", "!192.168.64.1", "192.168.65.0/24", "!192.168.65.1"])
    }

    /// The host reaches a VM from the gateway address, so that address must
    /// not be treated as a job environment.
    @Test("the host's own address is never inside the job set")
    func hostIsNotAJob() {
        let built = entries(for: NetworkConfig.defaultJobSubnets)
        for subnet in NetworkConfig.defaultJobSubnets {
            let gateway = NetworkGuard.gatewayCIDR(forSubnet: subnet)!
                .replacingOccurrences(of: "/32", with: "")
            #expect(built.contains("!\(gateway)"), "\(gateway) must be excluded")
        }
    }

    /// A subnet that cannot yield a gateway is still covered, not dropped.
    @Test("keeps a subnet whose gateway cannot be derived")
    func malformedSubnetSurvives() {
        #expect(entries(for: ["not-a-subnet"]) == ["not-a-subnet"])
    }
}
