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

/// Builds an agent wired to a fake GitHub and a fake provider.
///
/// A free function rather than a method on one suite: cancellation driven by
/// GitHub and cancellation asked for by a person need exactly the same rig, and
/// a copy of it in each would drift.
func withCancellationAgent<T>(
    fixtures: FakeGitHubFixtures,
    repos: [String] = ["acme/widgets"],
    status: NodeStatus = .online,
    _ body: (NodeAgent, SaplingStore, HangingProvider) async throws -> T
) async throws -> T {
    let server = try await FakeGitHubServer.start(fixtures: fixtures)
    var config = SaplingConfig()
    // Stated, not derived: these tests are about cancellation, and must not
    // pass or fail on how much RAM the machine running them happens to have.
    config.node.memoryBudgetOverrideGB = 64
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
