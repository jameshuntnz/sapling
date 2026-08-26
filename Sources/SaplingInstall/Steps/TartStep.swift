import Foundation
import SaplingCore

/// Checks that Tart is installed.
public struct TartStep: InstallStep {
    /// Name shown by `install` and `doctor`.
    public let name = "Tart"
    /// Creates the step.
    public init() {}
    private let inner = BrewPackageStep(
        name: "Tart",
        executable: "tart",
        formula: "cirruslabs/cli/tart",
        isCask: false
    )
    /// Reports whether this step is already satisfied.
    public func check() async -> StepState { await inner.check() }
    /// Installs or configures Tart, which runs the macOS VMs.
    public func fix() async throws -> String { try await inner.fix() }
}

// MARK: - 4. Apple `container`

/// §9.5 step 4 warns against hardcoding an install command for a tool whose
/// distribution story is still moving, so this asks Homebrew what it
/// currently knows rather than assuming, and falls back to pointing at
/// Apple's releases page.
