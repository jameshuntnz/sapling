import Foundation
import Testing

@testable import SaplingCore
@testable import SaplingInstall

extension EnvironmentDependentTests {
    @Suite("Paths")
    struct PathsTests {
        @Test("expands a leading tilde only")
        func tildeExpansion() {
            #expect(SaplingPaths.expandTilde("~/x") == NSHomeDirectory() + "/x")
            #expect(SaplingPaths.expandTilde("~") == NSHomeDirectory())
            #expect(SaplingPaths.expandTilde("/absolute/path") == "/absolute/path")
            // A tilde inside a path is a real character, not a home directory.
            #expect(SaplingPaths.expandTilde("/a/~/b") == "/a/~/b")
        }

        /// The home directory holds GitHub credentials, so it must not stay
        /// world-readable even if it already existed with looser permissions.
        @Test("creates the tree at 0700 and tightens an existing directory")
        func ensureHomeDirectory() async throws {
            try await TemporaryHome.run { home in
                try FileManager.default.createDirectory(
                    at: home,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o755]
                )
                try SaplingPaths.ensureHomeDirectory()

                let attributes = try FileManager.default.attributesOfItem(atPath: home.path)
                #expect(attributes[.posixPermissions] as? Int == 0o700)
                #expect(FileManager.default.fileExists(atPath: SaplingPaths.logsDirectory.path))
                #expect(FileManager.default.fileExists(atPath: SaplingPaths.stateDirectory.path))
                #expect(FileManager.default.fileExists(atPath: SaplingPaths.runnerCacheDirectory.path))
            }
        }

        @Test("SAPLING_HOME overrides the home directory")
        func honoursOverride() async throws {
            try await TemporaryHome.run { home in
                #expect(SaplingPaths.home.path == home.path)
                #expect(SaplingPaths.configFile.path == home.path + "/config.toml")
                #expect(SaplingPaths.databaseFile.path == home.path + "/sapling.db")
                #expect(SaplingPaths.sshKeyFile.path == home.path + "/vm_ed25519")
            }
        }

        /// The config holds a PAT or an App key path, so it is written 0600.
        @Test("writes the config file at 0600")
        func configPermissions() async throws {
            try await TemporaryHome.run { home in
                var config = SaplingConfig()
                config.github.repos = ["acme/widgets"]
                try config.save()

                let attributes = try FileManager.default.attributesOfItem(
                    atPath: SaplingPaths.configFile.path)
                #expect(attributes[.posixPermissions] as? Int == 0o600)
            }
        }
    }

    // MARK: - LaunchDaemon plist
}
