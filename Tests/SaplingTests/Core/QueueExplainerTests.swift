import Foundation
import Testing

@testable import SaplingCore

/// A queued job that says nothing about why looks like a broken scheduler.
///
/// Under memory admission a node can be half-idle by slot count and completely
/// full by memory, and both statements are true at once. The panel has to
/// reconcile them or the reader will conclude something is wrong.
@Suite("Queue explanations")
struct QueueExplainerTests {
    func job(_ id: String, _ platform: JobPlatform, _ name: String) -> Job {
        Job(id: id, repo: "acme/widgets", platform: platform, labels: [], status: .queued, name: name)
    }

    /// The state this exists for: slots free, memory gone.
    @Test("a node with free slots but no memory says so")
    func memoryNotSlots() {
        let reasons = QueueExplainer.explain(
            queued: [job("1", .linux, "android")],
            inUse: [.linux: 1], capacity: [.linux: 4, .macos: 2],
            nodeCapacity: 6, committedGB: 10, budgetGB: 12,
            sizeOf: { _ in 6 })
        #expect(reasons["1"] == .waitingForMemory(wantsGB: 6, freeGB: 2))
        // Not the slot count, which would read as three slots going spare.
        #expect(reasons["1"]?.summary.contains("2GB free") == true)
    }

    @Test("a full platform is reported as a slot problem")
    func platformFull() {
        let reasons = QueueExplainer.explain(
            queued: [job("1", .linux, "unit tests")],
            inUse: [.linux: 4], capacity: [.linux: 4, .macos: 2],
            nodeCapacity: 6, committedGB: 8, budgetGB: 12,
            sizeOf: { _ in 2 })
        #expect(reasons["1"] == .platformFull(inUse: 4, capacity: 4))
    }

    /// Head-of-line reservation is deliberate and counter-intuitive.
    ///
    /// A small job that would fit is held so a large one is not starved.
    /// Unexplained, it reads as a bug somebody will go and "fix".
    @Test("jobs held behind a larger one are told which job")
    func behindLargerJob() {
        let reasons = QueueExplainer.explain(
            queued: [job("1", .linux, "android"), job("2", .linux, "lint")],
            inUse: [.linux: 1], capacity: [.linux: 4, .macos: 2],
            nodeCapacity: 6, committedGB: 10, budgetGB: 12,
            sizeOf: { $0.id == "1" ? 6 : 1 })
        #expect(reasons["1"] == .waitingForMemory(wantsGB: 6, freeGB: 2))
        // The 1GB job would fit in the 2GB spare, and is held anyway.
        #expect(reasons["2"] == .behindLargerJob(name: "android"))
    }

    /// A job that will start is not explained at all — the panel shows a reason
    /// only where there is something to explain.
    @Test("a job that fits gets no reason")
    func fittingJobIsSilent() {
        let reasons = QueueExplainer.explain(
            queued: [job("1", .linux, "lint")],
            inUse: [:], capacity: [.linux: 4, .macos: 2],
            nodeCapacity: 6, committedGB: 0, budgetGB: 12,
            sizeOf: { _ in 2 })
        #expect(reasons.isEmpty)
    }

    /// Each admitted job is charged before the next is judged, so the queue is
    /// explained against what the scheduler will actually have, not what it has.
    @Test("earlier jobs in the same pass count against later ones")
    func admissionAccumulates() {
        let queue = [job("1", .linux, "a"), job("2", .linux, "b"), job("3", .linux, "c")]
        let reasons = QueueExplainer.explain(
            queued: queue,
            inUse: [:], capacity: [.linux: 4, .macos: 2],
            nodeCapacity: 6, committedGB: 0, budgetGB: 12,
            sizeOf: { _ in 5 })
        // 5 + 5 fits in 12; the third does not.
        #expect(reasons["1"] == nil)
        #expect(reasons["2"] == nil)
        #expect(reasons["3"] == .waitingForMemory(wantsGB: 5, freeGB: 2))
    }

    @Test("the node-wide cap is reported as its own limit")
    func nodeFull() {
        let reasons = QueueExplainer.explain(
            queued: [job("1", .linux, "lint")],
            inUse: [.macos: 2], capacity: [.linux: 4, .macos: 2],
            nodeCapacity: 2, committedGB: 4, budgetGB: 12,
            sizeOf: { _ in 2 })
        #expect(reasons["1"] == .nodeFull(capacity: 2))
    }
}
