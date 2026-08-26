import Foundation
import Testing

@testable import SaplingAgent

@Suite("Bridge interface parsing")
struct BridgeParsingTests {
    /// Real `ifconfig` output from a Mac running both a Tart VM and Apple's
    /// `container` — the pf tables are built entirely from this.
    static let sample = """
        lo0: flags=8049<UP,LOOPBACK,RUNNING,MULTICAST> mtu 16384
        \tinet 127.0.0.1 netmask 0xff000000
        en0: flags=8863<UP,BROADCAST,SMART,RUNNING,SIMPLEX,MULTICAST> mtu 1500
        \tinet 192.168.1.42 netmask 0xffffff00 broadcast 192.168.1.255
        utun4: flags=8051<UP,POINTOPOINT,RUNNING,MULTICAST> mtu 1280
        \tinet 100.101.102.103 --> 100.101.102.103 netmask 0xff000000
        bridge100: flags=8863<UP,BROADCAST,SMART,RUNNING,SIMPLEX,MULTICAST> mtu 1500
        \tinet 192.168.64.1 netmask 0xffffff00 broadcast 192.168.64.255
        \tConfiguration:
        \t\tid 0:0:0:0:0:0 priority 0 hellotime 0 fwddelay 0
        bridge101: flags=8863<UP,BROADCAST,SMART,RUNNING,SIMPLEX,MULTICAST> mtu 1500
        \tinet 192.168.65.1 netmask 0xffffff00 broadcast 192.168.65.255
        """

    @Test("finds only bridge interfaces, with their network CIDRs")
    func findsBridges() {
        let interfaces = NetworkGuard.parseInterfaces(from: Self.sample)
        #expect(interfaces.map(\.name) == ["bridge100", "bridge101"])
        #expect(interfaces.map(\.subnet) == ["192.168.64.0/24", "192.168.65.0/24"])
        // The gateway address itself, which becomes the "allowed" entry.
        #expect(interfaces.map(\.address) == ["192.168.64.1", "192.168.65.1"])
    }

    /// The host's own LAN address and its tailnet address must never end up
    /// in the jobnets table — that would let jobs out through the very rules
    /// meant to contain them.
    @Test("ignores the host's LAN, loopback, and tailnet interfaces")
    func ignoresNonBridges() {
        let interfaces = NetworkGuard.parseInterfaces(from: Self.sample)
        #expect(!interfaces.contains { $0.address == "192.168.1.42" })
        #expect(!interfaces.contains { $0.address == "127.0.0.1" })
        #expect(!interfaces.contains { $0.address == "100.101.102.103" })
    }

    @Test("returns nothing when no VM has ever run")
    func noBridgesYet() {
        let output = """
            lo0: flags=8049<UP,LOOPBACK,RUNNING,MULTICAST> mtu 16384
            \tinet 127.0.0.1 netmask 0xff000000
            """
        #expect(NetworkGuard.parseInterfaces(from: output).isEmpty)
    }

    @Test("skips a bridge that is up but has no address yet")
    func bridgeWithoutAddress() {
        let output = """
            bridge100: flags=8863<UP,BROADCAST> mtu 1500
            \tConfiguration:
            \t\tid 0:0:0:0:0:0 priority 0
            """
        #expect(NetworkGuard.parseInterfaces(from: output).isEmpty)
    }
}
