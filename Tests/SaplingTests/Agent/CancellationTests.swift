import Foundation
import Testing

@testable import SaplingAgent
@testable import SaplingCore
@testable import SaplingDB

/// Reacting to jobs GitHub has taken back.
@Suite("Cancellation", .serialized)
struct CancellationTests {

    /// The bug this all exists for: a runner waiting on a job GitHub has
    /// cancelled holds its slot until the two-hour job timeout expires.
    @Test("a cancelled job stops its runner instead of waiting out the timeout")
    func cancelledRunningJobIsReleased() async throws {
        try await withCancellationAgent(fixtures: cancelledFixtures()) { agent, store, provider in
            // First poll discovers and dispatches; GitHub still says queued.
            try await agent.pollOnce()
            try await waitUntil { await provider.hasStarted() }
            #expect(await agent.activeJobCount() == 1)

            // GitHub's single-job endpoint reports 9001 cancelled, and it is no
            // longer listed as queued — the "cancelled after dispatch" case.
            // This is what the next poll cycle does with what it is holding.
            await agent.reconcileAbandonedJobs(stillQueued: ["acme/widgets": []])

            try await waitUntil { (try? await store.job(id: "9001"))?.status == .cancelled }
            let job = try #require(try await store.job(id: "9001"))
            // Cancelled, not failed: nothing here went wrong.
            #expect(job.status == .cancelled)
            #expect(job.exitReason?.contains("cancelled") == true)
            #expect(job.completedAt != nil)
            #expect(await provider.wasTornDown())

            // The slot is genuinely back, not merely marked back.
            let slots = try await store.slotsInUse()
            #expect((slots[.macos] ?? 0) == 0)
        }
    }

    /// The second runner of a job that had already run: a stale `queued`
    /// answer handed it back, and the runner started for the retry waited for
    /// an assignment GitHub had already given to the first one.
    @Test("a job GitHub finished on another runner releases ours, recorded as GitHub saw it")
    func finishedElsewhereIsReleased() async throws {
        var fixtures = cancelledFixtures()
        fixtures.jobByID = [
            9001: fakeRemoteJob(id: 9001, status: "completed", conclusion: "success")
                .replacingOccurrences(of: #""runner_name":null"#, with: #""runner_name":"sap-macos-earlier""#)
        ]
        try await withCancellationAgent(fixtures: fixtures) { agent, store, provider in
            try await agent.pollOnce()
            try await waitUntil { await provider.hasStarted() }

            await agent.reconcileAbandonedJobs(stillQueued: ["acme/widgets": []])

            try await waitUntil { (try? await store.job(id: "9001"))?.status == .completed }
            let job = try #require(try await store.job(id: "9001"))
            #expect(job.exitReason?.contains("sap-macos-earlier") == true)
            #expect(await provider.wasTornDown())
            #expect((try await store.slotsInUse()[.macos] ?? 0) == 0)
        }
    }

    /// GitHub not naming a runner is no evidence it was someone else's, so
    /// a job that may be ours, finishing under its own power, is left to it.
    @Test("a finished job with no runner named is left to finish on its own")
    func finishedWithoutRunnerIsLeftAlone() async throws {
        try await withCancellationAgent(fixtures: cancelledFixtures(conclusion: "success")) {
            agent, store, provider in
            try await agent.pollOnce()
            try await waitUntil { await provider.hasStarted() }

            await agent.reconcileAbandonedJobs(stillQueued: ["acme/widgets": []])

            #expect(try await store.job(id: "9001")?.status == .running)
            #expect(await provider.wasTornDown() == false)
        }
    }

    /// The cheaper half of the same bug: nothing should provision a VM for a
    /// job that GitHub finished while it sat in our queue.
    @Test("a job cancelled while queued is dropped before it is dispatched")
    func cancelledQueuedJobIsNeverDispatched() async throws {
        var fixtures = cancelledFixtures()
        // Discovery finds nothing, so the stored job looks stale.
        fixtures.queuedRunIDs = []
        try await withCancellationAgent(fixtures: fixtures, status: .cordoned) { agent, store, provider in
            try await store.saveJob(
                Job(
                    id: "9001", nodeID: agent.nodeID, repo: "acme/widgets", platform: .macos,
                    labels: ["self-hosted", "macos"], status: .queued, queuedAt: Date()))

            try await agent.pollOnce()

            let job = try #require(try await store.job(id: "9001"))
            #expect(job.status == .cancelled)
            #expect(job.exitReason?.contains("before it started here") == true)
            #expect(await provider.hasStarted() == false)
        }
    }

    /// GitHub still wants it, so nothing here should touch it.
    @Test("a job GitHub still reports as queued is left alone")
    func liveQueuedJobSurvives() async throws {
        try await withCancellationAgent(fixtures: cancelledFixtures(), status: .cordoned) { agent, store, _ in
            try await agent.pollOnce()
            #expect(try await store.job(id: "9001")?.status == .queued)
        }
    }

    /// A poll that couldn't reach a repo knows nothing about that repo's jobs,
    /// and must not mistake silence for cancellation.
    @Test("a repo that fails to poll does not have its jobs retired")
    func unreachableRepoDoesNotRetireJobs() async throws {
        var fixtures = cancelledFixtures()
        fixtures.failingRepos = ["acme/widgets"]
        try await withCancellationAgent(fixtures: fixtures, status: .cordoned) { agent, store, _ in
            try await store.saveJob(
                Job(
                    id: "9001", nodeID: agent.nodeID, repo: "acme/widgets", platform: .macos,
                    labels: ["self-hosted", "macos"], status: .queued, queuedAt: Date()))

            await #expect(throws: (any Error).self) { try await agent.pollOnce() }
            #expect(try await store.job(id: "9001")?.status == .queued)
        }
    }

    /// A job that vanished from GitHub entirely is as gone as a cancelled one.
    @Test("a job GitHub no longer knows about is dropped")
    func deletedJobIsDropped() async throws {
        var fixtures = cancelledFixtures()
        fixtures.queuedRunIDs = []
        // 9099 is in no fixture at all, so the lookup 404s.
        try await withCancellationAgent(fixtures: fixtures, status: .cordoned) { agent, store, _ in
            try await store.saveJob(
                Job(
                    id: "9099", nodeID: agent.nodeID, repo: "acme/widgets", platform: .macos,
                    labels: ["self-hosted", "macos"], status: .queued, queuedAt: Date()))

            try await agent.pollOnce()
            let job = try #require(try await store.job(id: "9099"))
            #expect(job.status == .cancelled)
            #expect(job.exitReason?.contains("no longer exists") == true)
        }
    }
}
