import Foundation
import SaplingCore

/// Checks that the daemon is registered to start on boot.
public struct LaunchDaemonStep: InstallStep {
    /// Name shown by `install` and `doctor`.
    public let name = "LaunchDaemon"
    let runAsUser: String?
    /// Creates the step.
    public init(runAsUser: String?) { self.runAsUser = runAsUser }

    /// Reports whether this step is already satisfied.
    public func check() async -> StepState {
        guard FileManager.default.fileExists(atPath: SaplingPaths.launchDaemonPlist.path) else {
            return .fixable("not registered")
        }
        // Logs under ~/.sapling let the console user point a root-opened file
        // anywhere; a plist from before they moved is worth reinstalling.
        let installed = (try? String(contentsOf: SaplingPaths.launchDaemonPlist, encoding: .utf8)) ?? ""
        guard installed.contains(SaplingPaths.logsDirectory.path) else {
            return .fixable("the registered plist still logs under ~/.sapling")
        }
        guard
            let result = try? await ProcessRunner.run(
                "launchctl",
                ["print", "system/\(SaplingPaths.launchDaemonLabel)"],
                timeout: .seconds(30)
            ), result.succeeded
        else {
            return .fixable("plist exists but the job is not loaded")
        }
        let running = result.stdout.contains("state = running")
        return .ok(running ? "loaded and running" : "loaded (not currently running)")
    }

    /// Installs or configures the LaunchDaemon, so a reboot brings Sapling back.
    public func fix() async throws -> String {
        guard InstallContext.isRoot else {
            throw InstallError("registering a LaunchDaemon needs root — re-run with sudo")
        }
        try SaplingPaths.ensureHomeDirectory()
        try FileManager.default.createDirectory(
            at: SaplingPaths.logsDirectory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o755, .ownerAccountID: 0, .groupOwnerAccountID: 0])

        let plist = Self.plistContents(runAsUser: runAsUser)
        try plist.write(to: SaplingPaths.launchDaemonPlist, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644, .ownerAccountID: 0, .groupOwnerAccountID: 0],
            ofItemAtPath: SaplingPaths.launchDaemonPlist.path
        )

        // bootout first so re-running install picks up a changed plist; it
        // fails harmlessly when nothing is loaded.
        _ = try? await ProcessRunner.run(
            "launchctl",
            ["bootout", "system/\(SaplingPaths.launchDaemonLabel)"],
            timeout: .seconds(60)
        )
        let bootstrap = try await ProcessRunner.run(
            "launchctl",
            ["bootstrap", "system", SaplingPaths.launchDaemonPlist.path],
            timeout: .seconds(60)
        )
        guard bootstrap.succeeded else {
            throw InstallError("`launchctl bootstrap` failed: \(bootstrap.stderr)")
        }
        return "registered \(SaplingPaths.launchDaemonLabel) (starts on boot)"
    }

    static func plistContents(runAsUser: String?) -> String {
        let home = InstallContext.saplingHome
        let path = ProcessRunner.extraPaths.joined(separator: ":")
        // TART_HOME points at the human's image library on purpose: the base
        // image is created interactively by them, and the root daemon has to
        // clone the same one.
        let entries = """
                <key>SAPLING_HOME</key>
                <string>\(home)</string>
                <key>TART_HOME</key>
                <string>\(InstallContext.tartHome)</string>
                <key>PATH</key>
                <string>\(path)</string>
            """
        var userElement = ""
        if let runAsUser {
            userElement = """
                    <key>UserName</key>
                    <string>\(runAsUser)</string>
                """
        }
        return """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0">
            <dict>
                <key>Label</key>
                <string>\(SaplingPaths.launchDaemonLabel)</string>
                <key>ProgramArguments</key>
                <array>
                    <string>\(SaplingPaths.installedBinary)</string>
                    <string>serve</string>
                </array>
                <key>RunAtLoad</key>
                <true/>
                <key>KeepAlive</key>
                <dict>
                    <key>SuccessfulExit</key>
                    <false/>
                </dict>
                <key>ThrottleInterval</key>
                <integer>10</integer>
                <key>StandardOutPath</key>
                <string>\(SaplingPaths.logsDirectory.path)/sapling.out.log</string>
                <key>StandardErrorPath</key>
                <string>\(SaplingPaths.logsDirectory.path)/sapling.err.log</string>
                <key>WorkingDirectory</key>
                <string>\(home)</string>
            \(userElement)    <key>EnvironmentVariables</key>
                <dict>
            \(entries)
                </dict>
                <key>ProcessType</key>
                <string>Background</string>
            </dict>
            </plist>
            """
    }
}
