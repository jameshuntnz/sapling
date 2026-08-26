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
    static let port = 18803

    func withFakeGitHub<T>(
        labels: (macos: [String], linux: [String]) = (
            ["self-hosted", "macos"], ["self-hosted", "linux", "arm64"]
        ),
        _ body: (NodeAgent, SaplingStore) async throws -> T
    ) async throws -> T {
        var fixtures = FakeGitHubFixtures()
        fixtures.queuedRunIDs = [100]
        fixtures.jobsByRun = [100: FakeGitHubFixtureLibrary.threePlatforms]
        let server = try await FakeGitHubServer.start(port: Self.port, fixtures: fixtures)

        var config = SaplingConfig()
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
