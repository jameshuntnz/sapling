import Foundation

/// The `[build_cache]` section: build output kept on the host between jobs.
///
/// Every job starts in a fresh environment with an empty build directory, so
/// every build is a cold one. Downloading a cache from GitHub did not help —
/// restoring 919MB cost ~130s against a ~140s build — but a directory on the
/// host's own disk is a different cost. Measured with this repository's CI on
/// the node: a cold build took 156s, and the same build over a restored
/// `.build` took 75s.
///
/// Sapling only provides the directory; a workflow decides what goes in it.
/// The job sees it as `$SAPLING_BUILD_CACHE`, restores from it at the start
/// and writes back at the end. That keeps the mechanism the same for SwiftPM,
/// Xcode's compilation cache, Gradle or anything else.
///
/// Off by default, because it is shared state between jobs and so a change to
/// what the isolation boundary means — see SECURITY.md for why the scope is
/// what it is.
public struct BuildCacheConfig: Codable, Sendable {
    /// Whether macOS jobs get a build cache directory.
    public var enabled: Bool
    /// Ceiling on everything the cache holds; least recently used goes first.
    public var maxSizeGB: Int

    enum CodingKeys: String, CodingKey {
        case enabled
        case maxSizeGB = "max_size_gb"
    }

    /// Creates a build cache configuration.
    public init(enabled: Bool = false, maxSizeGB: Int = 20) {
        self.enabled = enabled
        self.maxSizeGB = maxSizeGB
    }

    /// Reads a build cache configuration, defaulting anything absent.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        maxSizeGB = try c.decodeIfPresent(Int.self, forKey: .maxSizeGB) ?? 20
    }
}
