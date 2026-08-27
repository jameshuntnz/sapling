import Foundation
import Testing

@testable import SaplingCore

@Suite("Models")
struct ModelTests {
    @Test("job duration runs from start to completion, or to now while running")
    func jobDuration() {
        let start = Date().addingTimeInterval(-120)

        let finished = Job(
            id: "1", repo: "acme/widgets", platform: .linux, labels: [], status: .completed,
            startedAt: start, completedAt: start.addingTimeInterval(90)
        )
        #expect(finished.duration == 90)

        let running = Job(
            id: "2", repo: "acme/widgets", platform: .linux, labels: [], status: .running,
            startedAt: start
        )
        let elapsed = try! #require(running.duration)
        #expect(elapsed >= 119 && elapsed <= 130)

        let queued = Job(id: "3", repo: "acme/widgets", platform: .linux, labels: [], status: .queued)
        #expect(queued.duration == nil)
    }

    /// Draining and cordoned differ in intent, not in effect — both must stop
    /// new work.
    @Test("only an online node accepts new jobs")
    func nodeAcceptance() {
        #expect(NodeStatus.online.acceptsNewJobs)
        #expect(!NodeStatus.draining.acceptsNewJobs)
        #expect(!NodeStatus.cordoned.acceptsNewJobs)
        #expect(!NodeStatus.offline.acceptsNewJobs)
    }

    @Test("terminal states are exactly completed, failed and cancelled")
    func terminalStates() {
        let terminal = JobStatus.allCases.filter(\.isTerminal)
        #expect(Set(terminal) == [.completed, .failed, .cancelled])
        // A cancellation is GitHub's decision, so it is the one finished state
        // this node must never start over.
        #expect(Set(JobStatus.allCases.filter(\.isRetryable)) == [.completed, .failed])
        // Nothing can both hold a slot and be finished.
        #expect(!JobStatus.allCases.contains { $0.isTerminal && $0.occupiesSlot })
    }

    @Test("a join token is usable only while unused and unexpired")
    func joinTokenUsability() {
        let now = Date()
        #expect(JoinToken(token: "a", createdAt: now, expiresAt: now.addingTimeInterval(60)).isUsable)
        #expect(!JoinToken(token: "b", createdAt: now, expiresAt: now.addingTimeInterval(-1)).isUsable)
        #expect(
            !JoinToken(token: "c", createdAt: now, expiresAt: now.addingTimeInterval(60), usedAt: now)
                .isUsable)
    }

    @Test("slot availability never goes negative")
    func slotAvailability() {
        #expect(SlotUsage(platform: .macos, inUse: 1, capacity: 2).available == 1)
        #expect(SlotUsage(platform: .macos, inUse: 2, capacity: 2).available == 0)
        // A stale count must not report phantom free capacity.
        #expect(SlotUsage(platform: .macos, inUse: 3, capacity: 2).available == 0)
    }

    /// DTOs cross the wire to two independent clients, so date handling has
    /// to be identical on both sides.
    @Test("DTOs round-trip through the shared JSON coders")
    func jsonRoundTrip() throws {
        let original = StatusResponse(
            version: "0.1.0",
            node: Node(
                id: "mini", name: "mini", platform: "darwin/arm64", lastSeenAt: Date(), status: .draining),
            slots: [SlotUsage(platform: .macos, inUse: 1, capacity: 2)],
            queuedJobs: 3, runningJobs: 1, completedLast24h: 10, failedLast24h: 2,
            watchedRepos: ["acme/widgets"],
            lastPollAt: Date(), lastPollError: nil
        )
        let data = try SaplingJSON.encoder.encode(original)
        let decoded = try SaplingJSON.decoder.decode(StatusResponse.self, from: data)

        #expect(decoded.node.status == .draining)
        #expect(decoded.slots.first?.capacity == 2)
        #expect(decoded.watchedRepos == ["acme/widgets"])
        #expect(decoded.lastPollError == nil)
        // Slashes in repo names shouldn't come back escaped.
        #expect(String(decoding: data, as: UTF8.self).contains("acme/widgets"))
    }
}
