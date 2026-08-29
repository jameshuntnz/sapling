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
    /// A public repository is watchable now, but only because `ForkPolicy`
    /// refuses every run whose code did not come from the repository itself.
    /// That closes the path that mattered — a stranger opening a pull request
    /// — and closes nothing else: a public repository's own commits still run
    /// unsandboxed on this machine, so who can push to it is still the whole
    /// of the access control.
    ///
    /// Said at startup because the two settings that make it safe live on
    /// GitHub, not here, and nothing on this node can check them.
    func warnAboutPublicRepos() async {
        for repo in await watchedRepos() {
            guard let isPublic = try? await github.isPublic(repo: repo), isPublic else { continue }
            Log.warn(
                """
                watched repo \(repo) is PUBLIC. Fork pull requests are refused and cannot be \
                enabled, but commits pushed to \(repo) itself run unsandboxed on this machine. \
                Set "Require approval for all outside collaborators" on the repository so fork \
                jobs never reach the queue, and keep push access to people you would give a shell \
                to.
                """)
        }
    }
}
