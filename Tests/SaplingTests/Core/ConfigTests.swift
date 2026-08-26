import Foundation
import Testing

@testable import SaplingCore

@Suite("Configuration")
struct ConfigTests {
    @Test("round-trips through TOML")
    func roundTrip() throws {
        var config = SaplingConfig()
        config.node.name = "mac-mini-01"
        config.github.auth = .app
        config.github.appID = "123456"
        config.github.installationID = "7654321"
        config.github.privateKeyPath = "~/.sapling/app.pem"
        config.github.repos = ["acme/widgets", "acme/gizmos"]
        config.macos.maxConcurrent = 2
        config.cache.proxies = ["go", "cargo"]

        let directory = try TemporaryDirectory()
        let url = directory.appending("config.toml")
        try config.save(to: url)
        let loaded = try SaplingConfig.load(from: url)

        #expect(loaded.node.name == "mac-mini-01")
        #expect(loaded.github.auth == .app)
        #expect(loaded.github.repos == ["acme/widgets", "acme/gizmos"])
        #expect(loaded.cache.proxies == ["go", "cargo"])
    }

    /// A partial config is the normal case — `sapling install` writes only
    /// what it knows, and everything else has to fall back to a default
    /// rather than failing to parse.
    @Test("fills in defaults for absent sections")
    func partialConfig() throws {
        let toml = """
            [github]
            auth = "pat"
            token = "ghp_example"
            repos = ["acme/widgets"]
            """
        let config = try ConfigFixture.decode(toml)
        #expect(config.github.repos == ["acme/widgets"])
        #expect(config.server.port == 8734)
        #expect(config.macos.effectiveMaxConcurrent == 2)
        #expect(config.network.blockPrivateRanges)
    }

    /// Apple allows two concurrent macOS VMs.
    ///
    /// The config value is advisory; the effective value is the one the scheduler
    /// must use.
    @Test("clamps macOS concurrency to Apple's limit")
    func clampsMacOSConcurrency() {
        var config = SaplingConfig()
        config.macos.maxConcurrent = 8
        #expect(config.macos.effectiveMaxConcurrent == 2)
        #expect(config.warnings().contains { $0.contains("clamped") })

        config.macos.enabled = false
        #expect(config.macos.effectiveMaxConcurrent == 0)
    }

    @Test("rejects configs the daemon can't run with")
    func validation() {
        var config = SaplingConfig()
        #expect(throws: ConfigError.self) { try config.validate() }

        config.github.repos = ["not-a-repo"]
        config.github.auth = .pat
        config.github.token = "ghp_example"
        #expect(throws: ConfigError.self) { try config.validate() }

        config.github.repos = ["acme/widgets"]
        #expect(throws: Never.self) { try config.validate() }
    }

    @Test("warns when the API is bound wider than Tailscale")
    func bindWarning() {
        var config = SaplingConfig()
        config.server.bind = "0.0.0.0"
        #expect(config.server.bindMode == .all)
        #expect(config.warnings().contains { $0.contains("Tailscale") })
    }
}

@Suite("Job subnets")
struct JobSubnetConfigTests {
    /// vmnet allocates 192.168.64.0/24 upward as networks come up, and which
    /// provider lands on which is not fixed, so the default spans the range.
    @Test("defaults to vmnet's allocation range")
    func defaultSubnet() {
        let subnets = NetworkConfig().jobSubnets
        #expect(subnets.first == "192.168.64.0/24")
        #expect(subnets.contains("192.168.65.0/24"), "Tart and container land on different subnets")
        #expect(subnets.count == 8)
    }

    @Test("survives a TOML round trip")
    func roundTrip() throws {
        var config = SaplingConfig()
        config.github.repos = ["acme/widgets"]
        config.network.jobSubnets = ["192.168.64.0/24", "192.168.65.0/24"]

        let directory = try TemporaryDirectory()
        let url = directory.appending("config.toml")
        try config.save(to: url)

        let loaded = try SaplingConfig.load(from: url)
        #expect(loaded.network.jobSubnets == ["192.168.64.0/24", "192.168.65.0/24"])
    }

    /// A config written before this field existed must still load.
    @Test("older configs without the field get the default")
    func absentFieldDefaults() throws {
        let config = try ConfigFixture.decode(
            """
            [github]
            auth = "pat"
            token = "ghp_example"
            repos = ["acme/widgets"]

            [network]
            block_private_ranges = true
            """)
        #expect(config.network.jobSubnets == NetworkConfig.defaultJobSubnets)
    }
}
