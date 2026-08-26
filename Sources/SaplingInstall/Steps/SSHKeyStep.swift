import Foundation
import SaplingCore

/// Checks that the key used to reach macOS VMs exists.
public struct SSHKeyStep: InstallStep {
    /// Name shown by `install` and `doctor`.
    public let name = "VM SSH key"
    /// Creates the step.
    public init() {}

    /// Reports whether this step is already satisfied.
    public func check() async -> StepState {
        let path = SaplingPaths.sshKeyFile.path
        guard FileManager.default.fileExists(atPath: path) else {
            return .fixable("no key at \(path)")
        }
        guard FileManager.default.fileExists(atPath: path + ".pub") else {
            return .fixable("private key exists but \(path).pub is missing")
        }
        return .ok(path)
    }

    /// Installs or configures the SSH key pair the agent uses to reach VMs.
    public func fix() async throws -> String {
        try SaplingPaths.ensureHomeDirectory()
        let path = SaplingPaths.sshKeyFile.path
        try? FileManager.default.removeItem(atPath: path)
        try? FileManager.default.removeItem(atPath: path + ".pub")
        let result = try await ProcessRunner.run(
            "ssh-keygen",
            ["-t", "ed25519", "-N", "", "-f", path, "-C", "sapling-vm", "-q"],
            timeout: .seconds(60)
        )
        guard result.succeeded else {
            throw InstallError("ssh-keygen failed: \(result.stderr)")
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        return "generated \(path)"
    }
}
