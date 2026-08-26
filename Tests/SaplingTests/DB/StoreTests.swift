import Foundation
import Testing

@testable import SaplingCore
@testable import SaplingDB

@Suite("Store")
struct StoreTests {
    func makeStore() throws -> SaplingStore {
        let store = try SaplingStore(inMemoryNamed: UUID().uuidString)
        return store
    }

    func makeJob(_ id: String, platform: JobPlatform = .macos, status: JobStatus = .queued) -> Job {
        Job(
            id: id,
            nodeID: "mini",
            repo: "acme/widgets",
            workflowRunID: "999",
            platform: platform,
            labels: ["self-hosted", platform.rawValue],
            status: status,
            name: "build",
            queuedAt: Date()
        )
    }

    @Test("saves and reads a job, labels included")
    func jobRoundTrip() async throws {
        let store = try makeStore()
        try await store.upsertNode(
            Node(id: "mini", name: "mini", platform: "darwin/arm64", lastSeenAt: Date(), status: .online))
        try await store.saveJob(makeJob("1"))

        let loaded = try await store.job(id: "1")
        #expect(loaded?.repo == "acme/widgets")
        #expect(loaded?.labels == ["self-hosted", "macos"])
        #expect(loaded?.platform == .macos)
    }

    /// The poller re-sees the same queued job every cycle until it starts, so
    /// insert has to be a no-op the second time.
    @Test("insertIfNew reports whether the job was new")
    func insertIfNew() async throws {
        let store = try makeStore()
        try await store.upsertNode(
            Node(id: "mini", name: "mini", platform: "darwin/arm64", lastSeenAt: Date(), status: .online))

        #expect(try await store.insertJobIfNew(makeJob("1")))
        #expect(try await store.insertJobIfNew(makeJob("1")) == false)
        #expect(try await store.jobs().count == 1)
    }

    @Test("counts slots only for in-flight jobs")
    func slotAccounting() async throws {
        let store = try makeStore()
        try await store.upsertNode(
            Node(id: "mini", name: "mini", platform: "darwin/arm64", lastSeenAt: Date(), status: .online))

        try await store.saveJob(makeJob("1", platform: .macos, status: .running))
        try await store.saveJob(makeJob("2", platform: .macos, status: .provisioning))
        try await store.saveJob(makeJob("3", platform: .macos, status: .completed))
        try await store.saveJob(makeJob("4", platform: .linux, status: .cleanup))
        try await store.saveJob(makeJob("5", platform: .linux, status: .queued))

        let slots = try await store.slotsInUse()
        #expect(slots[.macos] == 2)
        #expect(slots[.linux] == 1)
    }

    /// After an unclean shutdown the VMs are gone but the rows still say
    /// "running", and would hold slots forever.
    @Test("fails jobs stranded by a crash")
    func orphanReconciliation() async throws {
        let store = try makeStore()
        try await store.upsertNode(
            Node(id: "mini", name: "mini", platform: "darwin/arm64", lastSeenAt: Date(), status: .online))
        try await store.saveJob(makeJob("1", status: .running))
        try await store.saveJob(makeJob("2", status: .completed))

        let stranded = try await store.reconcileOrphanedJobs(reason: "daemon restarted")
        #expect(stranded.count == 1)
        #expect(try await store.job(id: "1")?.status == .failed)
        #expect(try await store.job(id: "1")?.exitReason == "daemon restarted")
        #expect(try await store.job(id: "2")?.status == .completed)

        let slots = try await store.slotsInUse()
        #expect((slots[.macos] ?? 0) == 0)

        // The failure is recorded in the event log too, so the UI can explain
        // what happened rather than showing a job that silently changed.
        let events = try await store.events(jobID: "1")
        #expect(events.contains { $0.event == RunEventName.jobFailed })
    }

    @Test("returns events in order and supports tailing from an offset")
    func eventLog() async throws {
        let store = try makeStore()
        try await store.upsertNode(
            Node(id: "mini", name: "mini", platform: "darwin/arm64", lastSeenAt: Date(), status: .online))
        try await store.saveJob(makeJob("1"))

        for index in 1...5 {
            try await store.appendEvent(jobID: "1", event: RunEventName.log, detail: "line \(index)")
        }

        let all = try await store.events(jobID: "1")
        #expect(all.count == 5)
        #expect(all.first?.detail == "line 1")

        let after = try await store.events(jobID: "1", afterID: all[1].id)
        #expect(after.count == 3)
        #expect(after.first?.detail == "line 3")
    }

    @Test("join tokens are single-use and expire")
    func joinTokens() async throws {
        let store = try makeStore()
        let token = try await store.createJoinToken(ttl: 60)
        #expect(try await store.consumeJoinToken(token.token))
        #expect(try await store.consumeJoinToken(token.token) == false)
        #expect(try await store.consumeJoinToken("nonsense") == false)

        let expired = try await store.createJoinToken(ttl: -1)
        #expect(try await store.consumeJoinToken(expired.token) == false)
    }

    @Test("prunes only old terminal jobs")
    func pruning() async throws {
        let store = try makeStore()
        try await store.upsertNode(
            Node(id: "mini", name: "mini", platform: "darwin/arm64", lastSeenAt: Date(), status: .online))
        try await store.saveJob(makeJob("old", status: .completed))
        try await store.saveJob(makeJob("running", status: .running))

        // updated_at is set on write, so age it directly.
        try await store.writer.write { db in
            try db.execute(
                sql: "UPDATE jobs SET updated_at = ? WHERE id = 'old'",
                arguments: [Date().addingTimeInterval(-40 * 86400)])
        }

        let pruned = try await store.pruneJobs(olderThan: Date().addingTimeInterval(-30 * 86400))
        #expect(pruned == 1)
        #expect(try await store.job(id: "old") == nil)
        #expect(try await store.job(id: "running") != nil)
    }

    @Test("keeps daemon state across reads")
    func daemonState() async throws {
        let store = try makeStore()
        try await store.setState(SaplingStore.StateKey.lastPollError, "boom")
        #expect(try await store.state(SaplingStore.StateKey.lastPollError) == "boom")
        try await store.setState(SaplingStore.StateKey.lastPollError, nil)
        #expect(try await store.state(SaplingStore.StateKey.lastPollError) == nil)
    }
}
