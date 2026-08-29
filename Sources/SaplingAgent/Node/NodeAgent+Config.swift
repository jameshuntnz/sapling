import Foundation
import SaplingCore

/// Changing what the node is doing without stopping it.
///
/// The daemon holds one job for two hours at a time, so "edit the file and
/// restart" is not a neutral operation — it fails whatever is running. This
/// re-reads the file instead and swaps the half of the configuration that is
/// read at the point of use, reporting the rest rather than pretending. See
/// `ConfigReload` for which fields fall on which side of that line.
extension NodeAgent {
    /// The configuration the agent is running with right now.
    ///
    /// The control plane reads this rather than holding its own copy, so a
    /// reload cannot leave the API describing a configuration the agent
    /// stopped using.
    public func currentConfig() -> SaplingConfig {
        config
    }

    /// The file this agent loads its configuration from.
    public func currentConfigURL() -> URL {
        configURL
    }

    /// Re-reads the config file and applies everything that can change live.
    ///
    /// All or nothing: the file is parsed and validated in full before any of
    /// it is applied, so a config with a typo leaves the node exactly as it
    /// was rather than half-changed.
    ///
    /// - Returns: What was applied, what still needs a restart, and why
    ///   nothing was applied if the file could not be used.
    public func reloadConfig() async -> ConfigReloadResponse {
        let incoming: SaplingConfig
        do {
            incoming = try SaplingConfig.load(from: configURL)
            try incoming.validate()
        } catch {
            Log.error("config reload rejected: \(error.localizedDescription)")
            return ConfigReloadResponse(
                reloaded: false,
                message: "kept the running configuration",
                error: error.localizedDescription)
        }

        let live: [ConfigChange]
        let restartRequired: [ConfigChange]
        do {
            (live, restartRequired) = try ConfigReload.diff(running: config, incoming: incoming)
        } catch {
            return ConfigReloadResponse(
                reloaded: false,
                message: "kept the running configuration",
                error: "could not compare the configurations: \(error.localizedDescription)")
        }

        guard !live.isEmpty || !restartRequired.isEmpty else {
            return ConfigReloadResponse(
                reloaded: false,
                warnings: config.warnings(),
                message: "\(configURL.path) matches the running configuration")
        }

        if !live.isEmpty {
            let previousRepos = config.github.repos
            let previouslyAllowedPublic = config.github.allowPublicRepos
            config = ConfigReload.merge(running: config, incoming: incoming)
            for change in live {
                Log.info("config: \(change.key) \(change.from) → \(change.to)")
            }
            // Discovery caches the installation's repositories for fifteen
            // minutes. Editing the poll list and then waiting out that window
            // looks exactly like a reload that did nothing, so the cache goes
            // when the list it stands in for changes.
            if previousRepos != config.github.repos
                || previouslyAllowedPublic != config.github.allowPublicRepos
            {
                reposRefreshedAt = nil
            }
        }
        for change in restartRequired {
            Log.warn("config: \(change.key) needs a daemon restart to take effect")
        }

        let warnings = config.warnings()
        if !live.isEmpty {
            for warning in warnings { Log.warn(warning) }
        }

        return ConfigReloadResponse(
            reloaded: !live.isEmpty,
            applied: live,
            pendingRestart: restartRequired,
            warnings: warnings,
            message: Self.reloadSummary(applied: live.count, pending: restartRequired.count))
    }

    /// One line saying what a reload did and what it left.
    static func reloadSummary(applied: Int, pending: Int) -> String {
        func fields(_ count: Int) -> String { count == 1 ? "1 field" : "\(count) fields" }
        func held(_ count: Int) -> String {
            "\(fields(count)) \(count == 1 ? "needs" : "need") a daemon restart"
        }
        switch (applied, pending) {
        case (0, let pending):
            return "nothing a reload can apply; \(held(pending))"
        case (let applied, 0):
            return "applied \(fields(applied))"
        case (let applied, let pending):
            return "applied \(fields(applied)); \(held(pending))"
        }
    }
}
