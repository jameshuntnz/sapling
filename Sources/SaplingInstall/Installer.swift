import Foundation
import SaplingAgent
import SaplingCore

/// Runs the §9.5 step list.
///
/// `install` and `doctor` share one step list on purpose: doctor is exactly
/// install with the fixes withheld, so the two can never drift into
/// disagreeing about what "installed" means.
public struct Installer: Sendable {
    let options: InstallOptions

    /// Creates an installer.
    public init(options: InstallOptions = InstallOptions()) {
        self.options = options
    }

    /// The ordered step list, shared by `install` and `doctor`.
    public func steps() -> [any InstallStep] {
        let config = SaplingConfig.loadOrDefault()
        return [
            PlatformStep(),
            DiskStep(),
            CapacityStep(config: config),
            HomebrewStep(interactive: !options.nonInteractive),
            TartStep(),
            ContainerStep(),
            TailscaleStep(),
            ConfigStep(options: options),
            SSHKeyStep(),
            FirewallStep(enabled: config.network.blockPrivateRanges),
            JobNetworkStep(),
            BaseImageStep(imageName: config.macos.baseImage),
            BinaryStep(),
            LaunchDaemonStep(runAsUser: options.runAsUser),
        ]
    }

    /// What one `install` run changed, and what it could not.
    public struct Report: Sendable {
        /// Steps that were fixed during this run.
        public var completed: [String] = []
        /// Steps that were already in the desired state.
        public var alreadyDone: [String] = []
        /// Steps only a person can finish, with instructions.
        public var manual: [(step: String, summary: String, instructions: String)] = []
        /// Steps that were attempted and did not succeed.
        public var failed: [(step: String, reason: String)] = []

        /// Whether the installation needs nothing further.
        public var isComplete: Bool { manual.isEmpty && failed.isEmpty }
    }

    // MARK: - install

    /// Runs every step, fixing whatever is missing.
    public func install() async -> Report {
        InstallContext.prepareEnvironment()
        var report = Report()

        for step in steps() {
            if step is LaunchDaemonStep, options.skipDaemon {
                continue
            }
            let state = await step.check()
            switch state {
            case .ok(let summary):
                report.alreadyDone.append("\(step.name): \(summary)")
                print("  ok       \(step.name) — \(summary)")

            case .fixable(let summary):
                print("  fixing   \(step.name) — \(summary)")
                do {
                    let result = try await step.fix()
                    report.completed.append("\(step.name): \(result)")
                    print("  done     \(step.name) — \(result)")
                } catch {
                    report.failed.append((step.name, error.localizedDescription))
                    print("  FAILED   \(step.name) — \(error.localizedDescription)")
                    // Later steps build on earlier ones, so stop rather than
                    // cascade confusing failures.
                    if step is PlatformStep || step is HomebrewStep { return report }
                }

            case .manual(let summary, let instructions):
                report.manual.append((step.name, summary, instructions))
                print("  MANUAL   \(step.name) — \(summary)")

            case .failed(let reason):
                report.failed.append((step.name, reason))
                print("  FAILED   \(step.name) — \(reason)")
                if step is PlatformStep { return report }

            case .unverified(let reason):
                report.alreadyDone.append("\(step.name): \(reason)")
                print("  unknown  \(step.name) — \(reason)")
            }
        }

        await InstallContext.chownToOwner()
        return report
    }

    // MARK: - doctor

    /// One step's state, as reported by `doctor`.
    public struct DoctorResult: Sendable {
        /// The step's name.
        public let step: String
        /// What the check found.
        public let state: StepState
    }

    /// Read-only.
    ///
    /// Nothing here writes, so it's safe after an OS update or an unexpected
    /// reboot when you only want to know what broke.
    public func doctor() async -> [DoctorResult] {
        InstallContext.prepareEnvironment()
        var results: [DoctorResult] = []
        for step in steps() {
            results.append(DoctorResult(step: step.name, state: await step.check()))
        }
        return results
    }

    // MARK: - uninstall

