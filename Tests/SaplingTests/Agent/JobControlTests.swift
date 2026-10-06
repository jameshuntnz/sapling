import Foundation
import Testing

@testable import SaplingAgent
@testable import SaplingCore
@testable import SaplingDB

/// Stopping work because a person asked, rather than because GitHub did.
///
/// The distinction matters: the GitHub-driven path only ever releases jobs
/// GitHub has already finished with, so it can be sure nothing is lost. This
/// one is asked to abandon work GitHub still wants, and the behaviours that
/// makes load-bearing — the teardown, and the cancellation sticking across
/// later polls — are what these cover.
@Suite("Job control", .serialized)
struct JobControlTests {

    /// A job GitHub still wants run, which nothing automatic will touch.
    ///
    /// 9001 is reported queued and in progress, so only an explicit ask can
    /// stop it — which is the whole subject here.
    func liveFixtures() -> FakeGitHubFixtures {
        var fixtures = cancelledFixtures()
        fixtures.jobByID = [
            9001: fakeRemoteJob(id: 9001, status: "in_progress", conclusion: nil)
        ]
        return fixtures
    }

    @Test("stopping a running job tears down its environment and frees the slot")
    func stopsRunningJob() async throws {
        try await withCancellationAgent(fixtures: liveFixtures()) { agent, store, provider in
            try await agent.pollOnce()
            try await waitUntil { await provider.hasStarted() }
            #expect(await agent.activeJobCount() == 1)

            let outcome = await agent.cancel(jobID: "9001", reason: "cancelled from the Sapling app")
            #expect(outcome == .stopped)

            try await waitUntil { (try? await store.job(id: "9001"))?.status == .cancelled }
            let job = try #require(try await store.job(id: "9001"))
            #expect(job.exitReason == "cancelled from the Sapling app")
            #expect(job.completedAt != nil)
            // The VM is actually gone, not merely unaccounted for.
            #expect(await provider.wasTornDown())
            #expect((try await store.slotsInUse()[.macos] ?? 0) == 0)
        }
    }

    /// The cancellation has to survive the next poll.
    ///
    /// GitHub goes on offering a job for hours, so a cancel that only held
    /// until the following cycle would look like it silently failed.
    @Test("a cancelled job is not picked back up while GitHub still offers it")
    func cancellationSticksAcrossPolls() async throws {
        try await withCancellationAgent(fixtures: liveFixtures(), status: .cordoned) {
            agent, store, provider in
            try await store.saveJob(
                Job(
                    id: "9001", nodeID: agent.nodeID, repo: "acme/widgets", platform: .macos,
                    labels: ["self-hosted", "macos"], status: .queued, queuedAt: Date()))

            #expect(await agent.cancel(jobID: "9001", reason: "stopped by hand") == .dropped)
            #expect(try await store.job(id: "9001")?.status == .cancelled)

            // GitHub still lists it as queued on this cycle.
            try await agent.pollOnce()

            #expect(try await store.job(id: "9001")?.status == .cancelled)
            #expect(await provider.hasStarted() == false)
        }
    }

    @Test("a queued job is cancelled without provisioning anything")
    func dropsQueuedJob() async throws {
        try await withCancellationAgent(fixtures: liveFixtures(), status: .cordoned) {
            agent, store, provider in
            try await store.saveJob(
                Job(
                    id: "9001", nodeID: agent.nodeID, repo: "acme/widgets", platform: .macos,
                    labels: ["self-hosted", "macos"], status: .queued, queuedAt: Date()))

            #expect(await agent.cancel(jobID: "9001", reason: "stopped by hand") == .dropped)
            #expect(await provider.hasStarted() == false)

            let events = try await store.events(jobID: "9001")
            #expect(events.contains { $0.event == RunEventName.jobCancelled })
        }
    }

    /// Reported rather than silently accepted: a UI that says "cancelled" for a
    /// job that finished on its own teaches you to distrust the button.
    @Test("cancelling a job that already finished changes nothing")
    func finishedJobIsLeftAlone() async throws {
        try await withCancellationAgent(fixtures: liveFixtures(), status: .cordoned) { agent, store, _ in
            try await store.saveJob(
                Job(
                    id: "9001", nodeID: agent.nodeID, repo: "acme/widgets", platform: .macos,
                    labels: ["self-hosted", "macos"], status: .completed, completedAt: Date()))

            #expect(await agent.cancel(jobID: "9001", reason: "too late") == .alreadyFinished(.completed))
            #expect(try await store.job(id: "9001")?.status == .completed)
        }
    }

    @Test("an unknown job is reported as missing rather than invented")
    func unknownJob() async throws {
        try await withCancellationAgent(fixtures: liveFixtures(), status: .cordoned) { agent, _, _ in
            #expect(await agent.cancel(jobID: "nope", reason: "x") == .notFound)
        }
    }
}
