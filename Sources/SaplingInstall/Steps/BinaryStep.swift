import Foundation
import SaplingCore

/// Checks that the installed binary matches this one.
public struct BinaryStep: InstallStep {
    /// Name shown by `install` and `doctor`.
    public let name = "sapling binary"
    /// Creates the step.
    public init() {}

    /// Reports whether this step is already satisfied.
    public func check() async -> StepState {
        let target = SaplingPaths.installedBinary
        guard FileManager.default.isExecutableFile(atPath: target) else {
            return .fixable("not installed at \(target)")
        }
        guard let current = currentExecutablePath() else {
            return .ok(target)
        }
        if current == target { return .ok(target) }
        let currentData = FileManager.default.contents(atPath: current)
        let installedData = FileManager.default.contents(atPath: target)
        if currentData != installedData {
            return .fixable("\(target) differs from the binary you're running")
        }
        return .ok(target)
    }

    /// Installs or configures `/usr/local/bin/sapling`.
    public func fix() async throws -> String {
        guard InstallContext.isRoot else {
            throw InstallError("installing to \(SaplingPaths.installedBinary) needs root — re-run with sudo")
        }
        guard let current = currentExecutablePath() else {
            throw InstallError("could not determine the running binary's path")
        }
        let target = SaplingPaths.installedBinary
        try FileManager.default.createDirectory(
            atPath: (target as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
        if FileManager.default.fileExists(atPath: target) {
            try FileManager.default.removeItem(atPath: target)
        }
        try FileManager.default.copyItem(atPath: current, toPath: target)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: target)
        return "installed \(target)"
    }

    func currentExecutablePath() -> String? {
        CommandLine.arguments.first.flatMap { argv0 in
            argv0.hasPrefix("/") ? argv0 : ProcessRunner.which(argv0)
        } ?? Bundle.main.executablePath
    }
}

// MARK: - 11. LaunchDaemon

/// §9.5 step 8 — the step that actually delivers "don't keep installing
/// everything over and over": once this is in place a reboot alone brings the
/// daemon back.
