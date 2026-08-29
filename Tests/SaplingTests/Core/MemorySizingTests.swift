import Foundation
import Testing

@testable import SaplingCore

/// A `mem:` label is a number somebody guessed; this reads it off history.
///
/// The 6GB the Android build asks for was found by running it by hand in
/// containers on the node at 4GB and 6GB and reading `memory.peak`. Sapling
/// already measures that on every run, so the second time anyone asks the
/// question it should be a readout rather than an afternoon.
@Suite("Memory sizing advice")
struct MemorySizingTests {
    func gb(_ value: Double) -> Int64 { Int64(value * 1_073_741_824) }

    /// One run is an anecdote and two is a coincidence.
    ///
    /// A build's peak moves with what it happens to compile, and advising a
    /// smaller label off a single quiet run causes the OOM it meant to prevent.
    @Test("says nothing until there is enough history to mean it")
    func needsHistory() {
        #expect(MemorySizing.advise(requestGB: 8, peaks: [gb(1)]) == nil)
        #expect(MemorySizing.advise(requestGB: 8, peaks: [gb(1), gb(1)]) == nil)
        #expect(MemorySizing.advise(requestGB: 8, peaks: [gb(1), gb(1), gb(1)]) != nil)
    }

    @Test("a job reserving far more than it uses is told what to reserve")
    func oversized() {
        let advice = MemorySizing.advise(requestGB: 8, peaks: [gb(2.0), gb(2.4), gb(1.9)])
        guard case .oversized(let request, let peak, let suggest, let runs) = advice else {
            Issue.record("2.4GB peak against an 8GB request is oversized: \(String(describing: advice))")
            return
        }
        #expect(request == 8)
        #expect(peak == 3)  // rounded up from 2.4
        #expect(suggest == 4)  // 3 * 1.3, rounded up
        #expect(runs == 3)
        #expect(advice?.summary.contains("mem:4") == true)
    }

    /// The peaks are a floor, not a ceiling — the next run may compile more.
    @Test("the suggestion keeps headroom above the worst run seen")
    func keepsHeadroom() {
        let advice = MemorySizing.advise(requestGB: 12, peaks: [gb(4), gb(4), gb(4)])
        guard case .oversized(_, _, let suggest, _) = advice else {
            Issue.record("expected advice: \(String(describing: advice))")
            return
        }
        #expect(suggest > 4)
    }

    /// The failure mode that started all of this, caught before it happens.
    @Test("a job running close to its limit is warned, not trimmed")
    func tight() {
        let advice = MemorySizing.advise(requestGB: 6, peaks: [gb(5.6), gb(5.8), gb(5.5)])
        guard case .tight(let request, let peak, _) = advice else {
            Issue.record("5.8GB against 6GB is at risk: \(String(describing: advice))")
            return
        }
        #expect(request == 6)
        #expect(peak == 6)
        #expect(advice?.isWarning == true)
        #expect(advice?.summary.contains("OOM") == true)
    }

    /// Advice nobody would act on is noise on a machine rationing whole GB.
    @Test("a saving too small to matter is not mentioned")
    func staysQuietWhenTheSavingIsTrivial() {
        // 2GB peak, 4GB request: suggesting 3GB frees one gigabyte.
        #expect(MemorySizing.advise(requestGB: 4, peaks: [gb(2), gb(2), gb(2)]) == nil)
    }

    @Test("a job with no measurements gets no opinion")
    func noMeasurements() {
        #expect(MemorySizing.advise(requestGB: 8, peaks: []) == nil)
        #expect(MemorySizing.advise(requestGB: 0, peaks: [gb(1), gb(1), gb(1)]) == nil)
        #expect(MemorySizing.advise(requestGB: 8, peaks: [0, 0, 0]) == nil)
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
