import Foundation

/// Works out which daemon a client should talk to.
public enum ServerEndpoint {
    /// Port the control plane listens on unless configured otherwise.
    public static let defaultPort = 8734

    /// Last-resort endpoint: the daemon on this machine.
    public static var loopback: URL {
        var components = URLComponents()
        components.scheme = "http"
        components.host = "127.0.0.1"
        components.port = defaultPort
        guard let url = components.url else {
            preconditionFailure("the loopback endpoint constant is malformed")
        }
        return url
    }

    /// Resolution order, most explicit first: flag, environment, saved client
    /// config, the local daemon's own config, loopback.
    public static func resolve(explicit: String? = nil) -> URL {
        if let explicit, let url = normalize(explicit) { return url }
        if let env = ProcessInfo.processInfo.environment["SAPLING_SERVER"], let url = normalize(env) {
            return url
        }
        if let saved = ClientConfig.load().server, let url = normalize(saved) { return url }
        if let local = try? SaplingConfig.load() {
            let host = local.server.bindMode == .tailscale ? "127.0.0.1" : local.server.bind
            if let url = normalize("\(host):\(local.server.port)") { return url }
        }
        return loopback
    }

    static func normalize(_ raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.contains("://") { return URL(string: trimmed) }
        // Bare host means "add the default port"; host:port is used as given.
        if trimmed.contains(":") { return URL(string: "http://\(trimmed)") }
        return URL(string: "http://\(trimmed):\(defaultPort)")
    }
}
