import Foundation
import Testing

@testable import SaplingAPI

@Suite("Browser guard")
struct BrowserGuardTests {
    @Test("accepts the names a tailnet client uses")
    func trustedHosts() {
        for host in [
            "100.101.102.103:8734", "127.0.0.1", "localhost:8734", "mini", "mini:8734",
            "mini.tail1234.ts.net:8734", "mini.local", "[fd7a:115c:a1e5::1]:8734",
        ] {
            #expect(BrowserGuardMiddleware.isTrustedHost(host), "\(host)")
        }
    }

    /// DNS rebinding: the attacker's own domain, pointed at the node.
    @Test("refuses a public DNS name, whatever it resolves to")
    func untrustedHosts() {
        for host in ["evil.example.com", "evil.example.com:8734", "100.64.0.1.nip.io", "ts.net.evil.com", ""]
        {
            #expect(!BrowserGuardMiddleware.isTrustedHost(host), "\(host)")
        }
    }
}
