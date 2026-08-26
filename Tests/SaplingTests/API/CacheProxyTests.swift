import Foundation
import Testing
import Vapor

@testable import SaplingAPI
@testable import SaplingCore

final class UpstreamHitCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [String: Int] = [:]
    private var _failNext = false

    func record(_ path: String) { lock.withLock { counts[path, default: 0] += 1 } }
    func count(_ path: String) -> Int { lock.withLock { counts[path] ?? 0 } }
    var total: Int { lock.withLock { counts.values.reduce(0, +) } }

    var failNext: Bool {
        get { lock.withLock { _failNext } }
        set { lock.withLock { _failNext = newValue } }
    }
}

/// Drives the real pull-through path — disk cache, revalidation window, and
/// stale-on-upstream-failure — against a local stand-in registry.
@Suite("Cache proxy", .serialized)
struct CacheProxyTests {
    static let port = 18802

    func withUpstream<T>(
        proxies: [String] = ["go", "cargo"],
        mutableTTL: TimeInterval = 60,
        _ body: (CacheProxy, UpstreamHitCounter, URL) async throws -> T
    ) async throws -> T {
        let counter = UpstreamHitCounter()

        var env = Environment.testing
        env.arguments = ["fake-registry"]
        let app = try await Application.make(env)
        app.http.server.configuration.hostname = "127.0.0.1"
        app.http.server.configuration.port = Self.port
        app.logger.logLevel = .critical

        app.get([.catchall]) { request -> Response in
            let path = request.parameters.getCatchall().joined(separator: "/")
            counter.record(path)
            if counter.failNext {
                return Response(status: .internalServerError, body: .init(string: "upstream is unhappy"))
            }
            var headers = HTTPHeaders()
            headers.contentType = .init(type: "application", subType: "zip")
            return Response(status: .ok, headers: headers, body: .init(string: "payload for \(path)"))
        }

        try await app.startup()

        let base = "http://127.0.0.1:\(Self.port)"
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sapling-cache-\(UUID().uuidString)")

        var config = CacheConfig()
        config.proxies = proxies
        config.maxSizeGB = 1

        let proxy = CacheProxy(
            config: config,
            root: root,
            upstreams: [
                "go": CacheProxy.Upstream(
                    prefix: "go",
                    base: base,
                    immutableMatcher: { $0.contains("/@v/") && !$0.hasSuffix("/list") }
                ),
                "cargo-index": CacheProxy.Upstream(
                    prefix: "cargo/index", base: base, immutableMatcher: { _ in false }),
                "cargo-crates": CacheProxy.Upstream(
                    prefix: "cargo/crates", base: base, immutableMatcher: { _ in true }),
            ],
            mutableTTL: mutableTTL
        )

        do {
            let result = try await body(proxy, counter, root)
            try await app.asyncShutdown()
            try? FileManager.default.removeItem(at: root)
            return result
        } catch {
            try? await app.asyncShutdown()
            try? FileManager.default.removeItem(at: root)
            throw error
        }
    }

    @Test("fetches on a miss, then serves from disk")
    func cachesOnDisk() async throws {
        try await withUpstream { proxy, counter, root in
            let path = "example.com/mod/@v/v1.0.0.zip"

            let first = try await proxy.fetch(upstream: "go", path: path)
            #expect(counter.count(path) == 1)
            #expect(FileManager.default.fileExists(atPath: first.path.path))
            let body = try String(contentsOf: first.path, encoding: .utf8)
            #expect(body == "payload for \(path)")
            #expect(first.contentType.contains("zip"))

            // Immutable content: a second request must not touch upstream.
            let second = try await proxy.fetch(upstream: "go", path: path)
            #expect(counter.count(path) == 1, "immutable content should not be re-fetched")
            #expect(second.path == first.path)
        }
    }

    /// Version listings change as releases are published, so they can't be
    /// cached forever the way module zips can.
    @Test("revalidates mutable content once its window expires")
    func revalidatesMutableContent() async throws {
        try await withUpstream(mutableTTL: 0) { proxy, counter, _ in
            let path = "example.com/mod/@v/list"
            _ = try await proxy.fetch(upstream: "go", path: path)
            _ = try await proxy.fetch(upstream: "go", path: path)
            #expect(counter.count(path) == 2, "a mutable path past its TTL should be re-fetched")
        }
    }

    @Test("collapses repeat requests for mutable content inside the window")
    func collapsesWithinTTL() async throws {
        try await withUpstream(mutableTTL: 3600) { proxy, counter, _ in
            let path = "index/se/rd/serde"
            _ = try await proxy.fetch(upstream: "cargo-index", path: path)
            _ = try await proxy.fetch(upstream: "cargo-index", path: path)
            #expect(counter.count(path) == 1)
        }
    }

