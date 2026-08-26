import Foundation
import Testing

@testable import SaplingAgent

@Suite("Egress filter address maths")
struct NetworkGuardTests {
    @Test("converts ifconfig's hex netmasks to prefix lengths")
    func netmaskParsing() {
        #expect(NetworkGuard.prefixLength(fromHexNetmask: "0xffffff00") == 24)
        #expect(NetworkGuard.prefixLength(fromHexNetmask: "0xffff0000") == 16)
        #expect(NetworkGuard.prefixLength(fromHexNetmask: "ffffffff") == 32)
        #expect(NetworkGuard.prefixLength(fromHexNetmask: "nonsense") == nil)
    }

    @Test("derives the network address a pf table needs")
    func cidrDerivation() {
        #expect(NetworkGuard.networkCIDR(address: "192.168.64.1", prefix: 24) == "192.168.64.0/24")
        #expect(NetworkGuard.networkCIDR(address: "10.42.7.9", prefix: 16) == "10.42.0.0/16")
        #expect(NetworkGuard.networkCIDR(address: "bogus", prefix: 24) == nil)
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
        let interfaces = try await NetworkGuard.discoverBridgeInterfaces()
        for interface in interfaces {
            #expect(interface.name.hasPrefix("bridge"))
            #expect(interface.subnet.contains("/"))
        }
    }
}
