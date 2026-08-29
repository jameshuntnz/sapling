import Foundation
import Testing

@testable import SaplingAgent
@testable import SaplingCore
@testable import SaplingDB

/// The poll half of the agent loop, driven against the shared fake GitHub API.
///
/// The node stays cordoned throughout: discovery and dispatch are deliberately
/// separate (a cordoned node still shows what's waiting), so this exercises the
/// whole poll-to-store path without needing a VM to dispatch to.
@Suite("Poll loop", .serialized)
struct PollLoopTests {

    func withFakeGitHub<T>(
        labels: (macos: [String], linux: [String]) = (
            ["self-hosted", "macos"], ["self-hosted", "linux", "arm64"]
        ),
        _ body: (NodeAgent, SaplingStore) async throws -> T
    ) async throws -> T {
        var fixtures = FakeGitHubFixtures()
        fixtures.queuedRunIDs = [100]
        fixtures.jobsByRun = [100: FakeGitHubFixtureLibrary.threePlatforms]
        let server = try await FakeGitHubServer.start(fixtures: fixtures)

        var config = SaplingConfig()
        // Stated, not derived: dispatch must not depend on how much RAM
        // the machine running the suite happens to have.
        config.node.memoryBudgetOverrideGB = 64
        config.node.name = "mini"
        config.github = server.githubConfig()
        config.macos.labels = labels.macos
        config.linux.labels = labels.linux

        let store = try SaplingStore(inMemoryNamed: UUID().uuidString)
        let agent = NodeAgent(config: config, store: store)
        try await store.upsertNode(
            Node(
                id: agent.nodeID, name: "mini", platform: "darwin/arm64",
                lastSeenAt: Date(), status: .cordoned
            ))

        do {
            let result = try await body(agent, store)
            await server.shutdown()
            return result
        } catch {
            await server.shutdown()
            throw error
        }
    }

    /// End to end: a fork's run leaves no trace in the job table and nothing
    /// is sent to GitHub about it.
    ///
    /// Recording one as a failed job was considered and rejected. A public
    /// repository can carry more fork pull requests than real work, and filing
    /// each as a failure would bury the node's actual jobs in the UI and count
    /// a working node as a broken one — the argument `JobStatus.cancelled`
    /// already makes for itself.
    @Test("a fork's run leaves no job behind and cancels nothing")
    func refusesForkRuns() async throws {
        var fixtures = FakeGitHubFixtures()
        fixtures.queuedRunIDs = [100]
        fixtures.jobsByRun = [100: FakeGitHubFixtureLibrary.threePlatforms]
        fixtures.forkRunIDs = [100]
        let server = try await FakeGitHubServer.start(fixtures: fixtures)

        var config = SaplingConfig()
        config.node.memoryBudgetOverrideGB = 64
        config.node.name = "mini"
        config.github = server.githubConfig()
        // On, to prove the refusal path does not reach it: cancelling is a
        // whole-run operation, and cancelling a contributor's pull request
        // would take its GitHub-hosted jobs down with ours.
        config.github.cancelRunWhenExhausted = true

        let store = try SaplingStore(inMemoryNamed: UUID().uuidString)
        let agent = NodeAgent(config: config, store: store)
        try await store.upsertNode(
            Node(
                id: agent.nodeID, name: "mini", platform: "darwin/arm64",
                lastSeenAt: Date(), status: .cordoned
            ))

        try await agent.pollOnce()

        #expect(try await store.jobs().isEmpty)
        #expect(server.state.cancelledRuns.isEmpty, "must not cancel a fork's run")
        #expect(server.state.jobsRequests.isEmpty, "must not open a fork's run at all")
        #expect(try await store.state(SaplingStore.StateKey.forkRunsRefused) == "1")

        // Said once, not once a cycle: the run stays queued on GitHub until
        // its own timeout, so every poll sees it again.
        try await agent.pollOnce()
        #expect(try await store.state(SaplingStore.StateKey.forkRunsRefused) == "1")

        await server.shutdown()
    }

    @Test("records queued jobs this node can run, and skips ones it can't")
    func discoversMatchingJobs() async throws {
        try await withFakeGitHub { agent, store in
            try await agent.pollOnce()

            let jobs = try await store.jobs()
            #expect(Set(jobs.map(\.id)) == ["9001", "9002"])

            let macJob = try #require(jobs.first { $0.id == "9001" })
            #expect(macJob.platform == .macos)
            #expect(macJob.repo == "acme/widgets")
            #expect(macJob.workflowRunID == "100")
            #expect(macJob.name == "build")
            #expect(macJob.status == .queued)

            #expect(jobs.first { $0.id == "9002" }?.platform == .linux)
            // The Windows job matches no configured label set.
            #expect(!jobs.contains { $0.id == "9003" })
        }
    }

