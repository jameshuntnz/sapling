import Foundation
import Testing

@testable import SaplingAgent
@testable import SaplingCore

/// Memory is what jobs actually contend for, and what fails silently when short.
///
/// A container over its cap is SIGKILLed by the guest kernel and the surviving
/// tool reports a vanished worker, so the size a job gets has to be decided
/// deliberately rather than inherited from whatever the tool defaults to.
@Suite("Job sizing")
struct JobSizingTests {
    func config(_ mutate: (inout SaplingConfig) -> Void = { _ in }) -> SaplingConfig {
        var c = SaplingConfig()
        c.linux.memoryGB = 2
        c.macos.memoryGB = 6
        mutate(&c)
        return c
    }

    @Test("a mem: label overrides the platform default")
    func labelWins() {
        let c = config()
        #expect(
            JobSizing.memoryGB(
                labels: ["self-hosted", "linux", "mem:6"], platform: .linux, config: c) == 6)
        #expect(
            JobSizing.memoryGB(labels: ["self-hosted", "linux"], platform: .linux, config: c) == 2)
        #expect(
            JobSizing.memoryGB(labels: ["self-hosted", "macos"], platform: .macos, config: c) == 6)
    }

    @Test("reads both 6 and 6g")
    func parsesSuffixes() {
        #expect(RunnerImageSelector.parseMemoryGB("6") == 6)
        #expect(RunnerImageSelector.parseMemoryGB("6g") == 6)
        #expect(RunnerImageSelector.parseMemoryGB("6G") == 6)
        #expect(RunnerImageSelector.parseMemoryGB("6gb") == 6)
    }

    /// Guessing at a malformed size would hand a build silently less memory
    /// than the workflow asked for — the exact failure the label prevents.
    @Test("an unparseable size falls back rather than guessing")
    func rejectsNonsense() {
        #expect(RunnerImageSelector.parseMemoryGB("lots") == nil)
        #expect(RunnerImageSelector.parseMemoryGB("") == nil)
        #expect(RunnerImageSelector.parseMemoryGB("0") == nil)
        #expect(RunnerImageSelector.parseMemoryGB("-4") == nil)
        let c = config()
        #expect(
            JobSizing.memoryGB(labels: ["linux", "mem:huge"], platform: .linux, config: c) == 2)
    }

    /// The trap `image:` already documents: a selector left among the
    /// capabilities is a label the node will never advertise, which makes the
    /// job silently unroutable rather than loudly wrong.
    @Test("selectors are stripped from the capabilities matched on")
    func stripsSelectors() {
        let parsed = RunnerImageSelector.parse(
            ["self-hosted", "linux", "arm64", "image:android", "mem:6"])
        #expect(parsed.capabilities == ["self-hosted", "linux", "arm64"])
        #expect(parsed.image == "android")
        #expect(parsed.memoryGB == 6)
    }

    @Test("a request is clamped to the platform ceiling")
    func clampsToCeiling() {
        let c = config { $0.linux.maxMemoryGB = 8 }
        #expect(JobSizing.memoryGB(labels: ["mem:32"], platform: .linux, config: c) == 8)
        #expect(JobSizing.memoryGB(labels: ["mem:4"], platform: .linux, config: c) == 4)
    }

    // MARK: - Refusing what can never run

    /// A job asking for more than the machine has is not waiting for capacity.
    @Test("a request beyond the node's whole budget is refused, not queued")
    func refusesImpossible() {
        let reason = JobSizing.unschedulableReason(memoryGB: 32, budgetGB: 12, ceilingGB: nil)
        #expect(reason != nil)
        #expect(reason?.contains("32GB") == true)
        #expect(reason?.contains("12GB") == true)
        // The point of refusing: say that waiting will not help.
        #expect(reason?.contains("waiting") == true)
    }

    @Test("a request over the platform ceiling names the setting")
    func refusesOverCeiling() {
        let reason = JobSizing.unschedulableReason(memoryGB: 16, budgetGB: 64, ceilingGB: 8)
        #expect(reason?.contains("max_memory_gb") == true)
    }

    @Test("what fits is not refused")
    func allowsFitting() {
        #expect(JobSizing.unschedulableReason(memoryGB: 6, budgetGB: 12, ceilingGB: 8) == nil)
        #expect(JobSizing.unschedulableReason(memoryGB: nil, budgetGB: 12, ceilingGB: 8) == nil)
    }

    // MARK: - Admission

    /// Four 2GB jobs fit a 12GB budget; the fifth waits.
    ///
    /// Counts alone could not express that, and sizing every slot for the
    /// largest job wastes most of the machine.
    @Test("admission is decided by memory, not by counting")
    func admissionByMemory() {
        #expect(JobSizing.fits(memoryGB: 2, committedGB: 6, budgetGB: 12))
        #expect(JobSizing.fits(memoryGB: 6, committedGB: 6, budgetGB: 12))
        #expect(!JobSizing.fits(memoryGB: 6, committedGB: 8, budgetGB: 12))
        #expect(!JobSizing.fits(memoryGB: 2, committedGB: 12, budgetGB: 12))
    }

    /// Where the size is unknown, the charge has to guess high.
    ///
    /// A macOS VM charged the container default would book 1GB against a guest
    /// that takes eight, and the budget would then admit work the machine
    /// cannot hold.
    @Test("an unsized job is charged its own platform's default, not the other's")
    func chargesPerPlatform() {
        var c = SaplingConfig()
        c.linux.memoryGB = nil
        c.macos.memoryGB = nil
        // Nothing configured: each platform falls back to its own tool's size.
        #expect(LinuxConfig.containerDefaultMemoryGB == 1)
        #expect(MacOSConfig.baseImageDefaultMemoryGB == 8)
        #expect(MacOSConfig.baseImageDefaultMemoryGB > LinuxConfig.containerDefaultMemoryGB)
    }

    @Test("the budget is the machine less the host's reserve")
    func budget() {
        var node = NodeConfig()
        node.memoryReserveGB = 4
        #expect(node.memoryBudgetGB(totalGB: 16) == 12)
        // A machine smaller than its own reserve owes jobs nothing, not a
        // negative number the arithmetic would then admit against.
        #expect(node.memoryBudgetGB(totalGB: 2) == 0)
    }
}
