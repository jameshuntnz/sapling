import Foundation
import Testing

@testable import SaplingAgent
@testable import SaplingCore
@testable import SaplingDB

@Suite("Event sink")
struct EventSinkTests {
    @Test("writes provider events into the run log")
    func recordsEvents() async throws {
        let store = try SaplingStore(inMemoryNamed: UUID().uuidString)
        try await store.upsertNode(
            Node(id: "n", name: "n", platform: "darwin/arm64", lastSeenAt: nil, status: .online))
        try await store.saveJob(
            Job(id: "1", nodeID: "n", repo: "acme/widgets", platform: .linux, labels: [], status: .running))

        let sink = StoreEventSink(store: store, jobID: "1")
        await sink.record(RunEventName.vmCloned, detail: "sapling-abc")
        await sink.record(RunEventName.runnerStarted)

        let events = try await store.events(jobID: "1")
        #expect(events.map(\.event) == [RunEventName.vmCloned, RunEventName.runnerStarted])
        #expect(events.first?.detail == "sapling-abc")
        #expect(events.last?.detail == nil)
    }

    /// Runner output arrives in arbitrary chunks; one row per line keeps the
    /// log viewer readable instead of showing a single giant blob.
    @Test("splits multi-line output into one event per line")
    func splitsLines() async throws {
        let store = try SaplingStore(inMemoryNamed: UUID().uuidString)
        try await store.upsertNode(
            Node(id: "n", name: "n", platform: "darwin/arm64", lastSeenAt: nil, status: .online))
        try await store.saveJob(
            Job(id: "1", nodeID: "n", repo: "acme/widgets", platform: .linux, labels: [], status: .running))

        let sink = StoreEventSink(store: store, jobID: "1")
        await sink.log("first\nsecond\n\nthird\n")
        await sink.log("   ")

        let events = try await store.events(jobID: "1")
        #expect(events.count == 3)
        #expect(events.map(\.detail) == ["first", "second", "third"])
        #expect(events.allSatisfy { $0.event == RunEventName.log })
    }

    /// Logging must never be able to fail a job that is otherwise fine.
    @Test("swallows write failures instead of failing the job")
    func neverThrows() async throws {
        let store = try SaplingStore(inMemoryNamed: UUID().uuidString)
        // No such job, so the foreign key rejects the insert.
        let sink = StoreEventSink(store: store, jobID: "no-such-job")
        await sink.record("something", detail: nil)
    }
}