    /// The same job comes back on every poll until it starts; re-recording it
    /// would multiply the queue.
    @Test("polling repeatedly does not duplicate jobs")
    func pollingIsIdempotent() async throws {
        try await withFakeGitHub { agent, store in
            try await agent.pollOnce()
            try await agent.pollOnce()
            try await agent.pollOnce()
            #expect(try await store.jobs().count == 2)
        }
    }

    /// A cordoned node still surfaces what's waiting, so the UI stays useful
    /// while you're holding work back.
    @Test("a cordoned node discovers without dispatching")
    func cordonedDiscoversButDoesNotDispatch() async throws {
        try await withFakeGitHub { agent, store in
            try await agent.pollOnce()
            let jobs = try await store.jobs()
            #expect(jobs.count == 2)
            #expect(jobs.allSatisfy { $0.status == .queued })

            // Nothing claimed a slot.
            let slots = try await store.slotsInUse()
            #expect((slots[.macos] ?? 0) == 0)
            #expect((slots[.linux] ?? 0) == 0)
            #expect(await agent.activeJobCount() == 0)
        }
    }

    @Test("a node offering no matching labels records nothing")
    func noMatchingLabels() async throws {
        try await withFakeGitHub(labels: (["macos-14"], ["ubuntu-22"])) { agent, store in
            try await agent.pollOnce()
            #expect(try await store.jobs().isEmpty)
        }
    }

    @Test("cordon and uncordon move the node through the store")
    func statusTransitions() async throws {
        try await withFakeGitHub { agent, _ in
            #expect(await agent.currentStatus() == .cordoned)
            try await agent.setStatus(.online)
            #expect(await agent.currentStatus() == .online)
            try await agent.setStatus(.draining)
            #expect(await agent.currentStatus() == .draining)
        }
    }
}

/// A runner exiting cleanly is not evidence the job ran.
///
/// A deprecated runner exits 0 having refused to work, and reporting that as success is the worst failure
/// available: the build looks green and nothing was built.
@Suite("Job conclusion", .serialized)
struct JobConclusionTests {

    func withFakeGitHub<T>(_ body: (NodeAgent) async throws -> T) async throws -> T {
        var fixtures = FakeGitHubFixtures()
        fixtures.queuedRunIDs = [100]
        fixtures.jobsByRun = [100: FakeGitHubFixtureLibrary.threePlatforms]
        let server = try await FakeGitHubServer.start(fixtures: fixtures)

        var config = SaplingConfig()
        // Stated, not derived: dispatch must not depend on how much RAM
        // the machine running the suite happens to have.
        config.node.memoryBudgetOverrideGB = 64
        config.node.name = "mini"
        config.github = server.githubConfig()

        let store = try SaplingStore(inMemoryNamed: UUID().uuidString)
        let agent = NodeAgent(config: config, store: store)
        do {
            let result = try await body(agent)
            await server.shutdown()
            return result
        } catch {
            await server.shutdown()
            throw error
        }
    }

    /// Job 9001 is reported completed/success by the fake API.
    @Test("reports success when GitHub agrees the job succeeded")
    func successWhenGitHubAgrees() async throws {
        try await withFakeGitHub { agent in
            let job = Job(
                id: "9001", repo: "acme/widgets", platform: .macos, labels: [], status: .running)
            guard case .success = await agent.remoteConclusion(for: job, attempts: 1, retryDelay: .zero)
            else {
                Issue.record("expected .success")
                return
            }
        }
    }

    /// Job 424242 is unknown to the fake API, so there is nothing to go on.
    @Test("reports unknown when GitHub has no result")
    func unknownWhenGitHubHasNoResult() async throws {
        try await withFakeGitHub { agent in
            let job = Job(
                id: "424242", repo: "acme/widgets", platform: .macos, labels: [], status: .running)
            guard case .unknown = await agent.remoteConclusion(for: job, attempts: 1, retryDelay: .zero)
            else {
                Issue.record("a job GitHub has no result for must not read as finished")
                return
            }
        }
    }

    @Test("a non-numeric job id can never read as success")
    func rejectsUnusableID() async throws {
        try await withFakeGitHub { agent in
            let job = Job(
                id: "not-a-number", repo: "acme/widgets", platform: .macos, labels: [],
                status: .running)
            guard case .unknown = await agent.remoteConclusion(for: job, attempts: 1, retryDelay: .zero)
            else {
                Issue.record("expected .unknown")
                return
            }
        }
    }
}
