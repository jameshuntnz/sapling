import Foundation
import SaplingCore

/// Checks that Homebrew is installed.
public struct HomebrewStep: InstallStep {
    /// Name shown by `install` and `doctor`.
    public let name = "Homebrew"
    let interactive: Bool
    /// Creates the step.
    public init(interactive: Bool) { self.interactive = interactive }

    static let brewPath = "/opt/homebrew/bin/brew"

    /// Reports whether this step is already satisfied.
    public func check() async -> StepState {
        FileManager.default.isExecutableFile(atPath: Self.brewPath)
            ? .ok("installed at \(Self.brewPath)")
            : .fixable("not installed")
    }

    /// Installs or configures Homebrew, which everything else is installed through.
    public func fix() async throws -> String {
        let script = "https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh"
        if interactive {
            print(
                """

                Homebrew is not installed. Sapling will run Homebrew's official installer:
                  /bin/bash -c "$(curl -fsSL \(script))"
                """)
            guard Prompt.confirm("Run it now?", default: true) else {
                throw InstallError("Homebrew is required; install it manually and re-run `sapling install`")
            }
        }
        let result = try await ProcessRunner.run(
            "/bin/bash",
            ["-c", "NONINTERACTIVE=1 /bin/bash -c \"$(curl -fsSL \(script))\""],
            timeout: .seconds(1800)
        )
        guard result.succeeded else {
            throw InstallError("Homebrew install failed: \(result.stderr)")
        }
        return "installed Homebrew"
    }
}

/// Shared shape for the `brew install X` steps.
struct BrewPackageStep: InstallStep {
    let name: String
    let executable: String
    let formula: String
    let isCask: Bool

    func check() async -> StepState {
        ProcessRunner.which(executable) != nil
            ? .ok("`\(executable)` found at \(ProcessRunner.which(executable) ?? "?")")
            : .fixable("`\(executable)` not on PATH")
    }

    func fix() async throws -> String {
        var args = ["install"]
        if isCask { args.append("--cask") }
        args.append(formula)
        let result = try await ProcessRunner.run(HomebrewStep.brewPath, args, timeout: .seconds(3600))
        guard result.succeeded else {
            throw InstallError("`brew \(args.joined(separator: " "))` failed: \(result.stderr)")
        }
        return "installed \(formula)"
    }
}

// MARK: - 3. Tart
