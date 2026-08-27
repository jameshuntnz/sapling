import Foundation
import Testing

@testable import SaplingAgent
@testable import SaplingCore
@testable import SaplingDB

/// A provider that never finishes on its own.
///
/// Stands in for a booted VM whose runner is sitting in "Listening for Jobs"
/// waiting for an assignment GitHub is never going to send — the state the
/// whole cancellation path exists to get out of.
actor HangingProvider: JobProvider {
    nonisolated let platform: JobPlatform
    private var started = false
    private var torndown = false

    init(platform: JobPlatform) { self.platform = platform }

    func hasStarted() -> Bool { started }
    func wasTornDown() -> Bool { torndown }

    nonisolated func preflight() async throws {}
    nonisolated func reapOrphans() async -> [String] { [] }

    func run(_ request: JobRunRequest, events: any EventSink) async throws -> JobOutcome {
        started = true
        do {
            try await Task.sleep(for: .seconds(600))
        } catch {
            // Teardown is deliberately reached on the cancellation path, and
            // deliberately awaited, exactly as the real providers do it.
            torndown = true
            throw error
        }
        return JobOutcome(exitCode: 0)
    }
}

/// Reacting to jobs GitHub has taken back.
@Suite("Cancellation", .serialized)
struct CancellationTests {

    /// Builds an agent wired to a fake GitHub and a fake provider.
    func withAgent<T>(
        fixtures: FakeGitHubFixtures,
        repos: [String] = ["acme/widgets"],
        status: NodeStatus = .online,
        _ body: (NodeAgent, SaplingStore, HangingProvider) async throws -> T
    ) async throws -> T {
        let server = try await FakeGitHubServer.start(fixtures: fixtures)
        var config = SaplingConfig()
        config.node.name = "mini"
        config.github = server.githubConfig()
        config.github.repos = repos
        config.macos.labels = ["self-hosted", "macos"]
        config.linux.labels = ["self-hosted", "linux"]
        // The egress filter shells out to pfctl, which isn't the subject here.
        config.network.blockPrivateRanges = false

        let provider = HangingProvider(platform: .macos)
        let store = try SaplingStore(inMemoryNamed: UUID().uuidString)
        let agent = NodeAgent(
            config: config, store: store, macProvider: provider, linuxProvider: nil)
        try await store.upsertNode(
            Node(
                id: agent.nodeID, name: "mini", platform: "darwin/arm64",
                lastSeenAt: Date(), status: status
            ))

        do {
            let result = try await body(agent, store, provider)
            await server.shutdown()
            return result
        } catch {
            await server.shutdown()
            throw error
        }
    }

    /// One queued macOS job, which GitHub then reports as cancelled.
    func cancelledFixtures(conclusion: String? = "cancelled") -> FakeGitHubFixtures {
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
        fixtures.jobByID = [
            9001: fakeRemoteJob(id: 9001, status: "completed", conclusion: conclusion)
        ]
        return fixtures
    }

    /// The bug this all exists for: a runner waiting on a job GitHub has
    /// cancelled holds its slot until the two-hour job timeout expires.
    @Test("a cancelled job stops its runner instead of waiting out the timeout")
    func cancelledRunningJobIsReleased() async throws {
        try await withAgent(fixtures: cancelledFixtures()) { agent, store, provider in
            // First poll discovers and dispatches; GitHub still says queued.
            try await agent.pollOnce()
            try await waitUntil { await provider.hasStarted() }
            #expect(await agent.activeJobCount() == 1)

            // GitHub's single-job endpoint reports 9001 cancelled, and it is no
            // longer listed as queued — the "cancelled after dispatch" case.
            // This is what the next poll cycle does with what it is holding.
            await agent.reconcileAbandonedJobs(stillQueued: ["acme/widgets": []])

            try await waitUntil { (try? await store.job(id: "9001"))?.status == .failed }
            let job = try #require(try await store.job(id: "9001"))
            #expect(job.status == .failed)
            #expect(job.exitReason?.contains("cancelled") == true)
            #expect(job.completedAt != nil)
            #expect(await provider.wasTornDown())

            // The slot is genuinely back, not merely marked back.
            let slots = try await store.slotsInUse()
            #expect((slots[.macos] ?? 0) == 0)
        }
    }

    /// The cheaper half of the same bug: nothing should provision a VM for a
    /// job that GitHub finished while it sat in our queue.
    @Test("a job cancelled while queued is dropped before it is dispatched")
    func cancelledQueuedJobIsNeverDispatched() async throws {
        var fixtures = cancelledFixtures()
        // Discovery finds nothing, so the stored job looks stale.
        fixtures.queuedRunIDs = []
        try await withAgent(fixtures: fixtures, status: .cordoned) { agent, store, provider in
            try await store.saveJob(
                Job(
                    id: "9001", nodeID: agent.nodeID, repo: "acme/widgets", platform: .macos,
                    labels: ["self-hosted", "macos"], status: .queued, queuedAt: Date()))

            try await agent.pollOnce()

            let job = try #require(try await store.job(id: "9001"))
            #expect(job.status == .failed)
            #expect(job.exitReason?.contains("before it started here") == true)
            #expect(await provider.hasStarted() == false)
        }
    }

    /// GitHub still wants it, so nothing here should touch it.
    @Test("a job GitHub still reports as queued is left alone")
    func liveQueuedJobSurvives() async throws {
        try await withAgent(fixtures: cancelledFixtures(), status: .cordoned) { agent, store, _ in
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
        try await withAgent(fixtures: fixtures, status: .cordoned) { agent, store, _ in
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
        try await withAgent(fixtures: fixtures, status: .cordoned) { agent, store, _ in
            try await store.saveJob(
                Job(
                    id: "9099", nodeID: agent.nodeID, repo: "acme/widgets", platform: .macos,
                    labels: ["self-hosted", "macos"], status: .queued, queuedAt: Date()))

            try await agent.pollOnce()
            let job = try #require(try await store.job(id: "9099"))
            #expect(job.status == .failed)
            #expect(job.exitReason?.contains("no longer exists") == true)
        }
    }
}

/// Poll a condition rather than sleeping a fixed amount.
///
/// The work being waited on crosses an actor and a detached task, so a fixed
/// sleep is either slow or flaky depending on the machine.
func waitUntil(
    timeout: Duration = .seconds(10),
    _ condition: () async -> Bool
) async throws {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(20))
    }
    Issue.record("condition never became true within \(timeout)")
}
