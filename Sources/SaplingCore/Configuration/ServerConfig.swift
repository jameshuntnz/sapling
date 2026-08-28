import Foundation

/// Which interface the control-plane API listens on.
public enum BindMode: Sendable, Equatable {
    case tailscale
    case loopback
    case explicit(String)
    case all

    /// The value as it appears in `config.toml`.
    public var rawValue: String {
        switch self {
        case .tailscale: "tailscale"
        case .loopback: "loopback"
        case .all: "all"
        case .explicit(let address): address
        }
    }

    /// Creates a server configuration.
    public init(rawValue: String) {
        switch rawValue.lowercased() {
        case "tailscale", "auto": self = .tailscale
        case "loopback", "localhost", "127.0.0.1": self = .loopback
        case "all", "0.0.0.0", "*": self = .all
        default: self = .explicit(rawValue)
        }
    }
}

/// The `[node]` section: how this machine identifies itself.
public struct NodeConfig: Codable, Sendable {
    /// Human-readable node name, also the basis of its stable id.
    public var name: String

    /// Run one platform at a time, whatever the per-platform slot counts say.
    ///
    /// On by default, because the concurrency it gives up is not concurrency
    /// this node has. Measured three times: a macOS VM and an Apple
    /// `container` start together, the VM's vmnet interface is created and
    /// never attached to a bridge, the VM times out after five minutes, and
    /// its teardown then destroys the bridge the container is using — killing
    /// the Linux job. Sapling requeues the macOS job, which now runs alone and
    /// boots in eight seconds.
    ///
    /// That is the "fails once, then works on the retry with no intervention"
    /// pattern, and the retry works *because* the first attempt's failure
    /// killed the other job. So the node already serialises; it just does it
    /// by destroying one job and spending five minutes on it. Doing it
    /// deliberately keeps both jobs and loses nothing real.
    ///
    /// Turn it off to test whether concurrency has started working — on a node
    /// with no leaked `tart run` processes, which is the state that appears to
    /// break vmnet attachment. See docs/NETWORKING.md.
    public var serializePlatforms: Bool

    enum CodingKeys: String, CodingKey {
        case name
        case serializePlatforms = "serialize_platforms"
    }

    /// Creates a server configuration.
    public init(
        name: String = Host.current().localizedName ?? "sapling-node",
        serializePlatforms: Bool = true
    ) {
        self.name = name
        self.serializePlatforms = serializePlatforms
    }

    /// Creates a server configuration.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name =
            try c.decodeIfPresent(String.self, forKey: .name)
            ?? Host.current().localizedName
            ?? "sapling-node"
        serializePlatforms = try c.decodeIfPresent(Bool.self, forKey: .serializePlatforms) ?? true
    }
}

/// The `[server]` section: where the control-plane API listens.
public struct ServerConfig: Codable, Sendable {
    /// Bind mode as written in the config file.
    public var bind: String
    /// Port the API listens on.
    public var port: Int

    /// The parsed form of `bind`.
    public var bindMode: BindMode { BindMode(rawValue: bind) }

    enum CodingKeys: String, CodingKey { case bind, port }

    /// Creates a server configuration.
    public init(bind: String = "tailscale", port: Int = 8734) {
        self.bind = bind
        self.port = port
    }

    /// Creates a server configuration.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        bind = try c.decodeIfPresent(String.self, forKey: .bind) ?? "tailscale"
        port = try c.decodeIfPresent(Int.self, forKey: .port) ?? 8734
    }
}
