import Foundation
import SaplingCore
import SaplingDB

/// Which repositories this node polls.
///
/// Either configured explicitly, or — when `github.repos` is empty and the
/// node authenticates as a GitHub App — discovered from the installation, so
/// granting a repository is done once on GitHub instead of twice.
extension NodeAgent {
    /// How often a discovered list is re-checked against the installation.
    ///
    /// Installations change when someone grants or revokes a repository, and
    /// the node should notice without a restart. Not on every poll: this costs
    /// a request per cycle for something that changes rarely.
    static let repoRefreshInterval: TimeInterval = 900

    /// Repositories to poll right now.
    ///
    /// Falls back to the last known list when discovery fails, so a GitHub
    /// blip pauses updates rather than silently emptying the poll set — a node
    /// that quietly stops watching everything looks identical to a node with
    /// no queued work.
    func watchedRepos() async -> [String] {
        if !config.github.repos.isEmpty { return config.github.repos }

        let now = Date()
        if let refreshedAt = reposRefreshedAt,
            now.timeIntervalSince(refreshedAt) < Self.repoRefreshInterval,
            !discoveredRepos.isEmpty
        {
            return discoveredRepos
        }

        do {
            let result = try await github.installationRepositories()
            reposRefreshedAt = now

            if result.watched != discoveredRepos {
                let added = Set(result.watched).subtracting(discoveredRepos)
                let removed = Set(discoveredRepos).subtracting(result.watched)
                if !added.isEmpty { Log.info("now watching \(added.sorted().joined(separator: ", "))") }
                if !removed.isEmpty {
                    Log.info("no longer watching \(removed.sorted().joined(separator: ", "))")
                }
            }
            discoveredRepos = result.watched

            if !result.skippedPublic.isEmpty {
                Log.warn(
                    """
                    ignoring \(result.skippedPublic.count) public repo(s) in this installation: \
                    \(result.skippedPublic.sorted().joined(separator: ", ")). Discovery does not \
                    watch public repos unless github.allow_public_repos is on; list one in \
                    github.repos to take just that one.
                    """)
            }
            if result.watched.isEmpty {
                Log.warn("this App installation grants no watchable repositories — nothing will be polled")
            }

            try? await store.setState(
                SaplingStore.StateKey.watchedRepos, Self.encode(result.watched))
            return result.watched
        } catch {
            Log.error("could not list installation repositories: \(error.localizedDescription)")
            // Keep whatever was last known rather than dropping to nothing.
            return discoveredRepos
        }
    }

    static func encode(_ repos: [String]) -> String {
        guard let data = try? JSONEncoder().encode(repos) else { return "[]" }
        return String(decoding: data, as: UTF8.self)
    }
}
