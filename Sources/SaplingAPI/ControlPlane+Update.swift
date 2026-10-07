import Foundation
import SaplingAgent
import SaplingCore

/// Updating the daemon in place.
///
/// A busy node is not refused: the release is downloaded and verified now,
/// the node drains, and the agent installs it once the last job finishes.
extension ControlPlane {
    /// Look for a newer version on the configured channel.
    ///
    /// A failed check is reported in the response rather than thrown: not
    /// being able to reach GitHub is worth showing, not worth a 500.
    ///
    /// - Returns: What is available, and what is running now.
    public func checkForUpdate() async -> UpdateCheckResponse {
        let live = await effectiveConfig()
        do {
            let update = try await SelfUpdater(config: live).check()
            return UpdateCheckResponse(
                current: SaplingVersion.current,
                channel: live.update.channel,
                available: update?.version,
                tag: update?.tag,
                publishedAt: update?.publishedAt)
        } catch {
            return UpdateCheckResponse(
                current: SaplingVersion.current,
                channel: live.update.channel,
                error: error.localizedDescription)
        }
    }

    /// Install the newest version on the configured channel.
    ///
    /// On an idle node the daemon replies and then restarts, so the connection
    /// drops — which is success. On a busy one it replies with the jobs the
    /// install is waiting on.
    ///
    /// - Parameter force: Install now even while jobs are running, failing
    ///   them, and whether or not the release outranks what is running.
    /// - Returns: What is being applied, or why nothing is.
    public func applyUpdate(force: Bool) async -> UpdateApplyResponse {
        guard await UpdateGate.shared.enter() else {
            return UpdateApplyResponse(applying: false, message: "an update is already being applied")
        }
        let response = await apply(force: force)
        await UpdateGate.shared.leave()
        return response
    }

    private func apply(force: Bool) async -> UpdateApplyResponse {
        if force {
            _ = await agent?.cancelPendingUpdate()
        } else if let pending = await agent?.pendingUpdateVersion {
            return UpdateApplyResponse(
                applying: false, version: pending,
                message: "\(pending) is already waiting for running jobs to finish",
                waitingOnJobs: await agent?.activeJobCount())
        }

        let live = await effectiveConfig()
        let updater = SelfUpdater(config: live)
        let update: AvailableUpdate?
        do {
            // With force, take the newest release on the channel whether or not
            // it outranks what is running. Without it, only a genuine upgrade.
            update = force ? try await updater.newestRelease() : try await updater.check()
        } catch {
            return UpdateApplyResponse(
                applying: false, message: "could not check for updates: \(error.localizedDescription)")
        }
        guard let update else {
            return UpdateApplyResponse(
                applying: false,
                message: "already on \(SaplingVersion.current), the newest on the "
                    + "\(live.update.channel.rawValue) channel")
        }

        let staged: StagedRelease
        do {
            staged = try await updater.stage(update)
        } catch {
            return UpdateApplyResponse(applying: false, message: error.localizedDescription)
        }

        let idle = await agent?.holdDispatchIfIdle() ?? true
        if let agent, !idle, !force {
            return await schedule(staged, updater: updater, agent: agent)
        }
        do {
            // Installed before replying, so a failure is reported rather than
            // silently swallowed by the restart.
            try await updater.install(staged)
            return UpdateApplyResponse(
                applying: true, version: update.version,
                message: "installed \(update.version); the daemon is restarting")
        } catch {
            await agent?.releaseDispatchHold()
            return UpdateApplyResponse(applying: false, message: error.localizedDescription)
        }
    }

    /// Call off an update that is waiting for jobs to finish.
    ///
    /// - Returns: What was called off, if anything.
    public func cancelUpdate() async -> UpdateApplyResponse {
        guard let version = await agent?.cancelPendingUpdate() else {
            let installing = await agent?.pendingUpdateVersion
            return UpdateApplyResponse(
                applying: installing != nil, version: installing,
                message: installing.map { "\($0) is already installing" } ?? "no update is pending")
        }
        return UpdateApplyResponse(
            applying: false, version: version,
            message: "called off \(version); accepting jobs as before")
    }

    private func schedule(
        _ staged: StagedRelease, updater: SelfUpdater, agent: NodeAgent
    ) async -> UpdateApplyResponse {
        let running = await agent.activeJobCount()
        do {
            let scheduled = try await agent.scheduleUpdate(
                version: staged.version,
                install: { try await updater.install(staged) },
                discard: { updater.discard(staged) })
            guard scheduled else {
                // Another request scheduled one while this one was downloading.
                updater.discard(staged)
                let pending = await agent.pendingUpdateVersion ?? staged.version
                return UpdateApplyResponse(
                    applying: false, version: pending,
                    message: "\(pending) is already waiting for running jobs to finish",
                    waitingOnJobs: running)
            }
        } catch {
            updater.discard(staged)
            return UpdateApplyResponse(applying: false, message: error.localizedDescription)
        }
        return UpdateApplyResponse(
            applying: false, version: staged.version,
            message: "\(staged.version) is verified; draining, and installing once "
                + "\(running) running job(s) finish",
            waitingOnJobs: running)
    }
}

/// Lets one update request apply at a time.
///
/// Two overlapping installs both swapped the binary on the node, and the
/// loser's rollback put the old version back under the winner's restart.
actor UpdateGate {
    static let shared = UpdateGate()
    private var busy = false

    /// Claims the gate.
    ///
    /// - Returns: Whether it was free.
    func enter() -> Bool {
        guard !busy else { return false }
        busy = true
        return true
    }

    /// Releases the gate.
    func leave() { busy = false }
}
