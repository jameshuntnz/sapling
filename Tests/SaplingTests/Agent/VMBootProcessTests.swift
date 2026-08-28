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
