import Foundation
import Testing

@testable import SaplingAgent
@testable import SaplingCore
@testable import SaplingDB

/// A provider that returns immediately, standing in for a runner that has
/// exited cleanly having done work — just not necessarily *this* job's work.
struct ImmediateProvider: JobProvider, Sendable {
    let platform: JobPlatform = .macos
    func preflight() async throws {}
    func reapOrphans() async -> [String] { [] }
    func run(_ request: JobRunRequest, events: any EventSink) async throws -> JobOutcome {
        JobOutcome(exitCode: 0)
    }
}

/// What happens when this node's runner ran somebody else's job.
///
/// Every job carries the same labels, so a JIT runner started for one job
/// takes whichever matching job GitHub hands it. The job we started it for is
/// then still queued, and recording that as a failure blames the node for
/// something that is simply how JIT runners work.
@Suite("Hand-off", .serialized)
struct HandOffTests {

    func withAgent<T>(
        remoteJob: String,
        cancelRunWhenExhausted: Bool = false,
        _ body: (NodeAgent, SaplingStore, FakeGitHubServer) async throws -> T
    ) async throws -> T {
        var fixtures = FakeGitHubFixtures()
        fixtures.queuedRunIDs = [100]
        fixtures.jobsByRun = [
            100: """
            {"jobs":[
              {"id":9001,"run_id":100,"name":"build","status":"queued","conclusion":null,
               "labels":["self-hosted","macos"],"started_at":null,
               "completed_at":null,"runner_name":null}
            ]}
            """
        ]
        fixtures.jobByID = [9001: remoteJob]
        let server = try await FakeGitHubServer.start(fixtures: fixtures)

        var config = SaplingConfig()
        config.node.name = "mini"
        config.github = server.githubConfig()
        config.github.cancelRunWhenExhausted = cancelRunWhenExhausted
        config.macos.labels = ["self-hosted", "macos"]
        config.linux.enabled = false
        config.network.blockPrivateRanges = false

        let store = try SaplingStore(inMemoryNamed: UUID().uuidString)
        let agent = NodeAgent(
            config: config, store: store,
            macProvider: ImmediateProvider(), linuxProvider: nil,
            conclusionAttempts: 1, conclusionRetryDelay: .zero
        )
        try await store.upsertNode(
            Node(
                id: agent.nodeID, name: "mini", platform: "darwin/arm64",
                lastSeenAt: Date(), status: .online
            ))

        do {
            let result = try await body(agent, store, server)
            await server.shutdown()
            return result
        } catch {
            await server.shutdown()
            throw error
        }
    }

    /// GitHub still has the job queued, so our runner cannot have run it.
    @Test("a job the runner never picked up goes back in the queue, not into failures")
    func stillQueuedIsRequeuedNotFailed() async throws {
        let stillQueued = fakeRemoteJob(id: 9001, status: "queued", conclusion: nil)
        try await withAgent(remoteJob: stillQueued) { agent, store, _ in
            try await agent.pollOnce()
            try await waitUntil { await agent.activeJobCount() == 0 }

            let job = try #require(try await store.job(id: "9001"))
            #expect(job.status == .queued)
            #expect(job.exitReason == nil)
            // Its slot went back too.
            #expect(try await store.slotsInUse().isEmpty)

            let events = try await store.events(jobID: "9001").map(\.event)
            #expect(events.contains(RunEventName.jobRequeued))
            #expect(!events.contains(RunEventName.jobFailed))
        }
    }

    /// The same signal with GitHub silent means something really did go wrong.
    @Test("a job GitHub has no answer for is still recorded as failed")
    func unknownStillFails() async throws {
        try await withAgent(remoteJob: fakeRemoteJob(id: 9001, status: "in_progress", conclusion: nil)) {
            agent, store, _ in
            try await agent.pollOnce()
            try await waitUntil { (try? await store.job(id: "9001"))?.status == .failed }
            let job = try #require(try await store.job(id: "9001"))
            #expect(job.exitReason?.contains("without the job completing") == true)
        }
    }

    /// Giving up quietly is the safe default.
    ///
    /// GitHub has no per-job cancel, so the only way to signal it is to cancel
    /// the whole run — which takes the siblings with it. That has to be asked
    /// for explicitly.
    @Test("giving up does not touch GitHub unless the config asks for it")
    func exhaustionIsSilentByDefault() async throws {
        try await withAgent(remoteJob: fakeRemoteJob(id: 9001, status: "queued", conclusion: nil)) {
            agent, store, server in
            let job = Job(
                id: "9001", repo: "acme/widgets", workflowRunID: "100", platform: .macos,
                labels: [], status: .failed)
            try await store.saveJob(job)

            await agent.handleExhaustedJob(job)
            #expect(server.state.cancelledRuns.isEmpty)
            let events = try await store.events(jobID: "9001").map(\.event)
            #expect(events.contains(RunEventName.jobFailed))
        }
    }

    @Test("giving up cancels the run when the config asks for it")
    func exhaustionCancelsRunWhenConfigured() async throws {
        try await withAgent(
            remoteJob: fakeRemoteJob(id: 9001, status: "queued", conclusion: nil),
            cancelRunWhenExhausted: true
        ) { agent, store, server in
            let job = Job(
                id: "9001", repo: "acme/widgets", workflowRunID: "100", platform: .macos,
                labels: [], status: .failed)
            try await store.saveJob(job)

            await agent.handleExhaustedJob(job)
            #expect(server.state.cancelledRuns == [100])
            let details = try await store.events(jobID: "9001").compactMap(\.detail)
            #expect(details.contains { $0.contains("along with its other jobs") })
        }
    }
}
