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

/// Retrying because a person asked, which answers to different rules.
@Suite("Manual retry")
struct ManualRetryTests {

    func makeStore() throws -> SaplingStore {
        try SaplingStore(inMemoryNamed: UUID().uuidString)
    }

    func job(_ store: SaplingStore, status: JobStatus, attempts: Int = 0) async throws {
        try await store.saveJob(
            Job(
                id: "1", repo: "acme/widgets", workflowRunID: "100", platform: .macos,
                labels: ["self-hosted", "macos"], status: status,
                completedAt: status.isTerminal ? Date() : nil,
                exitReason: status.isTerminal ? "VM would not boot" : nil))
        for _ in 0..<attempts {
            try await store.claimJob(id: "1")
            try await store.updateJobStatus(id: "1", status: status, completedAt: Date())
        }
    }

    /// The whole reason this exists rather than reusing `requeueJob`: a button
    /// that silently does nothing on the third press is worse than no button.
    @Test("retrying ignores the attempt ceiling the poll loop respects")
    func bypassesTheCeiling() async throws {
        let store = try makeStore()
        try await job(store, status: .failed, attempts: 4)
        // The automatic path has given up on this job for good.
        #expect(
            try await store.requeueJob(id: "1", failedBefore: Date(), maxAttempts: 3) == .notEligible)

        #expect(try await store.retryJob(id: "1") == .queued)
        let queued = try #require(try await store.job(id: "1"))
        #expect(queued.status == .queued)
        #expect(queued.completedAt == nil)
        #expect(queued.exitReason == nil)

        // The count starts over, so the ceiling applies afresh to what follows.
        #expect(try await store.claimJob(id: "1") == 1)
    }

    /// A cancellation is GitHub's decision, which only a person may overrule.
    ///
    /// The node must not do it unprompted. If GitHub really has finished with
    /// the job, the poll loop retires it again before anything is provisioned.
    @Test("a cancelled job can be retried by hand even though the poll loop won't")
    func cancelledJobIsRetryable() async throws {
        let store = try makeStore()
        try await job(store, status: .cancelled)
        #expect(
            try await store.requeueJob(id: "1", failedBefore: Date(), maxAttempts: 3) == .notEligible)
        #expect(try await store.retryJob(id: "1") == .queued)
        #expect(try await store.job(id: "1")?.status == .queued)
    }

    /// Queueing a job whose VM is still alive is how one job gets two.
    @Test("a job still holding a slot is refused rather than queued twice")
    func activeJobIsRefused() async throws {
        let store = try makeStore()
        try await job(store, status: .running)
        #expect(try await store.retryJob(id: "1") == .stillActive(.running))
        #expect(try await store.job(id: "1")?.status == .running)
    }

    @Test("an unknown job is reported as missing")
    func unknownJob() async throws {
        #expect(try await makeStore().retryJob(id: "nope") == .notFound)
    }
}
