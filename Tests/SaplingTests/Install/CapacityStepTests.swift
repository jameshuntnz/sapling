import Foundation
import Testing

@testable import SaplingCore
@testable import SaplingInstall

/// Apple's two-VM limit is a licensing ceiling, not a claim about your hardware.
///
/// Two 8GB VMs want the whole of a 16GB machine, and the resulting failure — a VM too slow to answer SSH
/// before its boot timeout — points at the base image rather than at the arithmetic.
@Suite("Capacity assessment")
struct CapacityStepTests {
    /// The exact configuration that broke the real node.
    @Test("rejects two 8GB VMs on a 16GB machine")
    func rejectsOvercommit() {
        let state = CapacityStep.assess(totalGB: 16, slots: 2, perVMGB: 8)
        #expect(!state.isOK)
        guard case .failed(let reason) = state else {
            Issue.record("over-committing RAM must fail, not warn: \(state)")
            return
        }
        // The message has to name the fix, since the symptom points elsewhere.
        #expect(reason.contains("macos.memory_gb"))
        #expect(reason.contains("SSH timeouts"))
    }

    @Test("accepts a configuration that leaves the host room")
    func acceptsFitting() {
        let state = CapacityStep.assess(totalGB: 16, slots: 2, perVMGB: 6)
        #expect(state.isOK)
        #expect(state.summary.contains("4GB left for the host"))
    }

    /// Fits, but only just — worth saying before it becomes a timeout.
    @Test("warns when the host is left short")
    func warnsWhenTight() {
        let state = CapacityStep.assess(totalGB: 16, slots: 2, perVMGB: 7)
        guard case .fixable(let summary) = state else {
            Issue.record("2GB for the host is tight and should be flagged: \(state)")
            return
        }
        #expect(summary.contains("tight"))
    }

    @Test("suggests a size that actually fits")
    func suggestsWorkableSize() {
        // 16GB, 2 slots, 4GB reserved -> 6GB each.
        let state = CapacityStep.assess(totalGB: 16, slots: 2, perVMGB: 8)
        #expect(state.summary.contains("6"))
    }

    @Test("a single slot may use much more of the machine")
    func singleSlot() {
        #expect(CapacityStep.assess(totalGB: 16, slots: 1, perVMGB: 8).isOK)
        #expect(!CapacityStep.assess(totalGB: 16, slots: 1, perVMGB: 20).isOK)
    }

    @Test("scales to a larger machine")
    func largerMachine() {
        #expect(CapacityStep.assess(totalGB: 64, slots: 2, perVMGB: 16).isOK)
        #expect(CapacityStep.assess(totalGB: 128, slots: 2, perVMGB: 32).isOK)
    }
}
