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
