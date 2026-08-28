import Foundation
import SaplingCore

/// Points a job's package managers at the host's cache proxy.
///
/// The host used to guess which gateway a job would reach it on:
/// `interfaces.first.address`, which is whichever bridge happened to come up
/// first. Containers sit on `192.168.64.x` and macOS VMs on `192.168.65.x`, so
/// one platform got a working cache and the other got `GOPROXY` pointing at a
/// private address that was not its gateway — which the egress filter then
/// blocked, correctly, and the build failed for a reason nothing named. Which
/// platform won was decided by boot order.
///
/// The environment knows its own gateway and the host does not, so the
/// environment resolves it — and proves the proxy answers there before
/// exporting anything, because a cache variable pointing at nothing is worse
/// than no cache variable at all.
enum CacheEndpoint {
    /// How long the guest waits for that proof before going direct.
    static let probeTimeout = 3

    /// Shell that exports the cache variables, or exports nothing.
    ///
    /// Written for `bash`, which both environments have: the Linux runner
    /// image is entered through `/bin/bash` and macOS ships it. `ip` is
    /// deliberately not used — it is absent from the runner image, and its
    /// absence was once read as "this container has no default route".
    /// - Parameters:
    ///   - cache: The cache configuration, or `nil` when caching is off.
    ///   - platform: Which environment the script will run in.
    /// - Returns: Shell to splice ahead of the runner, empty when there is
    ///   nothing to export.
    static func exportScript(cache: CacheConfig?, platform: JobPlatform) -> String {
        guard let cache, cache.enabled else { return "" }
        let exports = variableExports(cache: cache)
        guard !exports.isEmpty else { return "" }

        return """
            sapling_gateway=$(\(gatewayCommand(for: platform)))
            if [ -n "${sapling_gateway:-}" ] && curl -fsS -m \(probeTimeout) -o /dev/null \
            "http://${sapling_gateway}:\(cache.port)/\(CacheConfig.healthPath)"; then
              sapling_cache="http://${sapling_gateway}:\(cache.port)"
            \(exports.map { "  \($0)" }.joined(separator: "\n"))
            else
              echo "sapling: no package cache on this network; fetching directly"
            fi
            """
    }

    /// How each platform finds its own default gateway.
    ///
    /// Linux reads `/proc/net/route`, whose gateway column is little-endian
    /// hex — the fourth byte first. macOS asks `route`, which prints it.
    private static func gatewayCommand(for platform: JobPlatform) -> String {
        switch platform {
        case .linux:
            return """
                h=$(awk '$2=="00000000" {print $3; exit}' /proc/net/route); \
                [ -n "$h" ] && printf '%d.%d.%d.%d' \
                "0x${h:6:2}" "0x${h:4:2}" "0x${h:2:2}" "0x${h:0:2}"
                """
        case .macos:
            return "route -n get default 2>/dev/null | awk '/gateway:/ {print $2; exit}'"
        }
    }

    /// The exports each enabled proxy needs, in a stable order.
    private static func variableExports(cache: CacheConfig) -> [String] {
        var exports: [String] = []
        if cache.proxies.contains("go") {
            exports.append(#"export GOPROXY="${sapling_cache}/go,direct""#)
            exports.append(#"export GOSUMDB="sum.golang.org""#)
        }
        if cache.proxies.contains("cargo") {
            exports.append(#"export CARGO_REGISTRIES_CRATES_IO_PROTOCOL="sparse""#)
            exports.append(#"export SAPLING_CARGO_MIRROR="${sapling_cache}/cargo""#)
        }
        if cache.proxies.contains("npm") {
            exports.append(#"export NPM_CONFIG_REGISTRY="${sapling_cache}/npm""#)
        }
        if cache.proxies.contains("maven") {
            // Only the base address, deliberately. Gradle has no global mirror
            // setting — Maven's `settings.xml` mirrors have no equivalent — so
            // the alternative is an init script that clears the build's own
            // repository list and puts these in front of it. That reorders
            // dependency resolution from outside the project, breaks the
            // content filters `google()` is declared with, and fails the build
            // if anything about it is wrong.
            //
            // Exporting the address and letting the build opt in is a worse
            // cache and a much better trade: the repository declares which
            // repositories it trusts, and a node that is not Sapling simply
            // does not set this.
            exports.append(#"export SAPLING_MAVEN="${sapling_cache}/maven""#)
        }
        return exports
    }
}
