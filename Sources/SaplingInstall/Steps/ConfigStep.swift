import Foundation
import SaplingCore

/// Checks that a usable configuration file exists.
public struct ConfigStep: InstallStep {
    /// Name shown by `install` and `doctor`.
    public let name = "Configuration"
    let options: InstallOptions
    /// Creates the step.
    public init(options: InstallOptions) { self.options = options }

    /// Reports whether this step is already satisfied.
    public func check() async -> StepState {
        guard FileManager.default.fileExists(atPath: SaplingPaths.configFile.path) else {
            return .fixable("no config at \(SaplingPaths.configFile.path)")
        }
        do {
            let config = try SaplingConfig.load()
            try config.validate()
            let warnings = config.warnings()
            if warnings.isEmpty {
                return .ok(
                    "\(SaplingPaths.configFile.path), watching \(config.github.repos.joined(separator: ", "))"
                )
            }
            return .ok("\(SaplingPaths.configFile.path) — \(warnings.count) warning(s)")
        } catch {
            return .fixable("config is incomplete: \(error.localizedDescription)")
        }
    }

    /// Installs or configures `~/.sapling/config.toml`, including GitHub credentials.
    public func fix() async throws -> String {
        var config = (try? SaplingConfig.load()) ?? SaplingConfig()

        if let nodeName = options.nodeName { config.node.name = nodeName }
        if !options.repos.isEmpty { config.github.repos = options.repos }

        // Flags win over prompts so a full re-provision can be scripted
        // end-to-end (§9.5 step 6).
        if let token = options.githubToken {
            config.github.auth = .pat
            config.github.token = token
        } else if let appID = options.githubAppID {
            config.github.auth = .app
            config.github.appID = appID
            config.github.installationID = options.githubInstallationID
            config.github.privateKeyPath = options.githubPrivateKeyPath
        }

        if options.nonInteractive {
            try config.save()
            try config.validate()
            return "wrote \(SaplingPaths.configFile.path)"
        }

        if config.github.repos.isEmpty {
            // Blank is a real answer under App auth — the installation already
            // says which repositories this node may see, and repeating that
            // here just gives it a second place to drift from.
            let raw =
                Prompt.line(
                    "Repositories to watch (comma-separated owner/repo, or blank for every "
                        + "private repo the GitHub App can reach)") ?? ""
            config.github.repos =
                raw
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        }

        if (try? config.validate()) == nil {
            let choice = Prompt.choose(
                "\nGitHub credentials — a GitHub App is recommended (15,000 req/hr and finer-grained permissions); a PAT is the quick start (5,000 req/hr).",
                options: ["GitHub App (recommended)", "Personal access token"],
                default: 0
            )
            if choice.hasPrefix("GitHub App") {
                config.github.auth = .app
                config.github.appID = Prompt.line("GitHub App ID", default: config.github.appID)
                config.github.installationID = Prompt.line(
                    "Installation ID", default: config.github.installationID)
                let defaultKeyPath = SaplingPaths.home.appendingPathComponent("github-app.pem").path
                config.github.privateKeyPath = Prompt.line(
                    "Path to the App private key (.pem)", default: defaultKeyPath)
            } else {
                config.github.auth = .pat
                config.github.token = Prompt.secret("GitHub personal access token (input hidden)")
            }
        }

        try config.save()
        try config.validate()
        return "wrote \(SaplingPaths.configFile.path) (0600)"
    }
}

// MARK: - 7. VM SSH key

/// The agent talks to macOS VMs over SSH with a key rather than the base
/// image's password, so a leaked image password isn't enough to reach a
/// running build.
