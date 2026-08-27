import Foundation
import Testing

@testable import SaplingAgent

@Suite("Egress filter address maths")
struct NetworkGuardTests {
    @Test("converts ifconfig's hex netmasks to prefix lengths")
    func netmaskParsing() {
        #expect(BridgeTable.prefixLength(fromHexNetmask: "0xffffff00") == 24)
        #expect(BridgeTable.prefixLength(fromHexNetmask: "0xffff0000") == 16)
        #expect(BridgeTable.prefixLength(fromHexNetmask: "ffffffff") == 32)
        #expect(BridgeTable.prefixLength(fromHexNetmask: "nonsense") == nil)
    }

    @Test("derives the network address a pf table needs")
    func cidrDerivation() {
        #expect(BridgeTable.networkCIDR(address: "192.168.64.1", prefix: 24) == "192.168.64.0/24")
        #expect(BridgeTable.networkCIDR(address: "10.42.7.9", prefix: 16) == "10.42.0.0/16")
        #expect(BridgeTable.networkCIDR(address: "bogus", prefix: 24) == nil)
    }

    /// §8's whole point: the tailnet and the LAN are both off-limits to jobs.
    @Test("blocks LAN, link-local, and tailnet ranges by default")
    func defaultBlocks() {
        #expect(NetworkGuard.defaultBlockedCIDRs.contains("192.168.0.0/16"))
        #expect(NetworkGuard.defaultBlockedCIDRs.contains("10.0.0.0/8"))
        #expect(NetworkGuard.defaultBlockedCIDRs.contains("169.254.0.0/16"))
        #expect(NetworkGuard.defaultBlockedCIDRs.contains("100.64.0.0/10"))
    }

    @Test("finds this Mac's real bridge interfaces without crashing")
    func discovery() async throws {
        // No VM tooling on a monitor-only Mac, so an empty result is correct
        // here; the assertion is that parsing real ifconfig output is safe.
        let interfaces = try await BridgeTable.current()
        for interface in interfaces {
            #expect(interface.name.hasPrefix("bridge"))
            #expect(interface.subnet.contains("/"))
        }
    }
}

/// The egress filter must be in place *before* a job's traffic starts, but the host bridge only exists while
/// an environment is already running.
///
/// These cover the declared-subnet path that closes that gap.
@Suite("Declared job subnets")
struct DeclaredJobSubnetTests {
    @Test("derives the vmnet gateway from a subnet")
    func gatewayDerivation() {
        #expect(BridgeTable.gatewayCIDR(forSubnet: "192.168.64.0/24") == "192.168.64.1/32")
        #expect(BridgeTable.gatewayCIDR(forSubnet: "10.0.0.0/8") == "10.0.0.1/32")
        #expect(BridgeTable.gatewayCIDR(forSubnet: "172.16.32.0/20") == "172.16.32.1/32")
        // An address mid-subnet still resolves to that subnet's gateway.
        #expect(BridgeTable.gatewayCIDR(forSubnet: "192.168.64.7/24") == "192.168.64.1/32")
    }

    @Test("rejects malformed subnets rather than inventing a gateway")
    func rejectsMalformed() {
        #expect(BridgeTable.gatewayCIDR(forSubnet: "192.168.64.0") == nil)
        #expect(BridgeTable.gatewayCIDR(forSubnet: "not/a/subnet") == nil)
        #expect(BridgeTable.gatewayCIDR(forSubnet: "192.168.64.0/99") == nil)
        #expect(BridgeTable.gatewayCIDR(forSubnet: "") == nil)
    }
}