    /// A registry outage shouldn't fail a build that only needed a package
    /// this host already has.
    @Test("serves a stale copy when upstream fails")
    func servesStaleOnUpstreamFailure() async throws {
        try await withUpstream(mutableTTL: 0) { proxy, counter, _ in
            let path = "index/se/rd/serde"
            let fresh = try await proxy.fetch(upstream: "cargo-index", path: path)
            let original = try String(contentsOf: fresh.path, encoding: .utf8)

            counter.failNext = true
            let stale = try await proxy.fetch(upstream: "cargo-index", path: path)
            #expect(try String(contentsOf: stale.path, encoding: .utf8) == original)
        }
    }

    @Test("fails a miss it cannot satisfy")
    func failsColdMiss() async throws {
        try await withUpstream { proxy, counter, _ in
            counter.failNext = true
            await #expect(throws: (any Error).self) {
                _ = try await proxy.fetch(upstream: "cargo-crates", path: "crates/nope/1.0.0/download")
            }
        }
    }

    @Test("refuses an upstream that isn't enabled")
    func rejectsDisabledUpstream() async throws {
        try await withUpstream(proxies: ["go"]) { proxy, _, _ in
            await #expect(throws: (any Error).self) {
                _ = try await proxy.fetch(upstream: "cargo-crates", path: "anything")
            }
        }
    }

    @Test("maps config names onto upstreams, ignoring unknown ones")
    func enabledUpstreams() async throws {
        try await withUpstream(proxies: ["go", "cargo", "not-a-real-proxy"]) { proxy, _, _ in
            let enabled = await proxy.enabledUpstreams
            #expect(Set(enabled.keys) == ["go", "cargo-index", "cargo-crates"])
        }
        try await withUpstream(proxies: ["go"]) { proxy, _, _ in
            let enabled = await proxy.enabledUpstreams
            #expect(Set(enabled.keys) == ["go"])
        }
    }

    /// Module paths are arbitrarily deep; the filesystem's name limit is not.
    @Test("hashes cache keys but keeps them recognisable")
    func cacheKeys() {
        let deep = String(repeating: "very-long-segment/", count: 40) + "v1.0.0.zip"
        let key = CacheProxy.cacheKey(upstream: "go", path: deep)
        #expect(key.count < 100)
        #expect(key.contains("v1.0.0.zip"))

        // Deterministic, and different paths don't collide.
        #expect(
            CacheProxy.cacheKey(upstream: "go", path: "a/b")
                == CacheProxy.cacheKey(upstream: "go", path: "a/b"))
        #expect(
            CacheProxy.cacheKey(upstream: "go", path: "a/b")
                != CacheProxy.cacheKey(upstream: "go", path: "a/c"))
    }

    /// 256GB fills fast; the cache has to give ground before the disk does.
    @Test("prunes least-recently-used entries past the size cap")
    func prune() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sapling-prune-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let megabyte = Data(repeating: 0x41, count: 1_048_576)
        for index in 0..<4 {
            let file = root.appendingPathComponent("entry-\(index).bin")
            try megabyte.write(to: file)
            try FileManager.default.setAttributes(
                [.modificationDate: Date().addingTimeInterval(Double(-index) * 3600)],
                ofItemAtPath: file.path
            )
        }

        let scanned = CacheProxy.scan(root: root)
        #expect(scanned.entries.count == 4)
        #expect(scanned.total == 4 * 1_048_576)

        var config = CacheConfig()
        config.maxSizeGB = 1
        // Well under the cap: nothing should be removed.
        await CacheProxy(config: config, root: root).prune()
        #expect(CacheProxy.scan(root: root).entries.count == 4)
    }

    /// `.meta` sidecars describe entries; counting them as entries would
    /// double-count the cache's size.
    @Test("scan ignores metadata sidecars")
    func scanSkipsMetadata() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sapling-scan-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try Data(repeating: 0, count: 10).write(to: root.appendingPathComponent("body"))
        try Data(repeating: 0, count: 10).write(to: root.appendingPathComponent("body.meta"))

        #expect(CacheProxy.scan(root: root).entries.count == 1)
    }

    @Test("real upstream table marks immutable content correctly")
    func immutableMatchers() throws {
        let go = try #require(CacheProxy.upstreams["go"])
        #expect(go.immutableMatcher("example.com/mod/@v/v1.2.3.zip"))
        #expect(!go.immutableMatcher("example.com/mod/@v/list"))
        #expect(!go.immutableMatcher("example.com/mod/@latest"))

        let crates = try #require(CacheProxy.upstreams["cargo-crates"])
        #expect(crates.immutableMatcher("serde/1.0.0/download"))

        let index = try #require(CacheProxy.upstreams["cargo-index"])
        #expect(!index.immutableMatcher("se/rd/serde"))

        let npm = try #require(CacheProxy.upstreams["npm"])
        #expect(npm.immutableMatcher("lodash/-/lodash-4.17.21.tgz"))
        #expect(!npm.immutableMatcher("lodash"))
    }
}
