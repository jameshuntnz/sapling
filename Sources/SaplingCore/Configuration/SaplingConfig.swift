import Foundation
import TOMLKit

/// The whole of `~/.sapling/config.toml`.
public struct SaplingConfig: Codable, Sendable {
    /// Identity of this node.
    public var node: NodeConfig
    /// Control-plane listener settings.
    public var server: ServerConfig
    /// Credentials and the repositories to watch.
    public var github: GitHubConfig
    /// macOS job settings.
    public var macos: MacOSConfig
    /// Linux job settings.
    public var linux: LinuxConfig
    /// Egress filtering for job environments.
    public var network: NetworkConfig
    /// Host-side package caches.
    public var cache: CacheConfig
    /// Where the daemon looks for new versions of itself.
    public var update: UpdateConfig

    enum CodingKeys: String, CodingKey {
        case node, server, github, macos, linux, network, cache, update
    }

    /// Creates a configuration.
    public init(
        node: NodeConfig = NodeConfig(),
        server: ServerConfig = ServerConfig(),
        github: GitHubConfig = GitHubConfig(),
        macos: MacOSConfig = MacOSConfig(),
        linux: LinuxConfig = LinuxConfig(),
        network: NetworkConfig = NetworkConfig(),
        cache: CacheConfig = CacheConfig(),
        update: UpdateConfig = UpdateConfig()
    ) {
        self.node = node
        self.server = server
        self.github = github
        self.macos = macos
        self.linux = linux
        self.network = network
        self.cache = cache
        self.update = update
    }

    /// Creates a configuration.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        node = try c.decodeIfPresent(NodeConfig.self, forKey: .node) ?? NodeConfig()
        server = try c.decodeIfPresent(ServerConfig.self, forKey: .server) ?? ServerConfig()
        github = try c.decodeIfPresent(GitHubConfig.self, forKey: .github) ?? GitHubConfig()
        macos = try c.decodeIfPresent(MacOSConfig.self, forKey: .macos) ?? MacOSConfig()
        linux = try c.decodeIfPresent(LinuxConfig.self, forKey: .linux) ?? LinuxConfig()
        network = try c.decodeIfPresent(NetworkConfig.self, forKey: .network) ?? NetworkConfig()
        cache = try c.decodeIfPresent(CacheConfig.self, forKey: .cache) ?? CacheConfig()
        update = try c.decodeIfPresent(UpdateConfig.self, forKey: .update) ?? UpdateConfig()
    }

    // MARK: - Loading and saving

    /// Reads and parses the config file.
    ///
    /// - Throws: `ConfigError` if the file is absent or cannot be parsed.
    public static func load(from url: URL = SaplingPaths.configFile) throws -> SaplingConfig {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ConfigError("no config at \(url.path) — run `sapling install` first")
        }
        let text = try String(contentsOf: url, encoding: .utf8)
        do {
            return try TOMLDecoder().decode(SaplingConfig.self, from: text)
        } catch {
            throw ConfigError("could not parse \(url.path): \(error)")
        }
    }

    /// Load if present, otherwise defaults.
    ///
    /// Used by `doctor`, which has to be able to report on a half-installed machine.
    public static func loadOrDefault(from url: URL = SaplingPaths.configFile) -> SaplingConfig {
        (try? load(from: url)) ?? SaplingConfig()
    }

    /// Write with `0600` — this file holds a PAT or App key path (§8).
    public func save(to url: URL = SaplingPaths.configFile) throws {
        try SaplingPaths.ensureHomeDirectory()
        let text = try TOMLEncoder().encode(self)
        try text.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    // MARK: - Validation

    /// Non-fatal advisories surfaced by `doctor` and at daemon startup.
    public func warnings() -> [String] {
        var out: [String] = []
        if macos.maxConcurrent > MacOSConfig.appleConcurrencyLimit {
            out.append(
                "macos.max_concurrent is \(macos.maxConcurrent); Apple allows at most \(MacOSConfig.appleConcurrencyLimit) concurrent macOS VMs, so it is being clamped to \(MacOSConfig.appleConcurrencyLimit)"
            )
        }
        if !network.blockPrivateRanges {
            out.append(
                "network.block_private_ranges is off — jobs can reach your LAN, including anything else this Mac hosts (§8)"
            )
        }
        if github.auth == .pat {
            out.append(
                "using a PAT (5,000 req/hr). A GitHub App is recommended for multiple repos or a short poll interval"
            )
        }
        if github.pollIntervalSeconds < 10 {
            out.append(
                "github.poll_interval_seconds is \(github.pollIntervalSeconds); anything under 10s burns rate limit for little benefit"
            )
        }
        if server.bindMode == .all {
            out.append(
                "server.bind is \"all\" — the control plane is exposed beyond Tailscale, which §8 explicitly warns against"
            )
        }
        return out
    }

    /// Errors that stop the daemon from starting.
    public func validate() throws {
        if github.repos.isEmpty {
            throw ConfigError("github.repos is empty — nothing to poll. Add at least one \"owner/repo\".")
        }
        for repo in github.repos where repo.split(separator: "/").count != 2 {
            throw ConfigError("github.repos entry \"\(repo)\" is not in owner/repo form")
        }
        switch github.auth {
        case .pat:
            guard let token = github.token, !token.isEmpty else {
                throw ConfigError("github.auth is \"pat\" but github.token is not set")
            }
        case .app:
            guard let appID = github.appID, !appID.isEmpty else {
                throw ConfigError("github.auth is \"app\" but github.app_id is not set")
            }
            _ = appID
            guard let installationID = github.installationID, !installationID.isEmpty else {
                throw ConfigError("github.auth is \"app\" but github.installation_id is not set")
            }
            _ = installationID
            guard let keyPath = github.resolvedPrivateKeyPath, !keyPath.isEmpty else {
                throw ConfigError("github.auth is \"app\" but github.private_key_path is not set")
            }
            guard FileManager.default.fileExists(atPath: keyPath) else {
                throw ConfigError("GitHub App private key not found at \(keyPath)")
            }
        }
        if !macos.enabled && !linux.enabled {
            throw ConfigError("both macos.enabled and linux.enabled are false — this node can't run anything")
        }
        if server.port < 1 || server.port > 65535 {
            throw ConfigError("server.port \(server.port) is out of range")
        }
    }
}
