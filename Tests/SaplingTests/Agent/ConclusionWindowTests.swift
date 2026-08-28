import Foundation
import Testing

@testable import SaplingAgent
@testable import SaplingCore
@testable import SaplingDB

/// A runner exiting is not a job ending.
///
/// Post-steps and log upload run after it, and GitHub records the conclusion
/// after those. Five attempts three seconds apart gave that fifteen seconds,
/// and it was not enough: an iOS job GitHub concluded as `failure`, and a
/// release that published successfully, were both recorded here as "runner
/// exited without the job completing" — work that finished, filed as an
/// unexplained runner failure, inflating the node's failure count.
@Suite("Conclusion window")
struct ConclusionWindowTests {
    static func job(id: String) -> Job {
        Job(id: id, repo: "acme/widgets", platform: .macos, labels: [], status: .running)
    }

    static func remoteJob(id: Int64, status: String, conclusion: String? = nil) -> String {
        let concluded = conclusion.map { "\"\($0)\"" } ?? "null"
        return """
            {"id":\(id),"run_id":100,"name":"build","status":"\(status)","conclusion":\(concluded),
             "labels":["self-hosted","macos"],"started_at":"2026-08-24T10:00:00Z",
             "completed_at":null,"runner_name":"sap-macos-abc"}
            """
    }

    static func withGitHub(
        jobs: [Int64: String], _ body: (NodeAgent) async throws -> Void
    ) async throws {
        var fixtures = FakeGitHubFixtures()
        fixtures.jobByID = jobs
        let server = try await FakeGitHubServer.start(fixtures: fixtures)
        var config = SaplingConfig()
        config.node.name = "mini"
        config.github = server.githubConfig()
        let agent = NodeAgent(
            config: config, store: try SaplingStore(inMemoryNamed: UUID().uuidString))
        do {
            try await body(agent)
            await server.shutdown()
        } catch {
            await server.shutdown()
            throw error
        }
    }

    /// The grace is spent only on a job GitHub says is still going.
    ///
    /// A job it has no answer for at all still gives up promptly.
    @Test("a job GitHub is still running is waited for, a silent one is not")
    func gracePaidOnlyForRunningJobs() async throws {
        try await Self.withGitHub(jobs: [
            7001: Self.remoteJob(id: 7001, status: "in_progress")
        ]) { agent in
            let startedRunning = ContinuousClock.now
            _ = await agent.remoteConclusion(
                for: Self.job(id: "7001"),
                attempts: 1, retryDelay: .milliseconds(10), grace: .milliseconds(200))
            let runningElapsed = ContinuousClock.now - startedRunning

            let startedSilent = ContinuousClock.now
            _ = await agent.remoteConclusion(
                for: Self.job(id: "404404"),
                attempts: 1, retryDelay: .milliseconds(10), grace: .milliseconds(200))
            let silentElapsed = ContinuousClock.now - startedSilent

            #expect(runningElapsed >= .milliseconds(180), "an in-progress job must be waited for")
            #expect(silentElapsed < .milliseconds(150), "a job GitHub cannot see must not burn the grace")
        }
    }

    /// The case that was being mislabelled: GitHub finishes the job while we
    /// are still asking, and the answer it gives is the one recorded.
    @Test("a conclusion that arrives during the grace is the one recorded")
    func concludedDuringGrace() async throws {
        try await Self.withGitHub(jobs: [
            7002: Self.remoteJob(id: 7002, status: "completed", conclusion: "failure")
        ]) { agent in
            let result = await agent.remoteConclusion(
                for: Self.job(id: "7002"),
                attempts: 1, retryDelay: .milliseconds(10), grace: .milliseconds(200))
            #expect(result == .concluded("failure"))
        }
    }

    /// A job still *queued* after our runner exited means the runner ran
    /// something else — a different case, and not one the grace applies to.
    @Test("a still-queued job is handed back, without spending the grace")
    func queuedIsNotGraced() async throws {
        try await Self.withGitHub(jobs: [
            7003: Self.remoteJob(id: 7003, status: "queued")
        ]) { agent in
            let started = ContinuousClock.now
            let result = await agent.remoteConclusion(
                for: Self.job(id: "7003"),
                attempts: 1, retryDelay: .milliseconds(10), grace: .milliseconds(200))
            #expect(result == .stillQueued)
            #expect(ContinuousClock.now - started < .milliseconds(150))
        }
    }

    /// Existing callers pass `retryDelay: .zero` and expect exactly one ask.
    @Test("zero retry delay still means a single question")
    func zeroDelayAsksOnce() async throws {
        try await Self.withGitHub(jobs: [
            7004: Self.remoteJob(id: 7004, status: "in_progress")
        ]) { agent in
            let started = ContinuousClock.now
            _ = await agent.remoteConclusion(
                for: Self.job(id: "7004"), attempts: 1, retryDelay: .zero)
            #expect(ContinuousClock.now - started < .milliseconds(500))
        }
    }
}
