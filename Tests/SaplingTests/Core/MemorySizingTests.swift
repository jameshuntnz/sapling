import Foundation
import Testing

@testable import SaplingCore

/// Advice about a `mem:` label, from the one signal that means what it says.
///
/// The obvious signal does not support the obvious advice. A guest spends
/// spare memory on page cache and never returns it, so the host's footprint
/// climbs to whatever the job was given whatever it needed — measured on this
/// node, an Android build reserving 6GB peaked at 6.16GB and passed, and a
/// macOS job reserving 6GB peaked at 6.02GB and passed. Warning on a near-full
/// peak would warn on every healthy job.
@Suite("Memory sizing advice")
struct MemorySizingTests {
    /// One kill can be a bad day on a loaded node.
    @Test("says nothing until there is enough history to mean it")
    func needsHistory() {
        #expect(MemorySizing.advise(requestGB: 4, outcomes: [.memoryKill]) == nil)
        #expect(MemorySizing.advise(requestGB: 4, outcomes: [.memoryKill, .memoryKill]) == nil)
        #expect(
            MemorySizing.advise(requestGB: 4, outcomes: [.memoryKill, .memoryKill, .build]) != nil)
    }

    /// The failure this whole area exists to make legible, turned into a fix.
    @Test("a job killed for memory is told to raise its label")
    func killedBefore() {
        let advice = MemorySizing.advise(
            requestGB: 4, outcomes: [.memoryKill, .build, .memoryKill, .build])
        guard case .killedBefore(let request, let kills, let runs) = advice else {
            Issue.record("two kills in four runs deserves advice: \(String(describing: advice))")
            return
        }
        #expect(request == 4)
        #expect(kills == 2)
        #expect(runs == 4)
        #expect(advice?.summary.contains("mem:") == true)
        #expect(advice?.isWarning == true)
    }

    /// A job that has never been killed needs no opinion, however close to its
    /// limit it appears to run — appearing close is the resting state.
    @Test("a job that has never been killed is left alone")
    func healthyJobIsSilent() {
        #expect(MemorySizing.advise(requestGB: 6, outcomes: [.build, .build, .build]) == nil)
        #expect(MemorySizing.advise(requestGB: 6, outcomes: []) == nil)
    }

    @Test("an unsized job gets no opinion")
    func unsized() {
        #expect(
            MemorySizing.advise(requestGB: 0, outcomes: [.memoryKill, .memoryKill, .memoryKill])
                == nil)
    }

    // MARK: - Telling failures apart

    /// A memory kill and a build failure call for opposite responses, and
    /// arrive looking identical.
    @Test("a memory kill is not a build failure")
    func classifiesFailures() {
        #expect(
            FailureKind.of(reason: "the guest kernel OOM-killed a process in this container: …")
                == .memoryKill)
        #expect(
            FailureKind.of(reason: "the job asks for 32GB, more than the 12GB this node has")
                == .refused)
        #expect(FailureKind.of(reason: "container exited with status 1") == .build)
        #expect(FailureKind.of(reason: nil) == .build)
    }

    @Test("only the node's own faults are labelled as such")
    func buildFailuresAreUnlabelled() {
        #expect(FailureKind.build.label == nil)
        #expect(FailureKind.memoryKill.label != nil)
        #expect(FailureKind.refused.label != nil)
    }
}
