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
        response.editableKeys = ConfigReload.apiEditableKeys.sorted()

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

    /// Writes new values into the config file, then reloads it.
    ///
    /// Nothing is written unless the edited file loads and validates, so a bad
    /// value is answered, not saved. The file is changed in place rather than
    /// replaced, which keeps its owner and mode — it is the operator's file,
    /// and a root-owned replacement would lock them out of `sapling config
    /// edit`. A copy of the previous version is kept beside it.
    ///
    /// - Parameter request: The keys to change.
    /// - Returns: What the reload applied, or why nothing was written.
    func updateConfig(_ request: ConfigUpdateRequest) async -> ConfigReloadResponse {
        func refused(_ error: String) -> ConfigReloadResponse {
            ConfigReloadResponse(reloaded: false, message: "nothing was written", error: error)
        }
        guard let agent else {
            return refused("no node agent is running in this process, so there is no config to edit")
        }
        let blocked = request.values.keys.filter { !ConfigReload.apiEditableKeys.contains($0) }.sorted()
        guard blocked.isEmpty else {
            return refused("not editable over the API: \(blocked.joined(separator: ", "))")
        }
        guard !request.values.isEmpty else { return refused("no values given") }

        let url = await agent.currentConfigURL()
        do {
            let original = try String(contentsOf: url, encoding: .utf8)
            let edited = try ConfigFileEditor.apply(request.values, to: original)

            let candidate = FileManager.default.temporaryDirectory
                .appendingPathComponent("sapling-config-\(UUID().uuidString).toml")
            defer { try? FileManager.default.removeItem(at: candidate) }
            try edited.write(to: candidate, atomically: false, encoding: .utf8)
            try SaplingConfig.load(from: candidate).validate()

            try Self.backUp(url)
            try Data(edited.utf8).write(to: url)
        } catch {
            return refused(error.localizedDescription)
        }
        return await agent.reloadConfig()
    }

    /// How many API-made backups to keep beside the config file.
    static let configBackupsKept = 5

    /// Copies the config file aside before it is changed, keeping a few.
    private static func backUp(_ url: URL) throws {
        let directory = url.deletingLastPathComponent()
        let prefix = url.lastPathComponent + ".bak-api-"
        let stamp = ISO8601DateFormatter.string(
            from: Date(), timeZone: .current, formatOptions: [.withFullDate, .withTime])
        try FileManager.default.copyItem(
            at: url, to: directory.appendingPathComponent(prefix + stamp))

        let backups =
            (try? FileManager.default.contentsOfDirectory(atPath: directory.path))?
            .filter { $0.hasPrefix(prefix) }.sorted() ?? []
        for stale in backups.dropLast(configBackupsKept) {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(stale))
        }
    }
}
