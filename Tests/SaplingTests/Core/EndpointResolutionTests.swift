import Foundation
import Testing

@testable import SaplingCore

@Suite("Endpoint resolution order", .serialized)
struct EndpointResolutionTests {
    /// Documented contract: flag, then environment, then saved client config,
    /// then the local daemon's own config, then loopback.
    @Test("an explicit address beats the environment")
    func explicitWins() {
        setenv("SAPLING_SERVER", "from-env:1111", 1)
        defer { unsetenv("SAPLING_SERVER") }
        #expect(
            ServerEndpoint.resolve(explicit: "explicit-host:2222").absoluteString
                == "http://explicit-host:2222")
    }

    @Test("the environment is used when no flag is given")
    func environmentIsNext() {
        setenv("SAPLING_SERVER", "from-env:1111", 1)
        defer { unsetenv("SAPLING_SERVER") }
        #expect(ServerEndpoint.resolve().absoluteString == "http://from-env:1111")
    }

    @Test("an empty flag falls through instead of producing a broken URL")
    func emptyFlagFallsThrough() {
        setenv("SAPLING_SERVER", "from-env:1111", 1)
        defer { unsetenv("SAPLING_SERVER") }
        #expect(ServerEndpoint.resolve(explicit: "   ").absoluteString == "http://from-env:1111")
    }

    /// `restart` acts on this Mac through launchd, so it must not read the
    /// job count of whatever node `client.toml` or the environment points at —
    /// a workstation configured for the node would restart the workstation on
    /// the strength of the node looking idle.
    @Test("the local endpoint ignores the environment and the client config")
    func localIgnoresRemoteOverrides() async throws {
        try await TemporaryHome.run { home in
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            try "http://127.0.0.1:9999".write(
                to: SaplingPaths.endpointFile, atomically: true, encoding: .utf8)
            try ClientConfig(server: "mac-mini-01:8734").save(to: SaplingPaths.clientConfigFile)
            setenv("SAPLING_SERVER", "from-env:1111", 1)
            defer { unsetenv("SAPLING_SERVER") }

            #expect(ServerEndpoint.local.absoluteString == "http://127.0.0.1:9999")
            #expect(ServerEndpoint.resolve().absoluteString == "http://from-env:1111")
        }
    }

    /// Nothing published and nothing configured is a machine where the daemon
    /// has never run, and loopback is the right guess there.
    @Test("the local endpoint falls back to loopback")
    func localFallsBackToLoopback() async throws {
        try await TemporaryHome.run { _ in
            #expect(ServerEndpoint.local == ServerEndpoint.loopback)
        }
    }

    @Test("client config round-trips through TOML")
    func clientConfigRoundTrip() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = directory.appendingPathComponent("client.toml")
        try ClientConfig(server: "mac-mini-01:8734").save(to: url)
        #expect(ClientConfig.load(from: url).server == "mac-mini-01:8734")

        // A missing file is normal, not an error.
        #expect(ClientConfig.load(from: directory.appendingPathComponent("absent.toml")).server == nil)
    }
}
