import Foundation
import Testing

@testable import SaplingAPI
@testable import SaplingCore
@testable import SaplingDB

@Suite("Bind resolution")
struct BindResolverTests {
    @Test("resolves the deterministic modes")
    func explicitModes() async throws {
        #expect(try await BindResolver.resolve(.loopback).hostname == "127.0.0.1")
        #expect(try await BindResolver.resolve(.all).hostname == "0.0.0.0")
        #expect(try await BindResolver.resolve(.explicit("10.1.2.3")).hostname == "10.1.2.3")
    }

    @Test("names the wide bind in its description, so the log says so")
    func describesWideBind() async throws {
        let resolution = try await BindResolver.resolve(.all)
        #expect(resolution.description.contains("ALL"))
    }

    /// §8's access control is "bound to the tailnet".
    ///
    /// Silently falling back to a wider interface would turn a missing Tailscale
    /// into an open API.
    @Test("refuses rather than widening when Tailscale is absent")
    func tailscaleNeverFallsBack() async throws {
        if let address = await BindResolver.tailscaleAddress() {
            // If this machine really is on a tailnet, the address must be one.
            #expect(BindResolver.isCGNAT(address))
            return
        }
        await #expect(throws: ConfigError.self) {
            _ = try await BindResolver.resolve(.tailscale)
        }
    }

    @Test("recognises the CGNAT range Tailscale allocates from")
    func cgnatDetection() {
        #expect(BindResolver.isCGNAT("100.64.0.1"))
        #expect(BindResolver.isCGNAT("100.127.255.254"))
        #expect(!BindResolver.isCGNAT("100.128.0.1"))
        #expect(!BindResolver.isCGNAT("100.63.255.255"))
        #expect(!BindResolver.isCGNAT("192.168.1.1"))
        #expect(!BindResolver.isCGNAT("not-an-ip"))
    }

    @Test("parses bind modes from config text")
    func bindModeParsing() {
        #expect(BindMode(rawValue: "tailscale") == .tailscale)
        #expect(BindMode(rawValue: "auto") == .tailscale)
        #expect(BindMode(rawValue: "loopback") == .loopback)
        #expect(BindMode(rawValue: "127.0.0.1") == .loopback)
        #expect(BindMode(rawValue: "0.0.0.0") == .all)
        #expect(BindMode(rawValue: "10.0.0.5") == .explicit("10.0.0.5"))
        #expect(BindMode(rawValue: "10.0.0.5").rawValue == "10.0.0.5")
    }
}
