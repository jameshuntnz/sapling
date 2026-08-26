import Foundation
import Testing
import Vapor

@testable import SaplingAPI
@testable import SaplingCore
@testable import SaplingDB

/// Exercises the real route handlers over real HTTP with the real client, so
/// a mismatch between what the server encodes and what the CLI and menu bar
/// app decode shows up here rather than on the Mac mini.
@Suite("REST API", .serialized)
struct APITests {
    func withServer<T>(
        _ body: (SaplingStore, SaplingClient) async throws -> T
    ) async throws -> T {
        let store = try SaplingStore(inMemoryNamed: UUID().uuidString)
        var config = SaplingConfig()
        config.node.name = "test-node"
        config.github.repos = ["acme/widgets"]
        config.server.bind = "loopback"
        config.server.port = 0

        try await store.upsertNode(
            Node(
                id: "test-node",
                name: "test-node",
                platform: "darwin/arm64",
                lastSeenAt: Date(),
                status: .online
            ))

        let controlPlane = ControlPlane(store: store, config: config, agent: nil)

        var env = Environment.testing
        env.arguments = ["sapling-test"]
        let app = try await Application.make(env)
        app.http.server.configuration.hostname = "127.0.0.1"
        app.http.server.configuration.port = 0
        app.logger.logLevel = .critical
        app.middleware = .init()
        app.middleware.use(JSONErrorMiddleware())
        try registerRoutes(
            app, controlPlane: controlPlane,
            advertisedURL: "http://127.0.0.1:\(app.http.server.configuration.port)")

        try await app.startup()
        // An ephemeral port: fixed ones collide when a previous test's socket
        // is still held, which fails as "Address already in use".
        let port = try #require(app.http.server.shared.localAddress?.port)
        let client = SaplingClient(baseURL: try #require(URL(string: "http://127.0.0.1:\(port)")))
        do {
            let result = try await body(store, client)
            try await app.asyncShutdown()
            return result
        } catch {
            try? await app.asyncShutdown()
            throw error
        }
    }

    func makeJob(_ id: String, platform: JobPlatform = .macos, status: JobStatus = .queued) -> Job {
        Job(
            id: id,
            nodeID: "test-node",
            repo: "acme/widgets",
            workflowRunID: "42",
            platform: platform,
            labels: ["self-hosted", platform.rawValue],
            status: status,
            name: "build \(id)",
            queuedAt: Date()
        )
    }

    @Test("reports slots, counts, and watched repos")
    func status() async throws {
        try await withServer { store, client in
            try await store.saveJob(makeJob("1", platform: .macos, status: .running))
            try await store.saveJob(makeJob("2", platform: .linux, status: .queued))

            let status = try await client.status()
            #expect(status.node.name == "test-node")
            #expect(status.node.status == .online)
            #expect(status.version == SaplingVersion.current)
            #expect(status.watchedRepos == ["acme/widgets"])
            #expect(status.queuedJobs == 1)
            #expect(status.runningJobs == 1)

            let macSlot = status.slots.first { $0.platform == .macos }
            #expect(macSlot?.inUse == 1)
            #expect(macSlot?.capacity == 2)
            #expect(macSlot?.available == 1)
        }
    }

    @Test("lists and filters jobs")
    func jobs() async throws {
        try await withServer { store, client in
            try await store.saveJob(makeJob("1", status: .completed))
            try await store.saveJob(makeJob("2", status: .failed))
            try await store.saveJob(makeJob("3", status: .running))

            let all = try await client.jobs()
            #expect(all.count == 3)
            let failed = try await client.jobs(status: .failed)
            #expect(failed.map(\.id) == ["2"])

            let detail = try await client.job(id: "1")
            #expect(detail.job.name == "build 1")
            #expect(detail.job.labels == ["self-hosted", "macos"])
        }
    }

    /// The log viewer tails with `?after=`, so this is the contract the menu
    /// bar app depends on for incremental updates.
    @Test("serves the event log and supports tailing")
    func logs() async throws {
        try await withServer { store, client in
            try await store.saveJob(makeJob("1", status: .running))
            try await store.appendEvent(jobID: "1", event: RunEventName.vmCloned, detail: "sapling-abc")
            try await store.appendEvent(jobID: "1", event: RunEventName.log, detail: "first line")

            let all = try await client.logs(jobID: "1")
            #expect(all.events.count == 2)
            #expect(all.events.first?.event == RunEventName.vmCloned)

            try await store.appendEvent(jobID: "1", event: RunEventName.log, detail: "second line")
            let tail = try await client.logs(jobID: "1", after: all.events.last?.id)
            #expect(tail.events.count == 1)
            #expect(tail.events.first?.detail == "second line")
        }
    }

    @Test("cordon and uncordon move the node's status")
    func control() async throws {
        try await withServer { store, client in
            let cordoned = try await client.cordon()
            #expect(cordoned.status == .cordoned)
            var status = try await client.status()
            #expect(status.node.status == .cordoned)

            let uncordoned = try await client.uncordon()
            #expect(uncordoned.status == .online)
            status = try await client.status()
            #expect(status.node.status == .online)

            let drained = try await client.drain()
            #expect(drained.status == .draining)
            status = try await client.status()
            #expect(status.node.status == .draining)
        }
    }

    @Test("issues a single-use join token")
    func joinToken() async throws {
        try await withServer { store, client in
            let token = try await client.joinToken()
            #expect(token.token.count == 64)
            #expect(token.expiresAt > Date())
            let consumed = try await store.consumeJoinToken(token.token)
            #expect(consumed)
        }
    }

    /// Errors have to arrive as the same JSON shape as everything else, or
    /// the clients end up parsing an HTML error page.
    @Test("returns structured JSON errors")
    func errors() async throws {
        try await withServer { _, client in
            await #expect(throws: ClientError.self) {
                _ = try await client.job(id: "does-not-exist")
            }
            do {
                _ = try await client.job(id: "does-not-exist")
            } catch let error as ClientError {
                #expect(error.statusCode == 404)
                #expect(error.message.contains("does-not-exist"))
            }

            let url = try #require(
                URL(string: client.baseURL.absoluteString + "/api/v1/jobs?status=nonsense"))
            let (data, response) = try await URLSession.shared.data(from: url)
            #expect((response as? HTTPURLResponse)?.statusCode == 400)
            let decoded = try SaplingJSON.decoder.decode(APIErrorResponse.self, from: data)
            #expect(decoded.error == "invalid_status")
        }
    }
}
