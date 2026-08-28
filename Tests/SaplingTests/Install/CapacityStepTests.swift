import Foundation
import Testing

@testable import SaplingCore
@testable import SaplingInstall

/// A default larger than the whole job budget refuses every job of its platform.
///
/// This step no longer multiplies slots by the largest environment — admission
/// rations memory job by job, so the over-commit it used to guard against
/// cannot happen. What it still catches is a node configured so that nothing
/// of a given platform can ever start, which otherwise shows up only as jobs
/// queueing forever.
@Suite("Capacity assessment")
struct CapacityStepTests {
    /// The node these measurements came from: 16GB, 4GB kept for the host.
    @Test("reports how many of each default fit the budget")
    func reportsWhatFits() {
        let state = CapacityStep.assessNode(
            totalGB: 16, budgetGB: 12, macPerVMGB: 6, linuxPerGB: 2, linuxEnabled: true)
        #expect(state.isOK)
        // Two 6GB VMs or six 2GB containers, and any mix in between.
        #expect(state.summary.contains("2 x 6GB macOS"))
        #expect(state.summary.contains("6 x 2GB Linux"))
    }

    /// The configuration that broke the real node, now caught by admission.
    ///
    /// Two 8GB VMs never run at once, because the second is never admitted. One
    /// of them still fits, so this is not a misconfiguration to report here.
    @Test("a default that fits alone is fine even when two would not")
    func oversubscriptionIsAdmissionsProblem() {
        let state = CapacityStep.assessNode(
            totalGB: 16, budgetGB: 12, macPerVMGB: 8, linuxPerGB: 2, linuxEnabled: true)
        #expect(state.isOK)
        #expect(state.summary.contains("1 x 8GB macOS"))
    }

    @Test("a default larger than the whole budget fails, naming the fix")
    func defaultTooLarge() {
        let state = CapacityStep.assessNode(
            totalGB: 16, budgetGB: 4, macPerVMGB: 8, linuxPerGB: 2, linuxEnabled: true)
        guard case .failed(let reason) = state else {
            Issue.record("a default nothing can satisfy must fail: \(state)")
            return
        }
        #expect(reason.contains("every one would be refused"))
        #expect(reason.contains("node.memory_reserve_gb"))
    }

    /// The state the node was actually in: nothing ever wrote linux.memory_gb.
    @Test("an unset linux.memory_gb is reported as the 1GB default it really is")
    func flagsUnsetLinuxMemory() {
        let state = CapacityStep.assessNode(
            totalGB: 16, budgetGB: 12, macPerVMGB: 6, linuxPerGB: nil, linuxEnabled: true)
        guard case .fixable(let reason) = state else {
            Issue.record("an unset size is a live under-provisioning, not ok: \(state)")
            return
        }
        #expect(reason.contains("linux.memory_gb"))
        #expect(reason.contains("\(LinuxConfig.containerDefaultMemoryGB)GB"))
        // The symptom points at the build, so the message has to bridge the two.
        #expect(reason.contains("vanished daemon"))
    }

    /// A reserve that swallows the machine leaves a node that accepts nothing,
    /// and no per-platform size can rescue it.
    @Test("a reserve larger than the machine fails outright")
    func reserveEatsTheMachine() {
        let state = CapacityStep.assessNode(
            totalGB: 4, budgetGB: 0, macPerVMGB: 6, linuxPerGB: 2, linuxEnabled: true)
        guard case .failed(let reason) = state else {
            Issue.record("no budget at all must fail: \(state)")
            return
        }
        #expect(reason.contains("node.memory_reserve_gb"))
    }

    @Test("says nothing about containers when Linux is disabled")
    func linuxDisabled() {
        let state = CapacityStep.assessNode(
            totalGB: 16, budgetGB: 12, macPerVMGB: 6, linuxPerGB: nil, linuxEnabled: false)
        #expect(state.isOK)
        #expect(!state.summary.contains("Linux"))
    }

    @Test("an unknown VM size is reported as unknown, not guessed at")
    func unknownSizes() {
        let state = CapacityStep.assessNode(
            totalGB: 16, budgetGB: 12, macPerVMGB: nil, linuxPerGB: nil, linuxEnabled: false)
        #expect(state.isOK)
        #expect(state.summary.contains("unknown"))
    }

    /// Scaling is now a property of the budget, not of a slot count.
    @Test("a bigger machine simply fits more")
    func largerMachine() {
        let small = CapacityStep.assessNode(
            totalGB: 16, budgetGB: 12, macPerVMGB: 6, linuxPerGB: 6, linuxEnabled: true)
        let large = CapacityStep.assessNode(
            totalGB: 64, budgetGB: 60, macPerVMGB: 6, linuxPerGB: 6, linuxEnabled: true)
        #expect(small.summary.contains("2 x 6GB macOS"))
        #expect(large.summary.contains("10 x 6GB macOS"))
    }
}
