import Foundation
import Testing

@testable import SaplingAgent
@testable import SaplingCore
@testable import SaplingDB

/// One platform at a time, because the concurrency being given up is not
/// concurrency this node has.
///
/// Measured three times: a VM and a container start together, the VM never
/// gets a bridge, times out after five minutes, and its teardown destroys the
/// container's bridge — killing that job. The macOS job is requeued, runs
/// alone, and boots in eight seconds. The node already serialises; it just
/// does it by destroying a job first.
@Suite("Platform serialisation")
struct SerializationTests {
    static func agent(serialize: Bool) throws -> NodeAgent {
        var config = SaplingConfig()
        config.github.repos = ["acme/widgets"]
        config.github.auth = .pat
        config.github.token = "ghp_x"
        config.node.serializePlatforms = serialize
        return NodeAgent(config: config, store: try SaplingStore(inMemoryNamed: UUID().uuidString))
    }

    /// Off, and it should stay off.
    ///
    /// Measured on a rebooted node, a container and a VM started in the same
    /// instant both attach within three seconds, three times out of three.
    /// Serialising traded half the node's throughput for a fault it does not
    /// prevent.
    @Test("both platforms run together by default")
    func defaultsOff() {
        #expect(!NodeConfig().serializePlatforms)
        #expect(!SaplingConfig().node.serializePlatforms)
    }

    @Test("a busy platform holds the other one back")
    func otherPlatformBlocks() async throws {
        let agent = try Self.agent(serialize: true)
        #expect(await agent.blockedByOtherPlatform(.macos, inUse: [.linux: 1]))
        #expect(await agent.blockedByOtherPlatform(.linux, inUse: [.macos: 1]))
    }

    /// Serialising is across platforms, not within one: the per-platform slot
    /// count still decides how many of the same kind run together.
    @Test("a platform does not block itself")
    func samePlatformDoesNotBlock() async throws {
        let agent = try Self.agent(serialize: true)
        #expect(await !agent.blockedByOtherPlatform(.macos, inUse: [.macos: 1]))
        #expect(await !agent.blockedByOtherPlatform(.linux, inUse: [:]))
        #expect(await !agent.blockedByOtherPlatform(.linux, inUse: [.macos: 0]))
    }

    @Test("turning it off restores the old behaviour exactly")
    func canBeDisabled() async throws {
        let agent = try Self.agent(serialize: false)
        #expect(await !agent.blockedByOtherPlatform(.macos, inUse: [.linux: 1]))
        #expect(await !agent.blockedByOtherPlatform(.linux, inUse: [.macos: 2]))
    }

    /// `sapling install` writes every field to config.toml, so the flag has to
    /// survive a save and a load, and a file written before it existed has to
    /// load as the default rather than as anything surprising.
    @Test("the setting survives a save, and an older config defaults to off")
    func roundTrips() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("config.toml")

        var config = SaplingConfig()
        config.github.repos = ["acme/widgets"]
        config.github.auth = .pat
        config.github.token = "ghp_x"
        config.node.serializePlatforms = false
        try config.save(to: file)
        #expect(try !SaplingConfig.load(from: file).node.serializePlatforms)

        let older = try String(contentsOf: file, encoding: .utf8)
            .split(separator: "\n")
            .filter { !$0.contains("serialize_platforms") }
            .joined(separator: "\n")
        try older.write(to: file, atomically: true, encoding: .utf8)
        #expect(try !SaplingConfig.load(from: file).node.serializePlatforms)
    }
}
