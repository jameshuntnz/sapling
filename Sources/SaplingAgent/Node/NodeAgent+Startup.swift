import Foundation
import SaplingCore
import SaplingDB

/// Checks the agent runs once, before it will accept any work.
///
/// None of these are fatal on their own — a missing base image shouldn't stop
/// Linux jobs — so each one degrades to a warning rather than refusing to
/// start the node at all.
extension NodeAgent {
    func runPreflight() async throws {
        if let macProvider {
            do {
                try await macProvider.preflight()
            } catch {
                // A missing base image shouldn't stop Linux jobs from running.
                Log.warn("macOS provider unavailable: \(error.localizedDescription)")
            }
        }
        if let linuxProvider {
            do {
                try await linuxProvider.preflight()
            } catch {
                Log.warn("Linux provider unavailable: \(error.localizedDescription)")
            }
        }
    }

    func applyNetworkGuard() async {
        guard config.network.blockPrivateRanges else {
            Log.warn("egress filtering is disabled in config — jobs can reach your LAN (§8)")
            return
        }
        do {
            let applied = try await NetworkGuard(config: config.network).apply()
            networkGuardApplied = true
            Log.info("egress filter active on \(applied.jobSubnets.joined(separator: ", "))")
        } catch NetworkGuardError.noJobNetworks {
            // Expected on a cold boot: the bridge appears with the first VM,
            // so the guard is re-applied before each job dispatch.
            Log.info("no VM bridge yet — egress filter will be applied when the first job starts")
        } catch {
            Log.error("could not apply egress filter: \(error.localizedDescription)")
        }
    }

    /// §8: Sapling assumes trusted job code.
    ///
    /// A public repo can be made to run fork PR code, which breaks that
    /// assumption, so say so loudly.
    func warnAboutPublicRepos() async {
        for repo in config.github.repos {
            if let isPublic = try? await github.isPublic(repo: repo), isPublic {
                Log.error(
                    """
                    WATCHED REPO \(repo) IS PUBLIC. Sapling does not sandbox against adversarial \
                    job code (§2). Anyone who can open a pull request may be able to run code on \
                    this machine. Use private repos only.
                    """)
            }
        }
    }
}
