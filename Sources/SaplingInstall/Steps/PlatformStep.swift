import Foundation
import SaplingCore

/// Checks that the host is a Mac Sapling can run on.
public struct PlatformStep: InstallStep {
    /// Name shown by `install` and `doctor`.
    public let name = "Platform"
    /// Creates the step.
    public init() {}

    /// Reports whether this step is already satisfied.
    public func check() async -> StepState {
        var machine = utsname()
        uname(&machine)
        let arch = withUnsafeBytes(of: &machine.machine) { buffer in
            String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
        }
        guard arch == "arm64" else {
            return .failed("this is \(arch); Sapling requires Apple Silicon")
        }

        let version = ProcessInfo.processInfo.operatingSystemVersion
        // Apple's `container` tool requires macOS 26+; below that, only the
        // macOS VM provider can work.
        guard version.majorVersion >= 26 else {
            return .failed(
                """
                macOS \(version.majorVersion).\(version.minorVersion) — Apple's `container` tool \
                needs macOS 26 or later. macOS VM jobs would still work; Linux jobs would not.
                """)
        }

        guard let developerDir = try? await ProcessRunner.run("xcode-select", ["-p"]), developerDir.succeeded
        else {
            return .manual(
                "Xcode Command Line Tools are not installed",
                instructions:
                    "Run `xcode-select --install` and complete the installer, then re-run `sapling install`."
            )
        }
        return .ok("macOS \(version.majorVersion).\(version.minorVersion) on arm64, CLT present")
    }
}

// MARK: - 2. Homebrew
