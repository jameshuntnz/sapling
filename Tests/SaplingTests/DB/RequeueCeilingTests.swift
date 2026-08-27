import Foundation
import Testing

@testable import SaplingCore
@testable import SaplingDB

/// The attempt ceiling on requeueing.
///
/// Without one, a job GitHub keeps reporting as queued was retried every
/// cooldown until GitHub's own timeout hours later, cloning a VM each time.
@Suite("Requeue ceiling")
struct RequeueCeilingTests {

    func makeStore() throws -> SaplingStore {
        try SaplingStore(inMemoryNamed: UUID().uuidString)
    }

    func failedJob(_ store: SaplingStore, id: String = "1") async throws {
        try await store.saveJob(
            Job(
                id: id, repo: "acme/widgets", workflowRunID: "100", platform: .macos,
                labels: ["self-hosted", "macos"], status: .failed, completedAt: .distantPast,
                exitReason: "VM would not boot"))
    }

    /// The whole point: three starts, then it stops.
    @Test("a job that keeps failing is given up on rather than retried forever")
    func requeueStopsAtTheCeiling() async throws {
        let store = try makeStore()
        try await failedJob(store)
        let past = Date().addingTimeInterval(3600)

        // Attempt 1 was the original dispatch, so two more are offered.
        #expect(
            try await store.requeueJob(id: "1", failedBefore: past, maxAttempts: 3) == .requeued(attempt: 1))
        #expect(try await store.claimJob(id: "1") == 1)
        try await store.updateJobStatus(id: "1", status: .failed, completedAt: .distantPast)

        #expect(
            try await store.requeueJob(id: "1", failedBefore: past, maxAttempts: 3) == .requeued(attempt: 2))
        #expect(try await store.claimJob(id: "1") == 2)
        try await store.updateJobStatus(id: "1", status: .failed, completedAt: .distantPast)

        #expect(
            try await store.requeueJob(id: "1", failedBefore: past, maxAttempts: 3) == .requeued(attempt: 3))
        #expect(try await store.claimJob(id: "1") == 3)
        try await store.updateJobStatus(
            id: "1", status: .failed, exitReason: "VM would not boot", completedAt: .distantPast)

        #expect(
            try await store.requeueJob(id: "1", failedBefore: past, maxAttempts: 3) == .exhausted(attempts: 3)
        )
        let job = try #require(try await store.job(id: "1"))
        #expect(job.status == .failed)
        #expect(job.exitReason?.contains("gave up after 3 attempts") == true)
        // The last failure survives alongside it, because that's the half that
        // says what to actually fix.
        #expect(job.exitReason?.contains("VM would not boot") == true)
    }

    /// GitHub goes on offering the job for hours after we stop trying, so
    /// exhaustion has to be reported once, not every thirty seconds.
    @Test("giving up is reported exactly once")
    func exhaustionIsReportedOnce() async throws {
        let store = try makeStore()
        try await failedJob(store)
        let past = Date().addingTimeInterval(3600)

        for _ in 0..<3 {
            _ = try await store.requeueJob(id: "1", failedBefore: past, maxAttempts: 3)
            _ = try await store.claimJob(id: "1")
            try await store.updateJobStatus(id: "1", status: .failed, completedAt: .distantPast)
        }
        #expect(
            try await store.requeueJob(id: "1", failedBefore: past, maxAttempts: 3) == .exhausted(attempts: 3)
        )
        #expect(try await store.requeueJob(id: "1", failedBefore: past, maxAttempts: 3) == .notEligible)
        #expect(try await store.requeueJob(id: "1", failedBefore: past, maxAttempts: 3) == .notEligible)
    }

    /// A job failing instantly must not spin through its attempts in a second.
    @Test("the cooldown still holds a fresh failure back")
    func cooldownIsRespected() async throws {
        let store = try makeStore()
        try await store.saveJob(
            Job(
                id: "1", repo: "acme/widgets", platform: .macos, labels: [], status: .failed,
                completedAt: Date()))
        let cutoff = Date().addingTimeInterval(-120)
        #expect(try await store.requeueJob(id: "1", failedBefore: cutoff, maxAttempts: 3) == .notEligible)
    }

    /// GitHub's decision stands; retrying it would just re-provision a VM for
    /// work that has been called off.
    @Test("a cancelled job is never retried")
    func cancelledIsNotRetried() async throws {
        let store = try makeStore()
        try await store.saveJob(
            Job(
                id: "1", repo: "acme/widgets", platform: .macos, labels: [], status: .cancelled,
                completedAt: .distantPast))
        let past = Date().addingTimeInterval(3600)
        #expect(try await store.requeueJob(id: "1", failedBefore: past, maxAttempts: 3) == .notEligible)
        #expect(try await store.job(id: "1")?.status == .cancelled)
    }

    /// The runner ran a different job, so this one goes straight back without
    /// waiting out a cooldown it did nothing to deserve.
    @Test("a job handed back skips the cooldown but not the ceiling")
    func handBackSkipsCooldown() async throws {
        let store = try makeStore()
        try await store.saveJob(
            Job(
                id: "1", repo: "acme/widgets", platform: .macos, labels: [], status: .running,
                startedAt: Date()))

        #expect(try await store.returnJobToQueue(id: "1", maxAttempts: 3) == .requeued(attempt: 1))
        #expect(try await store.job(id: "1")?.status == .queued)
        #expect(try await store.job(id: "1")?.startedAt == nil)

        for _ in 0..<3 { _ = try await store.claimJob(id: "1") }
        #expect(try await store.returnJobToQueue(id: "1", maxAttempts: 3) == .exhausted(attempts: 3))
    }

    /// A slot released is a slot free; a cancelled job must not keep holding one.
    @Test("a cancelled job holds no slot and is terminal")
    func cancelledIsTerminalAndFree() async throws {
        #expect(JobStatus.cancelled.isTerminal)
        #expect(!JobStatus.cancelled.occupiesSlot)
        #expect(!JobStatus.cancelled.isRetryable)

        let store = try makeStore()
        try await store.saveJob(
            Job(id: "1", repo: "acme/widgets", platform: .macos, labels: [], status: .cancelled))
        #expect(try await store.slotsInUse().isEmpty)
    }
}