    /// Removes the daemon and its system changes.
    ///
    /// - Parameter purge: Also remove config, credentials, the database, and
    ///   Sapling's VM images.
    /// - Returns: A description of each change made, for printing.
    /// - Throws: `InstallError` if not running as root.
    public func uninstall(purge: Bool) async throws -> [String] {
        InstallContext.prepareEnvironment()
        guard InstallContext.isRoot else {
            throw InstallError("uninstall needs root — re-run with sudo")
        }
        var actions: [String] = []

        _ = try? await ProcessRunner.run(
            "launchctl",
            ["bootout", "system/\(SaplingPaths.launchDaemonLabel)"],
            timeout: .seconds(60)
        )
        if FileManager.default.fileExists(atPath: SaplingPaths.launchDaemonPlist.path) {
            try FileManager.default.removeItem(at: SaplingPaths.launchDaemonPlist)
            actions.append("removed the LaunchDaemon")
        }

        await NetworkGuard.flush()
        if let pfConf = try? String(contentsOfFile: FirewallStep.pfConfPath, encoding: .utf8),
            pfConf.contains(FirewallStep.beginMarker)
        {
            let cleaned = Self.removeMarkedBlock(from: pfConf)
            try? cleaned.write(toFile: FirewallStep.pfConfPath, atomically: true, encoding: .utf8)
            _ = try? await ProcessRunner.run("pfctl", ["-f", FirewallStep.pfConfPath], timeout: .seconds(30))
            actions.append("removed the pf anchor from \(FirewallStep.pfConfPath)")
        }
        try? FileManager.default.removeItem(atPath: NetworkGuard.anchorPath)

        if FileManager.default.fileExists(atPath: SaplingPaths.installedBinary) {
            try FileManager.default.removeItem(atPath: SaplingPaths.installedBinary)
            actions.append("removed \(SaplingPaths.installedBinary)")
        }

        if purge {
            // Config holds credentials and the database holds job history —
            // both only go when explicitly asked for (§9.5).
            try? FileManager.default.removeItem(atPath: InstallContext.saplingHome)
            actions.append("removed \(InstallContext.saplingHome)")

            let reaped = await VMMaintenance.removeSaplingVMs(
                config: SaplingConfig.loadOrDefault().macos, includingBaseImage: true)
            if !reaped.isEmpty {
                actions.append("deleted \(reaped.count) sapling VM(s)")
            }
        } else {
            actions.append(
                "kept \(InstallContext.saplingHome) (use --purge to remove config, database, and VM images)")
        }

        return actions
    }

    static func removeMarkedBlock(from text: String) -> String {
        var out: [String] = []
        var skipping = false
        for line in text.components(separatedBy: .newlines) {
            if line.contains(FirewallStep.beginMarker) {
                skipping = true
                continue
            }
            if line.contains(FirewallStep.endMarker) {
                skipping = false
                continue
            }
            if !skipping { out.append(line) }
        }
        return out.joined(separator: "\n")
    }

    // MARK: - upgrade

    /// Replace the installed binary and restart the daemon.
    ///
    /// Deliberately not a network self-update yet: there are no signed
    /// releases to verify against, and silently pulling an unverified binary
    /// onto a machine that runs your builds as root is the wrong default.
    public func upgrade(from binaryPath: String?) async throws -> [String] {
        InstallContext.prepareEnvironment()
        guard InstallContext.isRoot else {
            throw InstallError("upgrade needs root — re-run with sudo")
        }
        guard let source = binaryPath ?? BinaryStep().currentExecutablePath() else {
            throw InstallError("no binary given and the running binary's path could not be determined")
        }
        guard FileManager.default.isExecutableFile(atPath: source) else {
            throw InstallError("\(source) is not an executable file")
        }

        var actions: [String] = []
        let target = SaplingPaths.installedBinary
        if FileManager.default.fileExists(atPath: target) {
            try FileManager.default.removeItem(atPath: target)
        }
        try FileManager.default.copyItem(atPath: source, toPath: target)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: target)
        actions.append("installed \(source) -> \(target)")

        _ = try? await LaunchControl.restart()
        actions.append("restarted \(SaplingPaths.launchDaemonLabel)")
        return actions
    }
}
