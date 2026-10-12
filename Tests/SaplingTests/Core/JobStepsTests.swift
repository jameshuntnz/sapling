import Foundation
import Testing

@testable import SaplingCore

@Suite("Job steps")
struct JobStepsTests {
    @Test("folds GitHub's status and conclusion into one state")
    func state() {
        #expect(JobStep(number: 1, name: "a", status: "queued").state == .pending)
        #expect(JobStep(number: 1, name: "a", status: "in_progress").state == .running)
        #expect(JobStep(number: 1, name: "a", status: "completed", conclusion: "success").state == .succeeded)
        #expect(JobStep(number: 1, name: "a", status: "completed", conclusion: "failure").state == .failed)
        #expect(JobStep(number: 1, name: "a", status: "completed", conclusion: "skipped").state == .skipped)
        #expect(
            JobStep(number: 1, name: "a", status: "completed", conclusion: "cancelled").state == .cancelled)
    }

    @Test("settled only once every step has completed")
    func settled() {
        let done = JobStep(number: 1, name: "a", status: "completed", conclusion: "success")
        let running = JobStep(number: 2, name: "b", status: "in_progress")
        #expect(!JobStepsResponse(jobID: "1").isSettled)
        #expect(!JobStepsResponse(jobID: "1", steps: [done, running]).isSettled)
        #expect(JobStepsResponse(jobID: "1", steps: [done]).isSettled)
    }

    @Test("a running step's duration runs to now")
    func duration() {
        let start = Date(timeIntervalSince1970: 1000)
        let running = JobStep(number: 1, name: "a", status: "in_progress", startedAt: start)
        #expect(running.duration(now: start.addingTimeInterval(42)) == 42)
        #expect(JobStep(number: 1, name: "a", status: "queued").duration() == nil)
    }
}
