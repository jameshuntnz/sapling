import Foundation
import Testing

@testable import SaplingAgent
@testable import SaplingCore

/// Exercises `GitHubClient` against the shared fake GitHub API.
@Suite("GitHub client", .serialized)
struct GitHubClientTests {

    func withFakeGitHub<T>(
        _ body: (GitHubClient, FakeGitHubState) async throws -> T
    ) async throws -> T {
        var fixtures = FakeGitHubFixtures()
        fixtures.queuedRunIDs = [100]
        fixtures.inProgressRunIDs = [200]
        fixtures.jobsByRun = [
            100: FakeGitHubFixtureLibrary.mixedStatuses,
            200: FakeGitHubFixtureLibrary.queuedBehindRunningRun,
        ]

        let server = try await FakeGitHubServer.start(fixtures: fixtures)
        let client = GitHubClient(config: server.githubConfig())
        do {
            let result = try await body(client, server.state)
            await server.shutdown()
            return result
        } catch {
            await server.shutdown()
            throw error
        }
    }

    @Test("collects queued jobs from both queued and in-progress runs")
    func queuedJobs() async throws {
        try await withFakeGitHub { client, state in
            let jobs = try await client.queuedJobs(repo: "acme/widgets")

            // Only queued jobs come back; the in_progress one is filtered out.
            #expect(Set(jobs.map(\.id)) == [9001, 9003])
            let allQueued = jobs.allSatisfy { $0.isQueued }
            #expect(allQueued)

            let build = try #require(jobs.first { $0.id == 9001 })
            #expect(build.name == "build")
            #expect(build.runId == 100)
            #expect(build.labels == ["self-hosted", "macos"])

            // A queued run and an in-progress run are both walked — jobs
            // sitting behind an already-running run would be missed otherwise.
            #expect(Set(state.jobsRequests) == [100, 200])
        }
    }

    @Test("reads rate limit headers off responses")
    func rateLimit() async throws {
        try await withFakeGitHub { client, _ in
            _ = try await client.isPublic(repo: "acme/widgets")
            let limit = await client.currentRateLimit()
            #expect(limit.remaining == 4321)
            #expect(limit.resetAt == Date(timeIntervalSince1970: 2_000_000_000))
        }
    }

    @Test("requests a JIT config with the runner's name and labels")
    func jitConfig() async throws {
        try await withFakeGitHub { client, state in
            let config = try await client.jitConfig(
                repo: "acme/widgets",
                runnerName: "sap-macos-abc123",
                labels: ["self-hosted", "macos", "arm64"]
            )
            #expect(config == "ZmFrZS1qaXQtY29uZmln")

            let body = try #require(state.jitBodies.first)
            #expect(body["name"] as? String == "sap-macos-abc123")
            #expect(body["labels"] as? [String] == ["self-hosted", "macos", "arm64"])
            #expect(body["runner_group_id"] as? Int == 1)
            #expect(body["work_folder"] as? String == "_work")
        }
    }

    @Test("falls back to a registration token when asked")
    func registrationToken() async throws {
        try await withFakeGitHub { client, _ in
            let token = try await client.registrationToken(repo: "acme/widgets")
            #expect(token == "AABBCC")
        }
    }

    /// Job outcomes are reconciled from GitHub rather than inferred from the
    /// runner's exit code, because a JIT runner may pick up a different job.
    @Test("reads a single job's conclusion")
    func jobDetail() async throws {
        try await withFakeGitHub { client, _ in
            let job = try await client.job(repo: "acme/widgets", jobID: 9001)
            #expect(job.isCompleted)
            #expect(job.conclusion == "success")
            #expect(job.runnerName == "sap-macos-abc")
            #expect(job.startedAt != nil)
        }
    }

    @Test("surfaces API errors with their status code")
    func apiErrors() async throws {
        try await withFakeGitHub { client, _ in
            await #expect(throws: GitHubError.self) {
                _ = try await client.job(repo: "acme/widgets", jobID: 424242)
            }
            do {
                _ = try await client.job(repo: "acme/widgets", jobID: 424242)
            } catch let error as GitHubError {
                #expect(error.statusCode == 404)
                #expect(!error.isAuthFailure)
                #expect(!error.isRateLimited)
            }
        }
    }

    /// Only runners this node created, that are offline and not busy, get
    /// swept — never someone else's, and never a live one.
    @Test("prunes only its own dead runners")
    func pruneOfflineRunners() async throws {
        try await withFakeGitHub { client, state in
            let pruned = try await client.pruneOfflineRunners(
                repo: "acme/widgets",
                namePrefix: NodeAgent.runnerNamePrefix
            )
            #expect(pruned == 2)
            #expect(Set(state.deletedRunners) == [1, 4])
            #expect(!state.deletedRunners.contains(2), "must not delete a busy online runner")
            #expect(!state.deletedRunners.contains(3), "must not delete a runner it didn't create")
        }
    }

    /// §8: a public repo can be made to run fork-PR code, which breaks the
    /// trusted-code assumption the whole design rests on.
    @Test("detects repository visibility")
    func repositoryVisibility() async throws {
        try await withFakeGitHub { client, _ in
            let privateRepo = try await client.isPublic(repo: "acme/widgets")
            #expect(privateRepo == false)
            let publicRepo = try await client.isPublic(repo: "public-owner/public-repo")
            #expect(publicRepo == true)
        }
    }

    /// An installation token can be revoked, or rejected because of clock skew.
    ///
    /// One transparent retry makes that self-heal.
    @Test("retries once after a 401")
    func retriesOnAuthFailure() async throws {
        try await withFakeGitHub { client, state in
            let result = try await client.isPublic(repo: "flaky/endpoint")
            #expect(result == false)
            #expect(state.authAttempts == 2, "should have retried exactly once")
        }
    }
}

@Suite("GitHub token provider")
struct GitHubTokenProviderTests {
    @Test("returns the configured PAT unchanged")
    func patMode() async throws {
        var config = GitHubConfig()
        config.auth = .pat
        config.token = "ghp_example"
        let token = try await GitHubTokenProvider(config: config).token()
        #expect(token == "ghp_example")
    }

    @Test("refuses PAT mode with no token rather than sending an empty header")
    func patModeMissingToken() async {
        var config = GitHubConfig()
        config.auth = .pat
        config.token = nil
        await #expect(throws: ConfigError.self) {
            _ = try await GitHubTokenProvider(config: config).token()
        }
    }

    @Test("refuses App mode with incomplete credentials")
    func appModeIncomplete() async {
        var config = GitHubConfig()
        config.auth = .app
        config.appID = "123"
        await #expect(throws: ConfigError.self) {
            _ = try await GitHubTokenProvider(config: config).token()
        }
    }

    @Test("classifies error kinds")
    func errorClassification() {
        #expect(GitHubError(statusCode: 401, message: "").isAuthFailure)
        #expect(GitHubError(statusCode: 403, message: "").isRateLimited)
        #expect(GitHubError(statusCode: 429, message: "").isRateLimited)
        #expect(!GitHubError(statusCode: 500, message: "").isRateLimited)
    }
}
