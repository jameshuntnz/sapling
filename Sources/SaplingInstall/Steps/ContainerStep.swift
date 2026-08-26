import Foundation
import SaplingCore

/// Checks that Apple's `container` tool is installed and running.
public struct ContainerStep: InstallStep {
    /// Name shown by `install` and `doctor`.
    public let name = "Apple container"
    /// Creates the step.
    public init() {}

    static let manualInstructions = """
        Apple's `container` tool is distributed as a signed installer package from
        https://github.com/apple/container/releases — download the latest .pkg, install it,
        then run `container system start` and re-run `sapling install`.
        """

    /// Reports whether this step is already satisfied.
    public func check() async -> StepState {
        guard let path = ProcessRunner.which("container") else {
            return .fixable("`container` not on PATH")
        }
        let status = try? await ProcessRunner.run("container", ["system", "status"], timeout: .seconds(30))
        if status?.succeeded == true {
            return .ok("`container` at \(path), system running")
        }
        return .fixable("`container` at \(path), but the container system is not running")
    }

    /// Installs or configures Apple's `container` tool and its background service.
    public func fix() async throws -> String {
        if ProcessRunner.which("container") != nil {
            let start = try await ProcessRunner.run("container", ["system", "start"], timeout: .seconds(180))
            guard start.succeeded else {
                throw InstallError("`container system start` failed: \(start.stderr)")
            }
            return "started the container system"
        }

        // Ask Homebrew whether it currently carries it, instead of baking in
        // a command that may be wrong by the time this runs.
        let search = try? await ProcessRunner.run(
            HomebrewStep.brewPath, ["search", "--cask", "container"], timeout: .seconds(120))
        if let search, search.succeeded, search.stdout.split(separator: "\n").contains("container") {
            let install = try await ProcessRunner.run(
                HomebrewStep.brewPath, ["install", "--cask", "container"], timeout: .seconds(1800))
            if install.succeeded {
                _ = try? await ProcessRunner.run("container", ["system", "start"], timeout: .seconds(180))
                return "installed `container` via Homebrew"
            }
        }
        throw InstallError(Self.manualInstructions)
    }
}

// MARK: - 5. Tailscale

/// §9.5 step 5: partly automatable at best — the first login is interactive
/// and there is no way around it.
