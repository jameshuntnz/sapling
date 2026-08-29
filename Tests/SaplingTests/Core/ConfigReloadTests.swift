import Foundation
import Testing

@testable import SaplingCore

/// What a running daemon may and may not pick up from an edited config file.
///
/// The pair that matters here is `ConfigReload.reloadableKeys` and
/// `ConfigReload.merge` — the list says what is safe to change live, the merge
/// does the changing, and a field in one and not the other is either an edit
/// that silently does nothing or a field swapped under code that captured it
/// at startup. `mergeMatchesTheReloadableList` is what holds them together.
@Suite("Config reload")
struct ConfigReloadTests {
    /// A config with every reloadable field moved off its default, plus a few
    /// that are deliberately not reloadable.
    func edited() -> SaplingConfig {
        var config = SaplingConfig()

        config.github.repos = ["acme/one", "acme/two"]
        config.github.pollIntervalSeconds = 90
        config.github.cancelRunWhenExhausted = true
        config.github.allowPublicRepos = true

        config.node.maxConcurrent = 3
        config.node.memoryReserveGB = 8
        config.node.memoryBudgetOverrideGB = 48
        config.node.serializePlatforms = true

        config.macos.maxConcurrent = 1
        config.macos.labels = ["self-hosted", "macos"]
        config.macos.memoryGB = 12
        config.macos.maxMemoryGB = 24
        config.macos.jobTimeoutSeconds = 600

        config.linux.maxConcurrent = 4
        config.linux.labels = ["self-hosted", "linux"]
        config.linux.memoryGB = 6
        config.linux.maxMemoryGB = 16
        config.linux.jobTimeoutSeconds = 900
        config.linux.defaultImage = "ghcr.io/acme/runner:2"

        config.update.repository = "acme/sapling"
        config.update.channel = .dev
        config.update.checkIntervalHours = 12
        config.update.autoApply = true

        // Consumed once at startup, so a reload must report these rather than
        // apply them.
        config.node.name = "other"
        config.server.port = 9001
        config.github.token = "ghp_rotated"
        config.macos.baseImage = "other-base"
        config.network.blockPrivateRanges = false
        config.cache.port = 9002

        return config
    }

    @Test("flattens a config into the keys the TOML file actually uses")
    func flattening() throws {
        var config = SaplingConfig()
        config.github.pollIntervalSeconds = 45
        config.linux.labels = ["self-hosted", "linux"]
        let flat = try ConfigReload.flatten(config)

        #expect(flat["github.poll_interval_seconds"] == "45")
        #expect(flat["linux.labels"] == "[self-hosted, linux]")
        #expect(flat["macos.enabled"] == "true")
        // Absent from the config, so absent here — which is what makes
        // "unset → 8" show up as a change rather than as nothing.
        #expect(flat["macos.memory_gb"] == nil)
    }

    @Test("splits changes into what a reload applies and what needs a restart")
    func splitsChanges() throws {
        let (live, restartRequired) = try ConfigReload.diff(running: SaplingConfig(), incoming: edited())
        let liveKeys = Set(live.map(\.key))
        let restartKeys = Set(restartRequired.map(\.key))

        #expect(liveKeys.contains("github.repos"))
        #expect(liveKeys.contains("linux.max_concurrent"))
        #expect(restartKeys.contains("server.port"))
        #expect(restartKeys.contains("network.block_private_ranges"))
        #expect(restartKeys.contains("node.name"))
        #expect(liveKeys.isDisjoint(with: restartKeys))
    }

    @Test("reports no change when the file matches what is running")
    func identicalConfigs() throws {
        let (live, restartRequired) = try ConfigReload.diff(
            running: edited(), incoming: edited())
        #expect(live.isEmpty)
        #expect(restartRequired.isEmpty)
    }

    /// Clearing a field is an edit, and one worth seeing: dropping
    /// `macos.memory_gb` changes what every unsized job on the node gets.
    @Test("counts a field that appears or disappears as a change")
    func presenceIsAChange() throws {
        var sized = SaplingConfig()
        sized.macos.memoryGB = 12
        let added = try ConfigReload.diff(running: SaplingConfig(), incoming: sized)
        #expect(added.live.contains(ConfigChange(key: "macos.memory_gb", from: "(unset)", to: "12")))

        let removed = try ConfigReload.diff(running: sized, incoming: SaplingConfig())
        #expect(removed.live.contains(ConfigChange(key: "macos.memory_gb", from: "12", to: "(unset)")))
    }

    /// The test that keeps the policy honest.
    ///
    /// Every key the list claims is reloadable must actually cross over in
    /// `merge`, and nothing else may.
    @Test("merge applies exactly the reloadable keys")
    func mergeMatchesTheReloadableList() throws {
        let running = SaplingConfig()
        let merged = ConfigReload.merge(running: running, incoming: edited())
        let (live, restartRequired) = try ConfigReload.diff(running: running, incoming: merged)

        #expect(Set(live.map(\.key)) == ConfigReload.reloadableKeys)
        #expect(restartRequired.isEmpty)
        #expect(merged.server.port == running.server.port)
        #expect(merged.node.name == running.node.name)
        #expect(merged.macos.baseImage == running.macos.baseImage)
        #expect(merged.network.blockPrivateRanges == running.network.blockPrivateRanges)
    }

    /// The API has no auth (§8), so a credential must not be reachable through
    /// it even to a caller already inside the tailnet.
    @Test("never renders a credential, in a listing or in a diff")
    func redactsSecrets() throws {
        var running = SaplingConfig()
        running.github.token = "ghp_original"
        running.macos.sshPassword = "hunter2"

        let entries = try ConfigReload.entries(of: running)
        let rendered = entries.map(\.value).joined(separator: " ")
        #expect(!rendered.contains("ghp_original"))
        #expect(!rendered.contains("hunter2"))
        #expect(entries.contains(ConfigEntry(key: "github.token", value: "(set)", reloadable: false)))

        var rotated = running
        rotated.github.token = "ghp_rotated"
        let (_, restartRequired) = try ConfigReload.diff(running: running, incoming: rotated)
        let change = restartRequired.first { $0.key == "github.token" }
        #expect(change?.to == "(set, changed)")
        #expect(!(change?.to.contains("ghp") ?? true))
    }

    @Test("lists fields in section order, marking the ones a reload applies")
    func entryOrderAndMarking() throws {
        let entries = try ConfigReload.entries(of: SaplingConfig())
        let sections = entries.map { String($0.key.split(separator: ".").first ?? "") }
        #expect(sections.first == "node")
        #expect(sections.firstIndex(of: "github") ?? 0 < sections.firstIndex(of: "macos") ?? 0)
        #expect(entries.first { $0.key == "github.poll_interval_seconds" }?.reloadable == true)
        #expect(entries.first { $0.key == "server.port" }?.reloadable == false)
    }
}
