import Foundation
import Testing

@testable import SaplingCore

@Suite("Job status")
struct JobStatusTests {
    @Test("only in-flight states hold a slot")
    func slotOccupancy() {
        #expect(JobStatus.provisioning.occupiesSlot)
        #expect(JobStatus.running.occupiesSlot)
        #expect(JobStatus.cleanup.occupiesSlot)
        #expect(!JobStatus.queued.occupiesSlot)
        #expect(!JobStatus.completed.occupiesSlot)
        #expect(!JobStatus.failed.occupiesSlot)
    }
}
