import Foundation
import Testing

@testable import SaplingAgent
@testable import SaplingCore
@testable import SaplingDB

/// Reloading a config file under a running agent.
///
/// The agent is never started here: a reload is a file read and a struct swap,
/// and starting one would drag in GitHub, Tart and pf for a behaviour none of
/// them touch.
@Suite("Agent config reload")
struct ConfigReloadAgentTests {
    /// An agent pointed at a config file in a scratch directory.
    ///
    /// A closure rather than a returned tuple: the scratch directory is
    /// noncopyable, and letting it live for the body is exactly the lifetime
    /// wanted.
    func withAgent<T>(_ toml: String, _ body: (NodeAgent, URL) async throws -> T) async throws -> T {
        let directory = try TemporaryDirectory()
        let url = directory.appending("config.toml")
        try toml.write(to: url, atomically: true, encoding: .utf8)
        let config = try SaplingConfig.load(from: url)
        let store = try SaplingStore(inMemoryNamed: UUID().uuidString)
        return try await body(NodeAgent(config: config, store: store, configURL: url), url)
    }

    static let base = """
        [node]
        name = "mini"

        [server]
        port = 8734

        [github]
        auth = "pat"
        token = "ghp_example"
        repos = ["acme/widgets"]
        poll_interval_seconds = 30

        [macos]
        enabled = false

        [linux]
        max_concurrent = 2
        """

    @Test("picks up an edit to a reloadable field without a restart")
    func appliesLiveFields() async throws {
        try await withAgent(Self.base) { agent, url in
            try Self.base
                .replacingOccurrences(
                    of: "poll_interval_seconds = 30", with: "poll_interval_seconds = 60"
                )
                .replacingOccurrences(
                    of: #"repos = ["acme/widgets"]"#, with: #"repos = ["acme/widgets", "acme/gizmos"]"#
                )
                .write(to: url, atomically: true, encoding: .utf8)

            let result = await agent.reloadConfig()
            #expect(result.error == nil)
            #expect(result.reloaded)
            #expect(Set(result.applied.map(\.key)) == ["github.poll_interval_seconds", "github.repos"])
            #expect(result.pendingRestart.isEmpty)

            let running = await agent.currentConfig()
            #expect(running.github.pollIntervalSeconds == 60)
            #expect(running.github.repos == ["acme/widgets", "acme/gizmos"])
        }
    }

    /// The listener is already bound and the providers already hold their
    /// settings, so the honest answer is to report the edit, not to swap the
    /// value and leave the config describing something the node isn't doing.
    @Test("reports a restart-only field instead of applying it")
    func holdsBackRestartFields() async throws {
        try await withAgent(Self.base) { agent, url in
            try Self.base
                .replacingOccurrences(of: "port = 8734", with: "port = 9001")
                .write(to: url, atomically: true, encoding: .utf8)

            let result = await agent.reloadConfig()
            #expect(!result.reloaded)
            #expect(result.applied.isEmpty)
            #expect(result.pendingRestart.map(\.key) == ["server.port"])
            #expect(result.message.contains("1 field needs a daemon restart"))
            #expect(await agent.currentConfig().server.port == 8734)
        }
    }

    @Test("keeps the running configuration when the file no longer parses")
    func rejectsUnparseableFile() async throws {
        try await withAgent(Self.base) { agent, url in
            try "[github\nrepos = ".write(to: url, atomically: true, encoding: .utf8)

            let result = await agent.reloadConfig()
            #expect(result.error != nil)
            #expect(!result.reloaded)
            #expect(await agent.currentConfig().github.repos == ["acme/widgets"])
        }
    }

    /// A file that parses but describes a node that cannot run is refused for
    /// the same reason `serve` refuses to start on one.
    @Test("keeps the running configuration when the file fails validation")
    func rejectsInvalidFile() async throws {
        try await withAgent(Self.base) { agent, url in
            try Self.base
                .replacingOccurrences(of: "max_concurrent = 2", with: "enabled = false")
                .write(to: url, atomically: true, encoding: .utf8)

            let result = await agent.reloadConfig()
            #expect(result.error?.contains("can't run anything") == true)
            #expect(await agent.currentConfig().linux.enabled)
        }
    }

    @Test("says so plainly when the file matches what is running")
    func noChange() async throws {
        try await withAgent(Self.base) { agent, _ in
            let result = await agent.reloadConfig()
            #expect(!result.reloaded)
            #expect(result.applied.isEmpty)
            #expect(result.pendingRestart.isEmpty)
            #expect(result.message.contains("matches the running configuration"))
        }
    }

    /// Discovery caches the installation's repo list for fifteen minutes, so
    /// an edit to the poll list has to clear it or the reload looks inert.
    @Test("drops the discovered repo cache when the poll list changes")
    func clearsDiscoveryCache() async throws {
        try await withAgent(Self.base) { agent, url in
            await agent.primeDiscoveryForTesting(repos: ["acme/discovered"], at: Date())
            try Self.base
                .replacingOccurrences(
                    of: #"repos = ["acme/widgets"]"#, with: #"repos = ["acme/gizmos"]"#
                )
                .write(to: url, atomically: true, encoding: .utf8)

            _ = await agent.reloadConfig()
            #expect(await agent.reposRefreshedAt == nil)
        }
    }

    /// Sizes are recorded at discovery; a job still queued when `memory_gb`
    /// changes would otherwise wait for the old size.
    @Test("re-sizes queued jobs to the reloaded memory_gb, leaving labels and running jobs")
    func resizesQueuedJobs() async throws {
        let sized = Self.base.replacingOccurrences(
            of: "max_concurrent = 2", with: "max_concurrent = 2\nmemory_gb = 6")
        try await withAgent(sized) { agent, url in
            func job(_ id: String, _ labels: [String], _ status: JobStatus) -> Job {
                var job = Job(id: id, repo: "acme/widgets", platform: .linux, labels: labels, status: status)
                job.memoryGB = 6
                return job
            }
            try await agent.store.saveJob(job("default", ["linux"], .queued))
            try await agent.store.saveJob(job("labelled", ["linux", "mem:6"], .queued))
            try await agent.store.saveJob(job("running", ["linux"], .running))

            try sized.replacingOccurrences(of: "memory_gb = 6", with: "memory_gb = 3")
                .write(to: url, atomically: true, encoding: .utf8)
            _ = await agent.reloadConfig()

            let sizes = Dictionary(
                uniqueKeysWithValues: try await agent.store.jobs().map { ($0.id, $0.memoryGB) })
            #expect(sizes["default"] == 3)
            #expect(sizes["labelled"] == 6)
            #expect(sizes["running"] == 6)
        }
    }
}

extension NodeAgent {
    /// Stands in for a discovery round, so a test can check the cache is cleared.
    func primeDiscoveryForTesting(repos: [String], at date: Date) {
        discoveredRepos = repos
        reposRefreshedAt = date
    }
}
