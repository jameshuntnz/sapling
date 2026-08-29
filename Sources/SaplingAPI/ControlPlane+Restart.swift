import Foundation
import SaplingAgent
import SaplingCore

/// Restarting the daemon at its own request.
///
/// Exists so `sapling restart` needs no `sudo`. The daemon runs as root under
/// launchd, so it can kickstart itself — the same trick that lets a node
/// update without a password, and the same code path the updater uses once it
/// has swapped the binary.
extension ControlPlane {
    /// How long to let the reply reach the client before the process dies.
    ///
    /// `kickstart -k` kills this process, so without a gap the response races
    /// its own delivery and a successful restart reaches the caller as a
    /// connection error. The CLI tolerates that anyway; this makes the normal
    /// case a clean answer rather than a recovered one.
    static let restartReplyGrace = Duration.milliseconds(500)

    /// Ask launchd to take this daemon down and start it again.
    ///
    /// - Parameter force: Restart even while jobs are running.
    /// - Returns: Whether it is restarting, or why it is not.
    func restartDaemon(force: Bool) async -> RestartResponse {
        guard agent != nil else {
            return RestartResponse(
                restarting: false,
                message: "nothing was restarted",
                error: "no node agent is running in this process")
        }
        // A daemon started by hand was not started by launchd, so kickstart
        // would restart a *different* process — the installed one — or none.
        // Refusing sends the CLI to its local fallback, which says so plainly.
        guard getuid() == 0 else {
            return RestartResponse(
                restarting: false,
                message: "nothing was restarted",
                error: "this daemon is not running as root under launchd, so it cannot restart itself")
        }

        let running = await agent?.activeJobCount() ?? 0
        guard running == 0 || force else {
            return RestartResponse(
                restarting: false,
                runningJobs: running,
                message: "nothing was restarted",
                error: "\(running) job(s) are running — restarting would fail them")
        }

        Task.detached {
            try? await Task.sleep(for: Self.restartReplyGrace)
            Log.info("restarting at the control plane's request")
            _ = try? await LaunchControl.restart()
        }
        return RestartResponse(
            restarting: true,
            runningJobs: running,
            message: running == 0
                ? "restarting" : "restarting, failing \(running) running job(s)")
    }
}
