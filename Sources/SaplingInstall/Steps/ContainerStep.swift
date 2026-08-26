import Foundation
import SaplingAgent
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
        // Via ContainerCommand: under `sudo` this runs as root, and root
        // cannot reach the apiserver in the console user's session directly.
        // The timeout matters — a half-torn-down apiserver blocks rather than
        // refusing, which would hang `install` indefinitely.
        var running = false
        if let command = try? await SessionCommand.invocation("container", ["system", "status"]),
            let status = try? await ProcessRunner.run(
                command.executable, command.arguments, timeout: .seconds(20))
        {
            running = status.succeeded
        }
        if running {
            return .ok("`container` at \(path), system running")
        }
        return .fixable("`container` at \(path), but the container system is not running")
    }

    /// Installs or configures Apple's `container` tool and its background service.
    public func fix() async throws -> String {
        if ProcessRunner.which("container") != nil {
            let command = try await SessionCommand.invocation("container", ["system", "start"])
            let start = try await ProcessRunner.run(
                command.executable, command.arguments, timeout: .seconds(180))
            guard start.succeeded else {
                throw InstallError("`container system start` failed: \(start.stderr)")
            }
            return "started the container system"
        }

        // Ask Homebrew whether it currently carries it, instead of baking in
        // a command that may be wrong by the time this runs.
        // A formula in homebrew-core, not a cask — searching casks finds only
        // the unrelated `container-ps` and sends people to the manual route.
        let search = try? await ProcessRunner.run(
            HomebrewStep.brewPath, ["search", "--formula", "/^container$/"], timeout: .seconds(120))
        if let search, search.succeeded,
            search.stdout.split(separator: "\n").map({ $0.trimmingCharacters(in: .whitespaces) })
                .contains("container")
        {
            let install = try await ProcessRunner.run(
                HomebrewStep.brewPath, ["install", "container"], timeout: .seconds(1800))
            if install.succeeded {
                if let start = try? await SessionCommand.invocation("container", ["system", "start"]) {
                    _ = try? await ProcessRunner.run(
                        start.executable, start.arguments, timeout: .seconds(180))
                }
                return "installed `container` via Homebrew"
            }
        }
        throw InstallError(Self.manualInstructions)
    }
}
