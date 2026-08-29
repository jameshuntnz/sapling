import Foundation
import Testing

@testable import SaplingCore

/// How a failed `launchctl` is explained.
///
/// launchd answers with a symbol and nothing else, so the classification is
/// the whole value here: "Could not find service" is what an uninstalled
/// daemon looks like, and passing that phrase through leaves the reader to
/// guess the fix.
@Suite("launchd control")
struct LaunchControlTests {
    func result(_ stderr: String, exitCode: Int32 = 113, timedOut: Bool = false) -> CommandResult {
        CommandResult(
            command: "launchctl kickstart -k \(LaunchControl.serviceTarget)",
            exitCode: exitCode,
            stdout: "",
            stderr: stderr,
            timedOut: timedOut)
    }

    /// The exact wording `launchctl` uses on a Mac with no daemon installed,
    /// checked against the real command.
    @Test("turns a missing service into the install instruction")
    func missingService() {
        let message = LaunchControl.explain(
            result("Could not find service \"dev.sapling.daemon\" in domain for system"))
        #expect(message.contains("isn't installed"))
        #expect(message.contains("sudo sapling install"))
    }

    @Test("names root as the fix when launchd refuses the request")
    func permissionDenied() {
        #expect(LaunchControl.explain(result("Operation not permitted")).contains("sudo"))
    }

    @Test("reports a timeout as a timeout rather than as an exit code")
    func timeout() {
        let message = LaunchControl.explain(result("", exitCode: 0, timedOut: true))
        #expect(message.contains("timed out"))
    }

    @Test("passes an unrecognised failure through rather than guessing")
    func unknownFailure() {
        #expect(LaunchControl.explain(result("Input/output error")) == "Input/output error")
        #expect(LaunchControl.explain(result("")).contains("exit 113"))
    }

    @Test("addresses the daemon by its launchd label")
    func serviceTarget() {
        #expect(LaunchControl.serviceTarget == "system/\(SaplingPaths.launchDaemonLabel)")
    }
}
