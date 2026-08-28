import Foundation
import Testing

@testable import SaplingAgent

/// `tart run` is launched into a detached task that nothing awaits, so every
/// way it can fail was invisible: its own errors swallowed, its exit status
/// discarded, and only stderr read.
///
/// Measured on the node: the process lived 0.1 seconds, and Sapling spent the
/// next five minutes waiting for an IP address before blaming the address.
@Suite("VM boot process")
struct VMBootProcessTests {
    @Test("says nothing while the process is still running")
    func silentWhileHealthy() async {
        let process = VMBootProcess()
        await process.note("some ordinary boot chatter")
        #expect(await process.failure == nil)
        #expect(await process.explanation(vmName: "vm-1") == nil)
    }

    @Test("explains an exit, quoting what the process said")
    func explainsExit() async {
        let process = VMBootProcess()
        await process.note("Virtual machine limit exceeded")
        await process.end("`tart run` exited with status 1")
        let explanation = await process.explanation(vmName: "vm-1")
        #expect(explanation?.contains("vm-1") == true)
        #expect(explanation?.contains("status 1") == true)
        #expect(explanation?.contains("Virtual machine limit exceeded") == true)
    }

    /// The observed case exactly: it exited having printed nothing.
    ///
    /// That still has to produce an explanation, because the alternative is
    /// five minutes of silence and a misleading message.
    @Test("explains an exit even when the process printed nothing")
    func explainsSilentExit() async {
        let process = VMBootProcess()
        await process.end("`tart run` exited with status 1")
        let explanation = await process.explanation(vmName: "vm-2")
        #expect(explanation?.contains("printed nothing") == true)
        #expect(explanation?.contains("symptom") == true)
    }

    /// A cancellation arriving after the real failure must not overwrite the
    /// one message that named the cause.
    @Test("keeps the first reason it was given")
    func firstReasonWins() async {
        let process = VMBootProcess()
        await process.end("`tart run` exited with status 1")
        await process.end("cancelled")
        #expect(await process.failure == "`tart run` exited with status 1")
    }

    /// A VM that boots normally streams for the whole job; none of that is
    /// worth keeping, and keeping it would grow without limit.
    @Test("keeps only the tail of a long-running VM's output")
    func boundsRetainedOutput() async {
        let process = VMBootProcess()
        for index in 1...200 { await process.note("line \(index)") }
        await process.end("`tart run` exited with status 0")
        let explanation = await process.explanation(vmName: "vm-3")
        #expect(explanation?.contains("line 200") == true)
        #expect(explanation?.contains("line 1 ") == false)
        #expect((explanation?.count ?? 0) < 1000)
    }
}

/// Deleting a VM does not stop the process that was running it.
///
/// `tart run` goes through `launchctl asuser … sudo -u admin … tart run`, and
/// cancelling the task terminates only `ProcessRunner`'s immediate child. Six
/// leaked wrappers were found on the node, the oldest a day and nine hours,
/// one added by every macOS job — each apparently holding a `vmenet`
/// interface that is never released.
@Suite("Leaked VM processes")
struct LeakedVMProcessTests {
    @Test("reads process ids out of pgrep's output")
    func parsesPIDs() {
        #expect(TartProvider.parsePIDs("15335\n18498\n19474\n") == [15335, 18498, 19474])
        #expect(TartProvider.parsePIDs("  38478  \n") == [38478])
    }

    /// A signal sent to a mis-parsed id goes to whatever holds it.
    ///
    /// Anything that is not a plain number is not a process.
    @Test("ignores anything that is not a process id")
    func ignoresGarbage() {
        #expect(TartProvider.parsePIDs("").isEmpty)
        #expect(TartProvider.parsePIDs("no such process\n").isEmpty)
        #expect(TartProvider.parsePIDs("12ab\n-5\n").isEmpty)
        // 1 is launchd, and 0 is every process in the group.
        #expect(TartProvider.parsePIDs("0\n1\n").isEmpty)
    }
}

/// Teardown order, which is load-bearing.
///
/// Cancelling the boot task terminates `ProcessRunner`'s immediate child —
/// `launchctl` — and the `sudo` and `tart` processes beneath it survive, which
/// is why leaked wrappers are found parented to PID 1. Deleting a VM while the
/// process running it is still alive, still holding its `vmenet` interface, is
/// asking vmnet to lose track of an interface in use. Losing track of
/// interfaces is the fault under investigation, and the kill used to happen
/// after the delete.
@Suite("VM teardown order")
struct TeardownOrderTests {
    static var source: String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/SaplingAgent/Providers/TartProvider+Teardown.swift")
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    @Test("the VM's process is killed before the VM is deleted")
    func killPrecedesDelete() throws {
        let source = Self.source
        #expect(!source.isEmpty, "teardown source not found")
        guard let kill = source.range(of: "killRunProcesses(forVM: vmName)"),
            let delete = source.range(of: #"tartCommand(["delete", vmName])"#)
        else {
            Issue.record("teardown no longer kills the process or deletes the VM")
            return
        }
        #expect(
            kill.lowerBound < delete.lowerBound,
            "deleting a VM whose process still holds its vmenet interface is the bug this order fixes")
    }

    @Test("a stop that fails does not skip the kill and the delete")
    func failureDoesNotSkipLaterSteps() {
        // Each step is its own call now; the loop with an early `return` meant
        // one unavailable `tart` invocation silently skipped everything after.
        #expect(Self.source.contains("private static func tartCommand"))
        let earlyReturn = "guard let command = try? await tart(arguments) else { return }"
        #expect(!Self.source.contains(earlyReturn + "\n            _ ="))
    }
}
