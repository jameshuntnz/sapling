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

    // MARK: - The shared slot pool

    /// The node the measurements came from: 16GB, two slots, either platform.
    @Test("two 6GB slots fit a 16GB machine, leaving the host its reserve")
    func sharedPoolFits() {
        let state = CapacityStep.assessNode(
            totalGB: 16, slots: 2, macPerVMGB: 6, linuxPerGB: 6, linuxEnabled: true)
        #expect(state.isOK)
        #expect(state.summary.contains("4GB left for the host"))
    }

    /// Worst case is every slot holding the *larger* environment, because with
    /// a shared pool any slot may hold either.
    @Test("budgets the larger environment in every slot")
    func budgetsTheLargest() {
        // An 8GB VM and a 4GB container: two slots could hold two VMs.
        let state = CapacityStep.assessNode(
            totalGB: 16, slots: 2, macPerVMGB: 8, linuxPerGB: 4, linuxEnabled: true)
        #expect(!state.isOK)
        #expect(state.summary.contains("16GB worst case"))
    }

    /// The state the node was actually in.
    ///
    /// Nothing ever wrote `linux.memory_gb`, so every container ran in the 1GB
    /// default and every large build was killed part way through.
    @Test("flags an unset linux.memory_gb as the 1GB default it really is")
    func flagsUnsetLinuxMemory() {
        let state = CapacityStep.assessNode(
            totalGB: 16, slots: 2, macPerVMGB: 6, linuxPerGB: nil, linuxEnabled: true)
        guard case .fixable(let reason) = state else {
            Issue.record("an unset size is a live under-provisioning, not ok: \(state)")
            return
        }
        #expect(reason.contains("linux.memory_gb"))
        #expect(reason.contains("\(LinuxConfig.containerDefaultMemoryGB)GB"))
        // The symptom points at the build, so the message has to bridge the two.
        #expect(reason.contains("vanished daemon"))
    }

    /// 4GB is not a cautious floor — it is the value measured to OOM.
    @Test("flags a size below the measured floor even when it fits")
    func flagsStarvedEnvironments() {
        // 2 x 4GB = 8GB fits inside 16GB comfortably, and still fails builds.
        let state = CapacityStep.assessNode(
            totalGB: 16, slots: 2, macPerVMGB: 4, linuxPerGB: 4, linuxEnabled: true)
        guard case .fixable(let reason) = state else {
            Issue.record("4GB fits but is the size that OOMs; it must be flagged: \(state)")
            return
        }
        #expect(reason.contains("\(CapacityStep.minimumGB)GB"))
        // It should say what this machine can actually afford.
        #expect(reason.contains("6GB each"))
    }

    @Test("over-committing the machine outright fails")
    func overCommitFails() {
        let state = CapacityStep.assessNode(
            totalGB: 16, slots: 2, macPerVMGB: 8, linuxPerGB: 8, linuxEnabled: true)
        guard case .failed(let reason) = state else {
            Issue.record("2 x 8GB on a 16GB machine must fail: \(state)")
            return
        }
        #expect(reason.contains("node.max_concurrent"))
    }

    /// Raising the slot count is what makes a fitting node stop fitting.
    @Test("the same sizes fail once the node runs more of them")
    func slotsDriveTheBudget() {
        #expect(
            CapacityStep.assessNode(
                totalGB: 16, slots: 2, macPerVMGB: 6, linuxPerGB: 6, linuxEnabled: true
            ).isOK)
        #expect(
            !CapacityStep.assessNode(
                totalGB: 16, slots: 3, macPerVMGB: 6, linuxPerGB: 6, linuxEnabled: true
            ).isOK)
        // A bigger machine takes the same three.
        #expect(
            CapacityStep.assessNode(
                totalGB: 32, slots: 3, macPerVMGB: 6, linuxPerGB: 6, linuxEnabled: true
            ).isOK)
    }

    @Test("a node with no slots accepts nothing and needs no memory")
    func noSlots() {
        #expect(
            CapacityStep.assessNode(
                totalGB: 16, slots: 0, macPerVMGB: nil, linuxPerGB: nil, linuxEnabled: false
            ).isOK)
    }

    /// Linux off means the container default is irrelevant, not a warning.
    @Test("does not warn about containers when Linux is disabled")
    func linuxDisabled() {
        #expect(
            CapacityStep.assessNode(
                totalGB: 16, slots: 1, macPerVMGB: 8, linuxPerGB: nil, linuxEnabled: false
            ).isOK)
    }
}
