import Foundation
import SaplingCore

/// Checks that Tailscale is installed and logged in.
public struct TailscaleStep: InstallStep {
    /// Name shown by `install` and `doctor`.
    public let name = "Tailscale"
    /// Creates the step.
    public init() {}

    /// Reports whether this step is already satisfied.
    public func check() async -> StepState {
        guard ProcessRunner.which("tailscale") != nil else {
            return .fixable("`tailscale` not on PATH")
        }
        guard
            let status = try? await ProcessRunner.run(
                "tailscale", ["status", "--json"], timeout: .seconds(20)),
            status.succeeded
        else {
            return .manual(
                "Tailscale is installed but not logged in",
                instructions:
                    "Run `sudo tailscaled install-system-daemon` (if you used the CLI formula) then `tailscale up`, and re-run `sapling install`."
            )
        }
        guard let address = await currentAddress() else {
            return .manual(
                "Tailscale is running but has no IPv4 address yet",
                instructions:
                    "Run `tailscale up` and complete the login in a browser, then re-run `sapling install`."
            )
        }
        return .ok("up at \(address)")
    }

    /// Installs or configures Tailscale, which is how the node is reached at all.
    public func fix() async throws -> String {
        // The CLI formula rather than the cask: this host is headless, and
        // the cask's menu bar app needs a GUI login to authenticate.
        let result = try await ProcessRunner.run(
            HomebrewStep.brewPath, ["install", "tailscale"], timeout: .seconds(1800))
        guard result.succeeded else {
            throw InstallError("`brew install tailscale` failed: \(result.stderr)")
        }
        throw InstallError(
            """
            Installed Tailscale, but the rest is a genuine one-time manual step:
              sudo tailscaled install-system-daemon
              tailscale up
            Complete the login in a browser, then re-run `sapling install`.
            """)
    }

    func currentAddress() async -> String? {
        guard let result = try? await ProcessRunner.run("tailscale", ["ip", "-4"], timeout: .seconds(10)),
            result.succeeded
        else { return nil }
        let address = result.trimmedOutput.split(separator: "\n").first.map(String.init)
        return (address?.isEmpty == false) ? address : nil
    }
}

// MARK: - 6. Configuration
