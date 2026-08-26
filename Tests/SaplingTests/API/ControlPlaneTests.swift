import Foundation
import Testing

@testable import SaplingAPI
@testable import SaplingCore
@testable import SaplingDB

@Suite("Control plane service")
struct ControlPlaneServiceTests {
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
}
