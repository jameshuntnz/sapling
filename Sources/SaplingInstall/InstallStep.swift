import Foundation
import SaplingCore

/// The result of checking one piece of the installation.
public enum StepState: Sendable {
    /// Already in the desired state.
    case ok(String)
    /// Missing, and this step knows how to fix it.
    case fixable(String)
    /// Missing, and only a human can finish it (§9.5 steps 5 and 7).
    case manual(String, instructions: String)
    /// Present but broken.
    case failed(String)

    /// Whether the step needs no further action.
    public var isOK: Bool { if case .ok = self { true } else { false } }

    /// One-line description of the state, for printing.
    public var summary: String {
        switch self {
        case .ok(let text), .fixable(let text), .failed(let text):
            text
        case .manual(let text, _):
            text
        }
    }
}

/// One idempotent unit of `sapling install`.
///
/// Splitting every step into check-then-fix is what makes §9.5's "safe to
/// re-run after a partial failure, an OS update, or a wipe" fall out for
/// free: `install` runs check and fixes what's missing, `doctor` runs exactly
/// the same checks and changes nothing.
public protocol InstallStep: Sendable {
    var name: String { get }
    var detail: String { get }
    func check() async -> StepState
    /// Only called when `check()` returned `.fixable`.
    func fix() async throws -> String
}

extension InstallStep {
    /// Longer explanation, when the step has one.
    public var detail: String { "" }
    /// Brings the step into the desired state.
    ///
    /// Only called when `check()` returned `.fixable`.
    public func fix() async throws -> String {
        throw InstallError("\(name) cannot be fixed automatically")
    }
}

/// An install step that could not complete.
public struct InstallError: Error, LocalizedError, Sendable {
    /// What went wrong, phrased so it can be printed verbatim.
    public let message: String
    /// Creates install options.
    public init(_ message: String) { self.message = message }
    /// The message, for `LocalizedError`.
    public var errorDescription: String? { message }
}

/// Options that change what the installer writes, gathered up front so a
/// scripted re-provision can pass everything non-interactively (§9.5 step 6).
public struct InstallOptions: Sendable {
    /// Personal access token, for the quick-start path.
    public var githubToken: String?
    /// GitHub App id, for the recommended path.
    public var githubAppID: String?
    /// The App installation covering the watched repositories.
    public var githubInstallationID: String?
    /// Path to the App's private key.
    public var githubPrivateKeyPath: String?
    /// Repositories to watch, in `owner/repo` form.
    public var repos: [String]
    /// Name to give this node.
    public var nodeName: String?
    /// User the LaunchDaemon runs as. `nil` means root, which is required for
    /// the pf-based egress filter (§8).
    public var runAsUser: String?
    /// Never prompt; fail instead of asking.
    public var nonInteractive: Bool
    /// Do everything except registering the LaunchDaemon.
    public var skipDaemon: Bool

    /// Creates install options.
    public init(
        githubToken: String? = nil,
        githubAppID: String? = nil,
        githubInstallationID: String? = nil,
        githubPrivateKeyPath: String? = nil,
        repos: [String] = [],
        nodeName: String? = nil,
        runAsUser: String? = nil,
        nonInteractive: Bool = false,
        skipDaemon: Bool = false
    ) {
        self.githubToken = githubToken
        self.githubAppID = githubAppID
        self.githubInstallationID = githubInstallationID
        self.githubPrivateKeyPath = githubPrivateKeyPath
        self.repos = repos
        self.nodeName = nodeName
        self.runAsUser = runAsUser
        self.nonInteractive = nonInteractive
        self.skipDaemon = skipDaemon
    }
}
