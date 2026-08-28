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
        }
    }

    /// Deletes images this node built that no recent job used.
    ///
    /// Every distinct version of a repository's Dockerfile produces its own
    /// tag, so without this the node accumulates one image per edit until the
    /// disk fills. Only tags carrying Sapling's own prefix are considered —
    /// a base image someone pulled by hand is not this loop's business.
    ///
    /// Retention is by *reference*, not age: an image still named by a job
    /// record inside the retention window stays, however old the image is.
    /// A rarely-released project shouldn't have to rebuild its toolchain
    /// simply because it went a fortnight without a release.
    func pruneBuiltImages() async {
        guard config.linux.enabled, config.linux.buildImages else { return }

        let cutoff = Date().addingTimeInterval(-Double(Self.imageRetentionDays) * 86400)
        guard let recent = try? await store.recentJobImageRefs(since: cutoff) else { return }

        let inUse = Set(recent)
        var removed: [String] = []
        for tag in await RunnerImageBuilder.builtImageTags() where !inUse.contains(tag) {
            await RunnerImageBuilder.remove(tag: tag)
            removed.append(tag)
        }
        if !removed.isEmpty {
            Log.info("pruned \(removed.count) unused built image(s): \(removed.joined(separator: ", "))")
        }
    }

    func reapProviderOrphans() async {
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
