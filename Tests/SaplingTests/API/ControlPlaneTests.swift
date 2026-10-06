import Foundation
import Testing

@testable import SaplingAPI
@testable import SaplingCore
@testable import SaplingDB

@Suite("Control plane service")
struct ControlPlaneServiceTests {
    /// A control plane whose node row already exists.
    ///
    /// Jobs carry a foreign key to it, so anything storing one has to register
    /// the node first.
    func makeControlPlaneWithNode() async throws -> (SaplingStore, ControlPlane) {
        let (store, controlPlane) = try makeControlPlane()
        try await store.upsertNode(
            Node(id: "mini", name: "mini", platform: "darwin/arm64", lastSeenAt: nil, status: .online))
        return (store, controlPlane)
    }

    func makeControlPlane() throws -> (SaplingStore, ControlPlane) {
        let store = try SaplingStore(inMemoryNamed: UUID().uuidString)
        var config = SaplingConfig()
        config.node.name = "mini"
        config.github.repos = ["acme/widgets"]
        return (store, ControlPlane(store: store, config: config, agent: nil))
    }

    /// An unbounded limit is a way to make the daemon read the whole table
    /// into memory from a laptop.
    @Test("clamps the job limit in both directions")
    func clampsLimit() async throws {
        let (store, controlPlane) = try makeControlPlane()
        try await store.upsertNode(
            Node(id: "mini", name: "mini", platform: "darwin/arm64", lastSeenAt: nil, status: .online))
        for index in 0..<5 {
            try await store.saveJob(
                Job(
                    id: "\(index)", nodeID: "mini", repo: "acme/widgets", platform: .linux, labels: [],
                    status: .completed))
        }
        #expect(try await controlPlane.jobs(status: nil, limit: 100_000).count == 5)
        #expect(try await controlPlane.jobs(status: nil, limit: 0).count == 1)
        #expect(try await controlPlane.jobs(status: nil, limit: -5).count == 1)
    }

    @Test("synthesises a node record before the agent has registered one")
    func statusWithoutRegisteredNode() async throws {
        let (_, controlPlane) = try makeControlPlane()
        let status = try await controlPlane.status()
        #expect(status.node.name == "mini")
        #expect(status.node.status == .offline)
        #expect(status.slots.count == 2)
    }

    @Test("returns nothing for an unknown job rather than an empty shell")
    func unknownJob() async throws {
        let (_, controlPlane) = try makeControlPlane()
        #expect(try await controlPlane.job(id: "nope") == nil)
        #expect(try await controlPlane.logs(jobID: "nope", after: nil) == nil)
    }

    @Test("drain reports how many jobs it is waiting on")
    func drainMessage() async throws {
        let (store, controlPlane) = try makeControlPlane()
        try await store.upsertNode(
            Node(id: "mini", name: "mini", platform: "darwin/arm64", lastSeenAt: nil, status: .online))
        let response = try await controlPlane.drain()
        #expect(response.status == .draining)
        #expect(response.message.contains("nothing is running"))
    }

    /// The control plane can run without an agent in the process.
    ///
    /// Cancelling then cannot tear anything down, so it says so rather than
    /// reporting a teardown that never happened.
    @Test("cancelling without an agent records the decision and admits the limit")
    func cancelWithoutAgent() async throws {
        let (store, controlPlane) = try await makeControlPlaneWithNode()
        try await store.saveJob(
            Job(
                id: "7", nodeID: "mini", repo: "acme/widgets", platform: .linux, labels: [],
                status: .running))

        let response = try #require(try await controlPlane.cancelJob(id: "7"))
        #expect(response.changed)
        #expect(response.status == .cancelled)
        #expect(response.message.contains("no agent here"))
        #expect(try await store.job(id: "7")?.status == .cancelled)
    }

    /// `changed` is what a client keys off, so a no-op has to report false —
    /// a UI that says "cancelled" either way teaches you to distrust it.
    @Test("cancelling a finished job reports that nothing changed")
    func cancelFinishedJob() async throws {
        let (store, controlPlane) = try await makeControlPlaneWithNode()
        try await store.saveJob(
            Job(
                id: "7", nodeID: "mini", repo: "acme/widgets", platform: .linux, labels: [],
                status: .completed))

        let response = try #require(try await controlPlane.cancelJob(id: "7"))
        #expect(!response.changed)
        #expect(response.status == .completed)
    }

    @Test("retrying queues a finished job and refuses a live one")
    func retryJob() async throws {
        let (store, controlPlane) = try await makeControlPlaneWithNode()
        try await store.saveJob(
            Job(
                id: "7", nodeID: "mini", repo: "acme/widgets", platform: .linux, labels: [],
                status: .failed, completedAt: Date()))

        let queued = try #require(try await controlPlane.retryJob(id: "7"))
        #expect(queued.changed)
        #expect(queued.status == .queued)

        // Now that it is queued again, asking a second time is a no-op rather
        // than a second dispatch.
        let again = try #require(try await controlPlane.retryJob(id: "7"))
        #expect(!again.changed)
        #expect(again.status == .queued)
    }

    @Test("both actions report an unknown job as missing rather than inventing one")
    func unknownJobActions() async throws {
        let (_, controlPlane) = try makeControlPlane()
        #expect(try await controlPlane.cancelJob(id: "nope") == nil)
        #expect(try await controlPlane.retryJob(id: "nope") == nil)
    }
}
