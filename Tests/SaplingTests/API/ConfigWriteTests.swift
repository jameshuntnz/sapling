import Foundation
import Testing

@testable import SaplingAPI
@testable import SaplingAgent
@testable import SaplingCore
@testable import SaplingDB

/// `PUT /api/v1/config`: write a few keys, keep the file's comments, reload.
@Suite("Config write")
struct ConfigWriteTests {
    static let file = """
        [node]
        name = "mini"

        [github]
        auth = "pat"
        token = "ghp_example"
        repos = ["acme/widgets"]

        [macos]
        enabled = false

        [linux]
        max_concurrent = 2  # two Android builds swap
        """

    func withControlPlane<T>(_ body: (ControlPlane, URL) async throws -> T) async throws -> T {
        let directory = try TemporaryDirectory()
        let url = directory.appending("config.toml")
        try Self.file.write(to: url, atomically: true, encoding: .utf8)
        let config = try SaplingConfig.load(from: url)
        let store = try SaplingStore(inMemoryNamed: UUID().uuidString)
        let agent = NodeAgent(config: config, store: store, configURL: url)
        return try await body(ControlPlane(store: store, config: config, agent: agent), url)
    }

    @Test("writes the key, keeps its comment, and the running config follows")
    func writesAndReloads() async throws {
        try await withControlPlane { controlPlane, url in
            let result = await controlPlane.updateConfig(.init(values: ["linux.max_concurrent": "3"]))
            #expect(result.error == nil)
            #expect(result.applied.map(\.key) == ["linux.max_concurrent"])
            let text = try String(contentsOf: url, encoding: .utf8)
            #expect(text.contains("max_concurrent = 3  # two Android builds swap"))
            #expect(await controlPlane.effectiveConfig().linux.maxConcurrent == 3)

            let backups = try FileManager.default.contentsOfDirectory(
                atPath: url.deletingLastPathComponent().path
            ).filter { $0.hasPrefix("config.toml.bak-api-") }
            #expect(backups.count == 1)
        }
    }

    @Test("a value of the wrong type is refused and nothing is written")
    func refusesBadValue() async throws {
        try await withControlPlane { controlPlane, url in
            let result = await controlPlane.updateConfig(.init(values: ["linux.max_concurrent": "lots"]))
            #expect(result.error != nil)
            let text = try String(contentsOf: url, encoding: .utf8)
            #expect(text == Self.file)
        }
    }

    @Test("trust settings and credentials are not editable over the API")
    func refusesProtectedKeys() async throws {
        try await withControlPlane { controlPlane, url in
            for key in [
                "update.repository", "github.allow_public_repos", "build_cache.enabled", "github.token",
                "server.port", "linux.default_image",
            ] {
                let result = await controlPlane.updateConfig(.init(values: [key: "x"]))
                #expect(result.error?.contains("not editable") == true, "\(key) must be refused")
            }
            let text = try String(contentsOf: url, encoding: .utf8)
            #expect(text == Self.file)
        }
    }

    @Test("repositories can be removed over the API but not added, nor all removed")
    func reposOnlyShrink() async throws {
        try await withControlPlane { controlPlane, url in
            let two = Self.file.replacingOccurrences(
                of: #"repos = ["acme/widgets"]"#, with: #"repos = ["acme/widgets", "acme/gizmos"]"#)
            try two.write(to: url, atomically: true, encoding: .utf8)
            for widening in ["[acme/widgets, mallory/anything]", "[]"] {
                let result = await controlPlane.updateConfig(.init(values: ["github.repos": widening]))
                #expect(result.error?.contains("only be removed") == true, "\(widening) must be refused")
            }
            let text = try String(contentsOf: url, encoding: .utf8)
            #expect(text == two)

            let removed = await controlPlane.updateConfig(.init(values: ["github.repos": "[acme/gizmos]"]))
            #expect(removed.error == nil)
        }
    }

    /// The backstop behind the editor: whatever text it produces, only the
    /// keys asked for may load differently.
    @Test("an edit that changes keys it was not asked to is refused")
    func editsStayInTheirLane() throws {
        var before = SaplingConfig()
        before.github.repos = ["acme/widgets"]
        var after = before
        after.linux.maxConcurrent = 9
        after.linux.buildImages.toggle()
        let refusal = try ControlPlane.refusal(
            of: .init(values: ["linux.max_concurrent": "9"]), before: before, after: after)
        #expect(refusal?.contains("linux.build_images") == true)
    }
}
