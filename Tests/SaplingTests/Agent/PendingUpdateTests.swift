import Foundation
import Synchronization
import Testing

@testable import SaplingAgent
@testable import SaplingCore
@testable import SaplingDB

/// Counts what a scheduled update did, from closures the agent calls.
final class UpdateCalls: Sendable {
    let installs = Mutex(0)
    let discards = Mutex(0)
    let failInstall: Bool

    init(failInstall: Bool = false) { self.failInstall = failInstall }

    struct InstallFailed: Error {}

    func install() throws {
        installs.withLock { $0 += 1 }
        if failInstall { throw InstallFailed() }
    }

    func discard() { discards.withLock { $0 += 1 } }

    var installCount: Int { installs.withLock { $0 } }
    var discardCount: Int { discards.withLock { $0 } }
}

/// An update asked for while jobs run waits for them rather than failing them.
@Suite("Pending update")
struct PendingUpdateTests {
    /// One queued macOS job that GitHub keeps in progress until it is stopped.
    func liveFixtures() -> FakeGitHubFixtures {
        var fixtures = cancelledFixtures()
        fixtures.jobByID = [9001: fakeRemoteJob(id: 9001, status: "in_progress", conclusion: nil)]
        return fixtures
    }

    func schedule(_ agent: NodeAgent, _ calls: UpdateCalls) async throws -> Bool {
        try await agent.scheduleUpdate(
            version: "9.9.9", checkEvery: .milliseconds(20),
            install: { try calls.install() }, discard: { calls.discard() })
    }

    @Test("a busy node drains and installs only once its job finishes")
    func waitsForRunningJob() async throws {
        try await withCancellationAgent(fixtures: liveFixtures()) { agent, _, provider in
            try await agent.pollOnce()
            try await waitUntil { await provider.hasStarted() }

            let calls = UpdateCalls()
            #expect(try await schedule(agent, calls))
            #expect(await agent.currentStatus() == .draining)
            #expect(await agent.pendingUpdateVersion == "9.9.9")

            try await Task.sleep(for: .milliseconds(200))
            #expect(calls.installCount == 0)
            #expect(!(await provider.wasTornDown()))

            _ = await agent.cancel(jobID: "9001", reason: "finished")
            try await waitUntil { calls.installCount == 1 }
            #expect(calls.discardCount == 0)
        }
    }

    /// The race the hold exists for: a poll that read the node as online
    /// before it drained must not start a job the restart would then kill.
    @Test("nothing is dispatched once the restart hold is taken")
    func holdBlocksDispatch() async throws {
        try await withCancellationAgent(fixtures: liveFixtures()) { agent, store, provider in
            #expect(await agent.holdDispatchIfIdle())
            try await agent.pollOnce()

            #expect(await agent.activeJobCount() == 0)
            #expect(!(await provider.hasStarted()))
            #expect(try await store.job(id: "9001")?.status == .queued)
        }
    }

    @Test("the hold is refused while a job is running")
    func noHoldWhileBusy() async throws {
        try await withCancellationAgent(fixtures: liveFixtures()) { agent, _, provider in
            try await agent.pollOnce()
            try await waitUntil { await provider.hasStarted() }
            #expect(!(await agent.holdDispatchIfIdle()))
        }
    }

    @Test("calling it off puts back the status the node had before")
    func cancelRestoresPriorStatus() async throws {
        try await withCancellationAgent(fixtures: liveFixtures()) { agent, _, provider in
            try await agent.pollOnce()
            try await waitUntil { await provider.hasStarted() }
            try await agent.setStatus(.cordoned)

            #expect(try await schedule(agent, UpdateCalls()))
            #expect(await agent.cancelPendingUpdate() == "9.9.9")
            #expect(await agent.currentStatus() == .cordoned)
        }
    }

    @Test("a second update is refused while one is pending")
    func onePending() async throws {
        try await withCancellationAgent(fixtures: liveFixtures()) { agent, _, provider in
            try await agent.pollOnce()
            try await waitUntil { await provider.hasStarted() }

            let first = UpdateCalls()
            let second = UpdateCalls()
            #expect(try await schedule(agent, first))
            #expect(!(try await schedule(agent, second)))

            #expect(await agent.cancelPendingUpdate() == "9.9.9")
            #expect(await agent.currentStatus() == .online)
            #expect(await agent.pendingUpdateVersion == nil)
            #expect(first.discardCount == 1)
            #expect(first.installCount == 0)
        }
    }

    @Test("a failed install releases the hold and puts the node back")
    func failedInstallRecovers() async throws {
        try await withCancellationAgent(fixtures: liveFixtures()) { agent, _, provider in
            let calls = UpdateCalls(failInstall: true)
            #expect(try await schedule(agent, calls))
            try await waitUntil { calls.installCount == 1 }
            try await waitUntil { await agent.pendingUpdateVersion == nil }

            #expect(calls.discardCount == 1)
            #expect(await agent.currentStatus() == .online)
            try await agent.pollOnce()
            try await waitUntil { await provider.hasStarted() }
        }
    }
}
