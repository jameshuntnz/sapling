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

    // MARK: - Linux containers

    /// The state the node was actually in.
    ///
    /// Nothing ever wrote `linux.memory_gb`, so every container ran in the 1GB
    /// default and every large build was killed part way through.
    @Test("flags an unset linux.memory_gb as the 1GB default it really is")
    func flagsUnsetLinuxMemory() {
        let state = CapacityStep.assessLinux(
            totalGB: 16, macWantedGB: 0, slots: 2, perContainerGB: nil)
        guard case .fixable(let reason) = state else {
            Issue.record("an unset size is a live under-provisioning, not ok: \(state)")
            return
        }
        #expect(reason.contains("linux.memory_gb"))
        #expect(reason.contains("\(LinuxConfig.containerDefaultMemoryGB)GB"))
        // The symptom points at the build, so the message has to bridge the two.
        #expect(reason.contains("vanished daemon"))
        // 16 - 4 host = 12, over 2 slots.
        #expect(reason.contains("6"))
    }

    /// A container can be sized and still be too small to finish a real build.
    @Test("flags a configured size below the floor")
    func flagsStarvedContainers() {
        let state = CapacityStep.assessLinux(
            totalGB: 16, macWantedGB: 0, slots: 2, perContainerGB: 2)
        guard case .fixable = state else {
            Issue.record("2GB per container should be flagged: \(state)")
            return
        }
    }

    @Test("accepts containers that fit beside the VMs")
    func acceptsFittingContainers() {
        let state = CapacityStep.assessLinux(
            totalGB: 32, macWantedGB: 8, slots: 2, perContainerGB: 8)
        #expect(state.isOK)
    }

    /// The whole point of budgeting both platforms in one step: each half looks
    /// reasonable alone, and together they exceed the machine.
    @Test("counts the VMs against the container budget")
    func countsVMsAgainstContainers() {
        // 16GB, 4 reserved, 2 VMs x 6GB = 12 — nothing at all is left.
        let state = CapacityStep.assessLinux(
            totalGB: 16, macWantedGB: 12, slots: 2, perContainerGB: 4)
        guard case .failed(let reason) = state else {
            Issue.record("over-committing the host across platforms must fail: \(state)")
            return
        }
        #expect(reason.contains("linux.max_concurrent"))
        // Same containers, on a machine with room for them.
        #expect(
            CapacityStep.assessLinux(
                totalGB: 32, macWantedGB: 12, slots: 2, perContainerGB: 4
            ).isOK)
    }

    @Test("says nothing about containers when Linux jobs are off")
    func linuxDisabled() {
        #expect(
            CapacityStep.assessLinux(
                totalGB: 16, macWantedGB: 12, slots: 0, perContainerGB: nil
            ).isOK)
    }

    // MARK: - Reporting both at once

    /// A node wrong in two ways should say so once, not hide the second behind
    /// the first and make someone re-run doctor to discover it.
    @Test("reports both platforms, worst case winning")
    func combinesBothPlatforms() {
        let macFailed = CapacityStep.assess(totalGB: 16, slots: 2, perVMGB: 8)
        let linuxFixable = CapacityStep.assessLinux(
            totalGB: 16, macWantedGB: 16, slots: 2, perContainerGB: nil)
        let combined = CapacityStep.combine(macFailed, linuxFixable)

        guard case .failed(let reason) = combined else {
            Issue.record("a failed platform must win over a fixable one: \(combined)")
            return
        }
        #expect(reason.contains("macos.memory_gb"))
        #expect(reason.contains("linux.memory_gb"))
    }

    @Test("an ok platform does not mask the other")
    func okDoesNotMask() {
        let ok = StepState.ok("macOS jobs are disabled")
        let starved = CapacityStep.assessLinux(
            totalGB: 16, macWantedGB: 0, slots: 2, perContainerGB: 1)
        #expect(!CapacityStep.combine(ok, starved).isOK)
        #expect(CapacityStep.combine(ok, .ok("fine")).isOK)
    }
}
