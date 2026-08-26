import Foundation
import TOMLKit

/// Saved client settings, so the CLI and menu bar app don't have to be
/// told the server address every time.
public struct ClientConfig: Codable, Sendable {
    /// Daemon address as `host`, `host:port`, or a full URL.
    public var server: String?

    enum CodingKeys: String, CodingKey { case server }

    /// Creates a client configuration.
    public init(server: String? = nil) { self.server = server }

    /// Creates a client configuration.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        server = try c.decodeIfPresent(String.self, forKey: .server)
    }

    /// Reads saved client settings, falling back to empty defaults when the
    /// file is absent or unreadable.
    public static func load(from url: URL = SaplingPaths.clientConfigFile) -> ClientConfig {
        guard let text = try? String(contentsOf: url, encoding: .utf8),
            let config = try? TOMLDecoder().decode(ClientConfig.self, from: text)
        else {
            return ClientConfig()
        }
        return config
    }

    /// Writes client settings, creating the containing directory if needed.
    public func save(to url: URL = SaplingPaths.clientConfigFile) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try TOMLEncoder().encode(self).write(to: url, atomically: true, encoding: .utf8)
    }
}
