import Foundation
import Testing

@testable import SaplingAgent
@testable import SaplingCore

/// The host cannot know which gateway a job will reach it on.
///
/// That depends on which bridge the environment lands on, which does not
/// exist until the environment does. So the environment resolves it, and
/// these cover the shell that does the resolving.
@Suite("Cache endpoint")
struct CacheEndpointTests {
    @Test("exports nothing when caching is off")
    func cachingOff() {
        var config = CacheConfig()
        config.enabled = false
        #expect(CacheEndpoint.exportScript(cache: config, platform: .linux).isEmpty)
        #expect(CacheEndpoint.exportScript(cache: nil, platform: .linux).isEmpty)
    }

    @Test("exports nothing when no proxy is enabled")
    func noProxies() {
        var config = CacheConfig()
        config.proxies = []
        #expect(CacheEndpoint.exportScript(cache: config, platform: .linux).isEmpty)
    }

    /// No address is baked in.
    ///
    /// The bug this replaces put the host's guess — whichever bridge came up
    /// first — into every job on both platforms.
    @Test("hard-codes no address, on either platform")
    func noHardCodedAddress() {
        for platform in [JobPlatform.linux, .macos] {
            let script = CacheEndpoint.exportScript(cache: CacheConfig(), platform: platform)
            #expect(!script.contains("192.168."))
            #expect(script.contains("sapling_gateway"))
        }
    }

    /// `ip` is not in the runner image — its absence was once read as "this
    /// container has no default route" and cost an evening.
    @Test("Linux reads /proc/net/route rather than reaching for ip(8)")
    func linuxAvoidsIP() {
        let script = CacheEndpoint.exportScript(cache: CacheConfig(), platform: .linux)
        #expect(script.contains("/proc/net/route"))
        #expect(!script.contains("ip route"))
    }

    @Test("macOS asks route(8) for its default gateway")
    func macosUsesRoute() {
        let script = CacheEndpoint.exportScript(cache: CacheConfig(), platform: .macos)
        #expect(script.contains("route -n get default"))
    }

    /// A cache variable pointing at an address nothing answers on is worse
    /// than no cache variable: the egress filter blocks it and the build
    /// fails for a reason nothing names.
    @Test("proves the proxy answers before exporting anything")
    func probesBeforeExporting() {
        var config = CacheConfig()
        config.proxies = ["go"]
        let script = CacheEndpoint.exportScript(cache: config, platform: .linux)
        let probeIndex = script.range(of: CacheConfig.healthPath)
        let exportIndex = script.range(of: "export GOPROXY")
        #expect(probeIndex != nil)
        #expect(exportIndex != nil)
        if let probeIndex, let exportIndex {
            #expect(probeIndex.lowerBound < exportIndex.lowerBound)
        }
        #expect(script.contains("fetching directly"))
    }

    /// The script is generated, spliced into a larger one, and only ever run
    /// on a node — so a syntax error in it surfaces as a failed job on real
    /// hardware. `bash -n` catches that here instead.
    ///
    /// The Linux branch's arithmetic was checked against the real runner image
    /// on the node: `/proc/net/route` gives `0140A8C0` and the expression
    /// yields `192.168.64.1`, the container's actual gateway.
    @Test("generates shell bash will accept, on both platforms")
    func generatesValidShell() async throws {
        for platform in [JobPlatform.linux, .macos] {
            let script = CacheEndpoint.exportScript(cache: CacheConfig(), platform: platform)
            let file = FileManager.default.temporaryDirectory
                .appendingPathComponent("cache-endpoint-\(platform.rawValue)-\(UUID().uuidString).sh")
            try script.write(to: file, atomically: true, encoding: .utf8)
            defer { try? FileManager.default.removeItem(at: file) }
            let result = try await ProcessRunner.run("bash", ["-n", file.path], timeout: .seconds(20))
            #expect(result.succeeded, "\(platform.rawValue): \(result.stderr)")
        }
    }

    /// The mirror address is exported and nothing more.
    ///
    /// Gradle has no global mirror setting, so the alternative is an init
    /// script that clears the build's own repository list from outside the
    /// project — which reorders resolution, breaks the content filters
    /// `google()` is declared with, and fails the build when it is wrong.
    @Test("Maven exports an address, and does not rewrite the build")
    func mavenExportsAnAddressOnly() {
        var config = CacheConfig()
        config.proxies = ["maven"]
        let script = CacheEndpoint.exportScript(cache: config, platform: .linux)
        #expect(script.contains("SAPLING_MAVEN"))
        #expect(script.contains("/maven"))
        // Nothing that reaches into the build.
        #expect(!script.contains("init.gradle"))
        #expect(!script.contains("repositories"))
        #expect(!script.contains("settingsEvaluated"))
    }

    @Test("exports only the proxies that are enabled")
    func onlyEnabledProxies() {
        var config = CacheConfig()
        config.proxies = ["npm"]
        let script = CacheEndpoint.exportScript(cache: config, platform: .linux)
        #expect(script.contains("NPM_CONFIG_REGISTRY"))
        #expect(!script.contains("GOPROXY"))
        #expect(!script.contains("CARGO_REGISTRIES_CRATES_IO_PROTOCOL"))
    }
}
