import Foundation
import SaplingAgent
import SaplingCore

/// Reading and reloading the node's configuration over the API.
///
/// Two questions an operator otherwise has to answer by SSHing to the node and
/// reading a file: what is this daemon actually running with, and does the file
/// on disk still say the same thing.
extension ControlPlane {
    /// The effective configuration, redacted, with any unapplied edits.
    ///
    /// - Returns: The running values plus what a reload or a restart would
    ///   change.
    /// - Throws: If the running configuration cannot be encoded for display.
    func configuration() async throws -> ConfigResponse {
        let live = await effectiveConfig()
        let url = await agent?.currentConfigURL() ?? SaplingPaths.configFile
        var response = ConfigResponse(
            path: url.path,
            entries: try ConfigReload.entries(of: live),
            warnings: live.warnings())

        do {
            let onDisk = try SaplingConfig.load(from: url)
            let split = try ConfigReload.diff(running: live, incoming: onDisk)
            response.pendingReload = split.live
            response.pendingRestart = split.restartRequired
        } catch {
            // Still a useful answer: the daemon is running whatever it loaded
            // at startup, and the file having since been broken or moved is
            // precisely what the reader needs told.
            response.fileError = error.localizedDescription
        }
        return response
    }

    /// Re-reads the config file and applies what can change live.
    ///
    /// - Returns: What was applied, and what still needs a restart.
    func reloadConfig() async -> ConfigReloadResponse {
        guard let agent else {
            // No agent means nothing is holding a live configuration to swap —
            // `sapling demo` and any future agent-less control plane. Saying so
            // beats reporting a reload that changed nothing.
            return ConfigReloadResponse(
                reloaded: false,
                message: "kept the running configuration",
                error: "no node agent is running in this process, so there is nothing to reload")
        }
        return await agent.reloadConfig()
    }
}
