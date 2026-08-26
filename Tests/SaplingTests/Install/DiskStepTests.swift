import Foundation
import Testing

@testable import SaplingCore
@testable import SaplingInstall

/// A base image is 80GB+ on a 256GB disk, so these thresholds decide whether a node is usable.
///
/// The assessment is separated from the measuring so it can be tested without putting a real disk into each
/// state.
@Suite("Disk assessment")
struct DiskStepTests {
    static let gb: Int64 = 1_073_741_824

    @Test("reports plenty of space as fine")
    func healthy() {
        let state = DiskStep.assess(freeBytes: 120 * Self.gb, stagingBytes: 0, pullRunning: false)
        #expect(state.isOK)
        #expect(state.summary.contains("120GB"))
    }

    /// Enough to run jobs, not enough to pull another 80GB image — worth
    /// saying before someone starts a download that can't finish.
    @Test("distinguishes 'can run jobs' from 'can pull an image'")
    func lowButUsable() {
        let state = DiskStep.assess(freeBytes: 25 * Self.gb, stagingBytes: 0, pullRunning: false)
        #expect(state.isOK)
        #expect(state.summary.contains("not enough to pull"))
    }

    @Test("fails when jobs would run out of space partway through")
    func critical() {
        let state = DiskStep.assess(freeBytes: 5 * Self.gb, stagingBytes: 0, pullRunning: false)
        #expect(!state.isOK)
        if case .failed(let reason) = state {
            #expect(reason.contains("jobs will fail"))
        } else {
            Issue.record("expected .failed, got \(state)")
        }
    }

    /// `tart prune` clears the OCI cache but not this, so an interrupted pull
    /// leaves tens of gigabytes that nothing reclaims.
    @Test("flags staging data left by an interrupted pull")
    func staleStaging() {
        let state = DiskStep.assess(freeBytes: 100 * Self.gb, stagingBytes: 40 * Self.gb, pullRunning: false)
        if case .fixable(let summary) = state {
            #expect(summary.contains("40GB"))
            #expect(summary.contains("staging"))
        } else {
            Issue.record("expected .fixable, got \(state)")
        }
    }

    /// Staging data during a pull is the pull working, not a leak — and
    /// deleting it would destroy the download.
    @Test("leaves staging data alone while a pull is running")
    func stagingDuringPull() {
        let state = DiskStep.assess(freeBytes: 100 * Self.gb, stagingBytes: 40 * Self.gb, pullRunning: true)
        #expect(state.isOK)
    }

    @Test("ignores a trivial amount of staging data")
    func trivialStaging() {
        let state = DiskStep.assess(freeBytes: 100 * Self.gb, stagingBytes: 1024, pullRunning: false)
        #expect(state.isOK)
    }

    /// Low disk outranks stale staging only when there's no staging to clear;
    /// otherwise clearing it is the actionable advice.
    @Test("prefers the actionable message when both apply")
    func staleStagingOnALowDisk() {
        let state = DiskStep.assess(freeBytes: 5 * Self.gb, stagingBytes: 40 * Self.gb, pullRunning: false)
        if case .fixable(let summary) = state {
            #expect(summary.contains("staging"))
        } else {
            Issue.record("clearing staging is the fix that recovers the space")
        }
    }

    @Test("formats sizes readably at both ends of the scale")
    func formatting() {
        #expect(DiskStep.format(120 * Self.gb) == "120GB")
        #expect(DiskStep.format(Self.gb * 3 / 2) == "1.5GB")
    }
}
