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
    /// **Off**, and it should stay off. Measured on a freshly rebooted node,
    /// three times: a container and a macOS VM started in the same instant
    /// both attach within three seconds — `bridge100` to the container,
    /// `bridge101` to the VM — and the VM has an address in nine. Concurrency
    /// works. A full PR check runs both platforms through it cleanly.
    ///
    /// Turning this on was a wrong turn worth recording. Every observed
    /// failure had a container and a VM running together, so simultaneity
    /// looked like the cause; it is not. The failures all happened on a node
    /// that had been up for hours, and the variable is uptime, not
    /// concurrency. Serialising traded away half the node's throughput to
    /// avoid a fault it does not prevent.
    ///
    /// Kept as a lever for an operator with a node misbehaving in a way
    /// nobody has diagnosed yet — not as a default, and not as a fix.
    public var serializePlatforms: Bool

    enum CodingKeys: String, CodingKey {
        case name
        case serializePlatforms = "serialize_platforms"
    }

    /// Creates a server configuration.
    public init(
        name: String = Host.current().localizedName ?? "sapling-node",
        serializePlatforms: Bool = false
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
        serializePlatforms = try c.decodeIfPresent(Bool.self, forKey: .serializePlatforms) ?? false
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
