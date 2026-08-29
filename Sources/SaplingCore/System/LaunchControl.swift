import Foundation

/// Talking to launchd about the Sapling daemon.
///
/// One place for the service target and the restart, because the same
/// `launchctl` line is reached for from three directions — `sapling restart`,
/// `sapling upgrade`, and the daemon replacing its own binary — and they must
/// not drift apart.
public enum LaunchControl {
    /// The launchd service this daemon is registered as.
    public static var serviceTarget: String { "system/\(SaplingPaths.launchDaemonLabel)" }

    /// Kills the daemon and lets launchd start it again.
    ///
    /// `kickstart -k` rather than bootout and bootstrap: the job stays
    /// registered throughout, so a restart that fails leaves a node that still
    /// comes back on boot rather than one that is quietly unregistered.
    ///
    /// The caller does not necessarily survive this — when the daemon itself
    /// asks, launchd replaces the calling process.
    ///
    /// - Parameter timeout: How long to give `launchctl`.
    /// - Returns: The command's result, failures included.
    /// - Throws: If `launchctl` cannot be run at all.
    @discardableResult
    public static func restart(timeout: Duration = .seconds(60)) async throws -> CommandResult {
        try await ProcessRunner.run("launchctl", ["kickstart", "-k", serviceTarget], timeout: timeout)
    }

    /// Whether launchd has the daemon registered.
    ///
    /// - Returns: `true` when the job is loaded, whether or not it is running.
    public static func isRegistered() async -> Bool {
        let result = try? await ProcessRunner.run(
            "launchctl", ["print", serviceTarget], timeout: .seconds(30))
        return result?.succeeded ?? false
    }

    /// A failed `launchctl` result, phrased with the fix where there is one.
    ///
    /// launchd's own errors name a symbol and nothing else — "Could not find
    /// service" is what an uninstalled daemon looks like, and it is worth
    /// saying so rather than passing the phrase through.
    ///
    /// - Parameter result: The failed command.
    /// - Returns: A message that can be printed verbatim.
    public static func explain(_ result: CommandResult) -> String {
        let detail = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        let output = detail.isEmpty ? result.trimmedOutput : detail
        if output.contains("Could not find service") || output.contains("No such process") {
            return "launchd has no \(serviceTarget) — the daemon isn't installed. Run `sudo sapling install`."
        }
        if result.timedOut {
            return "`launchctl kickstart` timed out"
        }
        if output.contains("Operation not permitted") {
            return "launchd refused the request — this needs root, so re-run with sudo"
        }
        return output.isEmpty ? "`launchctl kickstart` failed (exit \(result.exitCode))" : output
    }
}
