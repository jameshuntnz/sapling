import Foundation
import SaplingCore

/// Installing an update without failing the jobs that are running.
///
/// The node drains, and the update is installed at the first moment nothing is
/// running. Startup registers the node online, so it comes back accepting jobs.
extension NodeAgent {
    /// An update staged and waiting for the node to go idle.
    struct PendingUpdate {
        let version: String
        let waiter: Task<Void, Never>
        let discard: @Sendable () -> Void
        let priorStatus: NodeStatus
    }

    /// How often a pending update checks whether the node has gone idle.
    public static let idleCheckInterval: Duration = .seconds(5)

    /// The version waiting to be installed, if any.
    public var pendingUpdateVersion: String? { pendingUpdate?.version }

    /// Stop dispatching if nothing is running or starting.
    ///
    /// - Returns: Whether the hold was taken; when it is, the caller may
    ///   restart without failing a job.
    public func holdDispatchIfIdle() -> Bool {
        guard runningJobs.isEmpty, dispatchesInFlight == 0 else { return false }
        dispatchHeld = true
        return true
    }

    /// Let dispatch resume after a restart that did not happen.
    public func releaseDispatchHold() {
        dispatchHeld = false
    }

    /// Drain the node and install an update once its jobs have finished.
    ///
    /// - Parameters:
    ///   - version: The version being installed, for status and logs.
    ///   - checkEvery: How often to look for an idle moment.
    ///   - install: Installs and restarts. Returning means it did not restart.
    ///   - discard: Cleans up the staged release if the update is called off.
    /// - Returns: `false` if another update is already pending.
    /// - Throws: If the node cannot be set draining.
    public func scheduleUpdate(
        version: String,
        checkEvery: Duration = idleCheckInterval,
        install: @escaping @Sendable () async throws -> Void,
        discard: @escaping @Sendable () -> Void
    ) async throws -> Bool {
        guard pendingUpdate == nil else { return false }
        let prior = await currentStatus()
        try await setStatus(.draining)

        let waiter = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if await self.holdDispatchIfIdle() {
                    await self.installPending(install)
                    return
                }
                try? await Task.sleep(for: checkEvery)
            }
        }
        pendingUpdate = PendingUpdate(version: version, waiter: waiter, discard: discard, priorStatus: prior)
        Log.info("\(version) staged; installing once \(runningJobs.count) running job(s) finish")
        return true
    }

    /// Call off a pending update and put the node back as it was.
    ///
    /// - Returns: The version called off, or `nil` if none was pending or it
    ///   is already installing.
    public func cancelPendingUpdate() async -> String? {
        guard let pending = pendingUpdate, !dispatchHeld else { return nil }
        pending.waiter.cancel()
        pending.discard()
        pendingUpdate = nil
        try? await setStatus(pending.priorStatus)
        Log.info("pending update to \(pending.version) called off")
        return pending.version
    }

    private func installPending(_ install: @Sendable () async throws -> Void) async {
        guard let pending = pendingUpdate else { return }
        Log.info("node idle; installing \(pending.version)")
        do {
            try await install()
        } catch {
            Log.error("pending update to \(pending.version) failed: \(error.localizedDescription)")
            pending.discard()
            pendingUpdate = nil
            dispatchHeld = false
            try? await setStatus(pending.priorStatus)
        }
    }
}
