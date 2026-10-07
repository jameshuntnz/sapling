import Foundation
import Testing

@testable import SaplingAgent
@testable import SaplingCore
@testable import SaplingDB

/// A JIT runner takes whichever queued job matches its labels, so the job it
/// actually runs has to be learned from GitHub, not assumed.
@Suite("Runner assignment", .serialized)
struct AssignmentTests {
    @Test("records the job GitHub gave this node's runner")
    func recordsAssignedJob() async throws {
        var fixtures = FakeGitHubFixtures()
        fixtures.queuedRunIDs = []
        fixtures.inProgressRunIDs = [100]
        fixtures.jobsByRun = [100: FakeGitHubFixtureLibrary.mixedStatuses]
        let server = try await FakeGitHubServer.start(fixtures: fixtures)
        defer { Task { await server.shutdown() } }

        var config = SaplingConfig()
        config.github = server.githubConfig()
        let store = try SaplingStore(inMemoryNamed: UUID().uuidString)
        let agent = NodeAgent(config: config, store: store)
        try await store.upsertNode(
            Node(
                id: agent.nodeID, name: "mini", platform: "darwin/arm64",
                lastSeenAt: Date(), status: .cordoned))

        // Started for 8000, but GitHub handed its runner 9002 instead.
        try await store.saveJob(
            Job(
                id: "8000", repo: "acme/widgets", workflowRunID: "50", platform: .linux,
                labels: ["self-hosted", "linux"], status: .running))
        await agent.setRunnerNameForTesting(jobID: "8000", runnerName: "sap-linux-1")

        try await agent.pollOnce()

        let job = try #require(try await store.job(id: "8000"))
        #expect(job.assignedJobID == "9002")
        #expect(job.assignedRunID == "100")
    }

    @Test("a job returned to the queue forgets its runner's assignment")
    func requeueClearsAssignment() async throws {
        let store = try SaplingStore(inMemoryNamed: UUID().uuidString)
        try await store.saveJob(
            Job(
                id: "8000", repo: "acme/widgets", workflowRunID: "50", platform: .linux,
                labels: ["self-hosted", "linux"], status: .running))
        try await store.setJobAssignment(id: "8000", jobID: "9002", runID: "100")

        try await store.returnJobToQueue(id: "8000", maxAttempts: 3)

        let job = try #require(try await store.job(id: "8000"))
        #expect(job.assignedJobID == nil)
        #expect(job.assignedRunID == nil)
    }
}

extension NodeAgent {
    /// Stands in for `execute` having minted a runner for a job.
    func setRunnerNameForTesting(jobID: String, runnerName: String) {
        runnerNames[jobID] = runnerName
    }
}
