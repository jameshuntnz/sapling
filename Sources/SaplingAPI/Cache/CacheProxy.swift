import Foundation
import SaplingCore
import Vapor

actor CacheProxy {
    struct Upstream {
        let prefix: String
        let base: String
        /// Content at these paths never changes once published, so it can be
        /// served from disk forever without revalidating.
        let immutableMatcher: @Sendable (String) -> Bool
    }

    static let upstreams: [String: Upstream] = [
        "go": Upstream(
            prefix: "go",
            base: "https://proxy.golang.org",
            // Everything under /@v/ is content-addressed except the mutable
            // version listings.
            immutableMatcher: { path in
                path.contains("/@v/") && !path.hasSuffix("/list") && !path.hasSuffix("/@latest")
            }
        ),
        "cargo-index": Upstream(
            prefix: "cargo/index",
            base: "https://index.crates.io",
            immutableMatcher: { _ in false }
        ),
        "cargo-crates": Upstream(
            prefix: "cargo/crates",
            base: "https://static.crates.io",
            immutableMatcher: { _ in true }
        ),
        "npm": Upstream(
            prefix: "npm",
            base: "https://registry.npmjs.org",
            // Tarballs are immutable; package metadata is not.
            immutableMatcher: { $0.contains("/-/") }
        ),
    ]
    .merging(mavenUpstreams) { current, _ in current }

    /// The four repositories a Kotlin/Android build resolves against.
    ///
    /// One prefix each rather than a single merged mirror, because Gradle is
    /// told about them separately and their order matters — `google()` is
    /// declared first and filtered to Android and Google groups. Collapsing
    /// them into one endpoint would lose that and change which repository an
    /// artifact resolves from.
    ///
    /// Maven layout is immutable except for two things: `maven-metadata.xml`,
    /// which is how a version range or `latest` is resolved, and anything
    /// under a `-SNAPSHOT` version, which is republished by definition.
    /// Everything else is a released coordinate and never changes, so it can
    /// be served from disk forever.
    static let mavenUpstreams: [String: Upstream] = [
        "maven-central": Upstream(
            prefix: "maven/central",
            base: "https://repo1.maven.org/maven2",
            immutableMatcher: isImmutableMavenPath
        ),
        "maven-google": Upstream(
            prefix: "maven/google",
            base: "https://dl.google.com/dl/android/maven2",
            immutableMatcher: isImmutableMavenPath
        ),
        "maven-plugins": Upstream(
            prefix: "maven/plugins",
            base: "https://plugins.gradle.org/m2",
            immutableMatcher: isImmutableMavenPath
        ),
        "maven-jitpack": Upstream(
            prefix: "maven/jitpack",
            base: "https://jitpack.io",
            // JitPack builds on demand and can republish a coordinate, so
            // nothing from it is treated as permanent.
            immutableMatcher: { _ in false }
        ),
    ]

    /// Whether a Maven path names a released artifact rather than a moving one.
    static let isImmutableMavenPath: @Sendable (String) -> Bool = { path in
        !path.contains("maven-metadata") && !path.contains("-SNAPSHOT")
    }

    let config: CacheConfig
    let root: URL
    private let session: URLSession
    /// Short revalidation window for mutable content — long enough to
    /// collapse the burst of identical requests a single job makes, short
    /// enough that a freshly published version isn't missed for long.
    let mutableTTL: TimeInterval
    /// Upstream table, overridable so the pull-through behaviour can be
    /// exercised against a local server instead of the real registries.
    let upstreamTable: [String: Upstream]

    init(config: CacheConfig, root: URL = SaplingPaths.runnerCacheDirectory) {
        self.init(config: config, root: root, upstreams: Self.upstreams, mutableTTL: 60)
    }

    init(
        config: CacheConfig,
        root: URL,
        upstreams: [String: Upstream],
        mutableTTL: TimeInterval
    ) {
        self.config = config
        self.root = root
        self.upstreamTable = upstreams
        self.mutableTTL = mutableTTL
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.timeoutIntervalForRequest = 60
        sessionConfig.timeoutIntervalForResource = 1800
        self.session = URLSession(configuration: sessionConfig)
    }

    /// Which upstreams are enabled, derived from the config's short names.
    var enabledUpstreams: [String: Upstream] {
        var out: [String: Upstream] = [:]
        for name in config.proxies {
            switch name {
            case "go":
                out["go"] = upstreamTable["go"]
            case "cargo":
                out["cargo-index"] = upstreamTable["cargo-index"]
                out["cargo-crates"] = upstreamTable["cargo-crates"]
            case "npm":
                out["npm"] = upstreamTable["npm"]
            case "maven":
                for key in Self.mavenUpstreams.keys { out[key] = upstreamTable[key] }
            default:
                Log.warn("unknown cache proxy \"\(name)\" in config; ignoring")
            }
        }
        return out.compactMapValues { $0 }
    }

    struct CachedFile: Sendable {
        let path: URL
        let contentType: String
    }

    /// Fetch through the cache, returning a local file to serve.
    func fetch(upstream key: String, path: String) async throws -> CachedFile {
        guard let upstream = enabledUpstreams[key] else {
            throw Abort(.notFound, reason: "cache proxy \"\(key)\" is not enabled")
        }
        let cacheKey = Self.cacheKey(upstream: key, path: path)
        let bodyURL = root.appendingPathComponent(key).appendingPathComponent(cacheKey)
        let metaURL = bodyURL.appendingPathExtension("meta")

        if let cached = readCache(bodyURL: bodyURL, metaURL: metaURL),
            upstream.immutableMatcher(path) || Date().timeIntervalSince(cached.storedAt) < mutableTTL
        {
            return CachedFile(path: bodyURL, contentType: cached.contentType)
        }

        guard let url = URL(string: upstream.base + "/" + path) else {
            throw Abort(.badRequest, reason: "bad upstream path")
        }

        let (tempURL, response) = try await session.download(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            try? FileManager.default.removeItem(at: tempURL)
            // A stale copy beats failing the job when upstream is unhappy.
            if let cached = readCache(bodyURL: bodyURL, metaURL: metaURL) {
                Log.warn(
                    "upstream \(url) returned \((response as? HTTPURLResponse)?.statusCode ?? -1); serving stale cache"
                )
                return CachedFile(path: bodyURL, contentType: cached.contentType)
            }
            throw Abort(
                HTTPResponseStatus(statusCode: (response as? HTTPURLResponse)?.statusCode ?? 502),
                reason: "upstream fetch failed for \(url)"
            )
        }

        let contentType = http.value(forHTTPHeaderField: "Content-Type") ?? "application/octet-stream"
        try store(tempURL: tempURL, bodyURL: bodyURL, metaURL: metaURL, contentType: contentType)
        return CachedFile(path: bodyURL, contentType: contentType)
    }

    // MARK: - Disk

    struct CacheMetadata: Codable {
        let contentType: String
        let storedAt: Date
    }

    func readCache(bodyURL: URL, metaURL: URL) -> CacheMetadata? {
        guard FileManager.default.fileExists(atPath: bodyURL.path),
            let data = try? Data(contentsOf: metaURL),
            let meta = try? SaplingJSON.decoder.decode(CacheMetadata.self, from: data)
        else {
            return nil
        }
        return meta
    }

    func store(tempURL: URL, bodyURL: URL, metaURL: URL, contentType: String) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: bodyURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: bodyURL.path) { try fm.removeItem(at: bodyURL) }
        try fm.moveItem(at: tempURL, to: bodyURL)
        let meta = CacheMetadata(contentType: contentType, storedAt: Date())
        try SaplingJSON.encoder.encode(meta).write(to: metaURL, options: .atomic)
    }

    /// Hash the path so arbitrarily deep module paths can't blow past the
    /// filesystem's name limits, and keep a readable suffix for debugging.
    static func cacheKey(upstream: String, path: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in Array(path.utf8) {
            hash ^= UInt64(byte)
            hash = hash &* 0x100_0000_01b3
        }
        let readable =
            path
            .split(separator: "/")
            .suffix(2)
            .joined(separator: "_")
            .filter { $0.isLetter || $0.isNumber || $0 == "." || $0 == "_" || $0 == "-" }
            .suffix(60)
        return String(format: "%016llx", hash) + "_" + readable
    }

    struct CacheEntry: Sendable {
        let url: URL
        let size: Int64
        let accessed: Date
    }

    /// Walking the directory tree is synchronous work; keeping it out of the
    /// actor's async context avoids blocking it on a large cache.
    nonisolated static func scan(root: URL) -> (entries: [CacheEntry], total: Int64) {
        let fm = FileManager.default
        guard
            let enumerator = fm.enumerator(
                at: root,
                includingPropertiesForKeys: [.fileSizeKey, .contentAccessDateKey],
                options: [.skipsHiddenFiles]
            )
        else { return ([], 0) }

        var entries: [CacheEntry] = []
        var total: Int64 = 0
        for case let url as URL in enumerator {
            guard url.pathExtension != "meta",
                let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentAccessDateKey]),
                let size = values.fileSize
            else { continue }
            entries.append(
                CacheEntry(
                    url: url,
                    size: Int64(size),
                    accessed: values.contentAccessDate ?? .distantPast
                ))
            total += Int64(size)
        }
        return (entries, total)
    }

    /// Trim the cache to its configured size, oldest-accessed first.
    func prune() async {
        let fm = FileManager.default
        let limit = Int64(config.maxSizeGB) * 1_073_741_824
        let root = self.root
        let scanned = await Task.detached { Self.scan(root: root) }.value
        let entries = scanned.entries
        let total = scanned.total
        guard total > limit else { return }

        var reclaimed: Int64 = 0
        for entry in entries.sorted(by: { $0.accessed < $1.accessed }) {
            guard total - reclaimed > limit else { break }
            try? fm.removeItem(at: entry.url)
            try? fm.removeItem(at: entry.url.appendingPathExtension("meta"))
            reclaimed += entry.size
        }
        Log.info("cache prune reclaimed \(reclaimed / 1_048_576)MB")
    }
}

/// Serves the cache proxy on the VM bridge gateway.
///
/// Bound to the bridge address rather than `0.0.0.0` on purpose: the egress
/// filter already treats the gateway as the one private address jobs may
/// reach, and binding wider would put this cache on the tailnet and the LAN
/// as well.
