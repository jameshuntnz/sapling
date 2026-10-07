import Foundation
import SaplingCore
import SaplingDB

/// Periodic tidying: pruning old rows and sweeping runner registrations
/// and VMs that outlived the daemon that made them.
extension NodeAgent {
    func housekeepingLoop() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(300))
            guard !Task.isCancelled else { return }

            if let pruned = try? await store.pruneJobs(olderThan: Date().addingTimeInterval(-30 * 86400)),
                pruned > 0
            {
                Log.info("pruned \(pruned) old job record(s)")
            }
            for repo in await watchedRepos() {
                if let count = try? await github.pruneOfflineRunners(
                    repo: repo, namePrefix: Self.runnerNamePrefix, inFlight: inFlightRunners),
                    count > 0
                {
                    Log.info("removed \(count) stale runner registration(s) from \(repo)")
                }
            }
            await pruneBuiltImages()
            // A job cancelled mid-run cannot clean up after itself, so its
            // lease waits here rather than for the next restart.
            await buildCache.reapLeases(keeping: Set(runningJobs.keys))
        }
    }

    /// Deletes images this node built that recent jobs no longer need.
    ///
    /// Only tags carrying Sapling's own prefix are considered — a base image
    /// someone pulled by hand is not this loop's business. See
    /// `BuiltImageRetention` for which tags stay.
    func pruneBuiltImages() async {
        guard config.linux.enabled, config.linux.buildImages else { return }

        let cutoff = Date().addingTimeInterval(-Double(Self.imageRetentionDays) * 86400)
        guard let recent = try? await store.recentJobImageRefs(since: cutoff),
            let active = try? await store.activeJobs()
        else { return }

        let removable = BuiltImageRetention.removable(
            built: await RunnerImageBuilder.builtImageTags(), recentRefs: recent,
            active: Set(active.compactMap(\.imageRef)))
        for tag in removable {
            await RunnerImageBuilder.remove(tag: tag)
        }
        if !removable.isEmpty {
            Log.info("pruned \(removable.count) built image(s): \(removable.joined(separator: ", "))")
        }
    }

    func reapProviderOrphans() async {
        let leases = await buildCache.reapLeases(keeping: Set(runningJobs.keys))
        if !leases.isEmpty {
            Log.warn("deleted orphaned build cache lease(s): \(leases.joined(separator: ", "))")
        }
        if let macProvider {
            let reaped = await macProvider.reapOrphans()
            if !reaped.isEmpty { Log.warn("deleted orphaned VM(s): \(reaped.joined(separator: ", "))") }
        }
        if let linuxProvider {
            let reaped = await linuxProvider.reapOrphans()
            if !reaped.isEmpty {
                Log.warn("deleted orphaned container(s): \(reaped.joined(separator: ", "))")
            }
        }
    }
}
