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
            for repo in config.github.repos {
                if let count = try? await github.pruneOfflineRunners(
                    repo: repo, namePrefix: Self.runnerNamePrefix), count > 0
                {
                    Log.info("removed \(count) stale runner registration(s) from \(repo)")
                }
            }
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
