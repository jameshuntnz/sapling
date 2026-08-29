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
    /// Cancel the workflow run when this node gives up on one of its jobs.
    ///
    /// Off by default, because it is still a whole-run operation: GitHub has
    /// no per-job cancel, confirmed against its REST API — the only endpoints
    /// for workflow jobs are reads. Left off, an abandoned job waits out
    /// GitHub's own timeout, which has been measured at nine hours.
    ///
    /// It is no longer indiscriminate, though. When it is on, the run is only
    /// cancelled if nothing else in it is working: a sibling mid-build on the
    /// other platform is not killed to tidy up after this job, and if GitHub
    /// cannot be asked, the run is left alone. So the trade this makes is now
    /// "a run that has nothing left to lose ends promptly" rather than "one
    /// stuck job takes its siblings with it".
    public var cancelRunWhenExhausted: Bool

    /// Whether discovery may watch public repositories.
    ///
    /// Off by default. A public repository is not dangerous in itself — the
    /// danger was always fork pull requests, and `ForkPolicy` refuses those
    /// unconditionally, on every repository, with no way to turn it off. What
    /// this switch actually decides is whether a public repository can arrive
    /// through an App installation nobody re-read, which is a different
    /// question from whether one may be run at all.
    ///
    /// Turning it on is not the whole job. Set GitHub's own
    /// *Require approval for all outside collaborators* on each public
    /// repository: that stops a fork's jobs reaching the queue in the first
    /// place, where this node can only decline them and leave them waiting out
    /// GitHub's timeout.
    public var allowPublicRepos: Bool

    enum CodingKeys: String, CodingKey {
        case auth, token, repos
        case appID = "app_id"
        case installationID = "installation_id"
        case privateKeyPath = "private_key_path"
        case pollIntervalSeconds = "poll_interval_seconds"
        case allowPublicRepos = "allow_public_repos"
        case apiBaseURL = "api_base_url"
        case cancelRunWhenExhausted = "cancel_run_when_exhausted"
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
        cancelRunWhenExhausted: Bool = false,
        allowPublicRepos: Bool = false,
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
        self.cancelRunWhenExhausted = cancelRunWhenExhausted
        self.allowPublicRepos = allowPublicRepos
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
        cancelRunWhenExhausted =
            try c.decodeIfPresent(Bool.self, forKey: .cancelRunWhenExhausted) ?? false
        allowPublicRepos = try c.decodeIfPresent(Bool.self, forKey: .allowPublicRepos) ?? false
    }

    /// The private key path with `~` expanded, or `nil` if unset.
    public var resolvedPrivateKeyPath: String? {
        privateKeyPath.map(SaplingPaths.expandTilde)
    }
}
