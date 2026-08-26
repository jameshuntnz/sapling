import Foundation

/// How Sapling authenticates to the GitHub API.
public enum GitHubAuthMode: String, Codable, Sendable {
    case app
    case pat
}

/// How the control-plane API picks its bind address.
///
/// `.tailscale` is the default and the documented posture (§8): resolve the
/// host's Tailscale address and bind only that, so the API is unreachable
/// from the LAN or the public internet even if the firewall is misconfigured.

/// The `[github]` section: which repositories to watch and how to reach them.
public struct GitHubConfig: Codable, Sendable {
    /// Which credential type the other fields describe.
    public var auth: GitHubAuthMode
    /// Personal access token, used when `auth == .pat`.
    public var token: String?
    /// GitHub App credentials, used when `auth == .app`.
    public var appID: String?
    /// The App installation that grants access to the watched repositories.
    public var installationID: String?
    /// Path to the App's private key, `~` accepted.
    public var privateKeyPath: String?
    /// Repositories to poll, each in `owner/repo` form.
    public var repos: [String]
    /// How often to ask GitHub for queued jobs.
    public var pollIntervalSeconds: Int
    /// GitHub API root.
    ///
    /// Overridable for GitHub Enterprise, and for tests.
    public var apiBaseURL: String

    enum CodingKeys: String, CodingKey {
        case auth, token, repos
        case appID = "app_id"
        case installationID = "installation_id"
        case privateKeyPath = "private_key_path"
        case pollIntervalSeconds = "poll_interval_seconds"
        case apiBaseURL = "api_base_url"
    }

    /// Creates a GitHub configuration.
    public init(
        auth: GitHubAuthMode = .app,
        token: String? = nil,
        appID: String? = nil,
        installationID: String? = nil,
        privateKeyPath: String? = nil,
        repos: [String] = [],
        pollIntervalSeconds: Int = 30,
        apiBaseURL: String = "https://api.github.com"
    ) {
        self.auth = auth
        self.token = token
        self.appID = appID
        self.installationID = installationID
        self.privateKeyPath = privateKeyPath
        self.repos = repos
        self.pollIntervalSeconds = pollIntervalSeconds
        self.apiBaseURL = apiBaseURL
    }

    /// Creates a GitHub configuration.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        auth = try c.decodeIfPresent(GitHubAuthMode.self, forKey: .auth) ?? .app
        token = try c.decodeIfPresent(String.self, forKey: .token)
        appID = try c.decodeIfPresent(String.self, forKey: .appID)
        installationID = try c.decodeIfPresent(String.self, forKey: .installationID)
        privateKeyPath = try c.decodeIfPresent(String.self, forKey: .privateKeyPath)
        repos = try c.decodeIfPresent([String].self, forKey: .repos) ?? []
        pollIntervalSeconds = try c.decodeIfPresent(Int.self, forKey: .pollIntervalSeconds) ?? 30
        apiBaseURL = try c.decodeIfPresent(String.self, forKey: .apiBaseURL) ?? "https://api.github.com"
    }

    /// The private key path with `~` expanded, or `nil` if unset.
    public var resolvedPrivateKeyPath: String? {
        privateKeyPath.map(SaplingPaths.expandTilde)
    }
}
