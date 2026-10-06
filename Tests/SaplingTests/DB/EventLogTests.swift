import Foundation
import Testing

@testable import SaplingCore
@testable import SaplingDB

/// Reading a long log from the end, and dropping old ones.
@Suite("Event log")
struct EventLogTests {
    func store(withEvents count: Int, jobID: String = "1", completedAt: Date? = nil) async throws
        -> SaplingStore
    {
        let store = try SaplingStore(inMemoryNamed: UUID().uuidString)
        try await store.upsertNode(
            Node(id: "n", name: "n", platform: "darwin/arm64", lastSeenAt: nil, status: .online))
        try await store.saveJob(
            Job(
                id: jobID, nodeID: "n", repo: "acme/widgets", platform: .linux, labels: [],
                status: completedAt == nil ? .running : .completed, completedAt: completedAt))
        for index in 0..<count {
            try await store.appendEvent(jobID: jobID, event: RunEventName.log, detail: "line \(index)")
        }
        return store
    }

    /// The bug: the detail started at the top, so a runner that dumped
    /// thousands of lines hid the outcome at the end.
    @Test("the newest page comes back oldest first, saying there is more")
    func newestPage() async throws {
        let store = try await store(withEvents: 25)
        let page = try await store.latestEvents(jobID: "1", limit: 10)
        #expect(page.events.map(\.detail) == (15..<25).map { "line \($0)" })
        #expect(page.hasEarlier)

        let earlier = try await store.latestEvents(jobID: "1", beforeID: page.events.first?.id, limit: 10)
        #expect(earlier.events.map(\.detail) == (5..<15).map { "line \($0)" })
        let first = try await store.latestEvents(jobID: "1", beforeID: earlier.events.first?.id, limit: 10)
        #expect(first.events.count == 5)
        #expect(!first.hasEarlier)
    }

    @Test("trimming drops old finished jobs' logs and keeps everything else")
    func trims() async throws {
        let store = try await store(
            withEvents: 5, jobID: "old", completedAt: Date().addingTimeInterval(-30 * 86400))
        try await store.saveJob(
            Job(id: "new", nodeID: "n", repo: "acme/widgets", platform: .linux, labels: [], status: .running))
        try await store.appendEvent(jobID: "new", event: RunEventName.log, detail: "still running")

        let deleted = try await store.trimEvents(completedBefore: Date().addingTimeInterval(-14 * 86400))
        #expect(deleted == 5)
        #expect(try await store.events(jobID: "old").isEmpty)
        #expect(try await store.job(id: "old") != nil)
        #expect(try await store.events(jobID: "new").count == 1)
    }
}
