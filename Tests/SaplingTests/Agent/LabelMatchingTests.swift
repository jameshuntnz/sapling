import Foundation
import Testing

@testable import SaplingAgent
@testable import SaplingCore
@testable import SaplingDB

@Suite("Label matching")
struct LabelMatchingTests {
    func makeAgent(_ mutate: (inout SaplingConfig) -> Void = { _ in }) throws -> NodeAgent {
        var config = SaplingConfig()
        config.github.repos = ["acme/widgets"]
        config.github.auth = .pat
        config.github.token = "ghp_example"
        mutate(&config)
        return NodeAgent(config: config, store: try SaplingStore(inMemoryNamed: UUID().uuidString))
    }

    /// Mirrors GitHub's rule: a runner is eligible when its labels are a
    /// superset of the job's.
    @Test("matches a job whose labels this node covers")
    func supersetMatching() async throws {
        let agent = try makeAgent()
        #expect(await agent.platform(matching: ["self-hosted", "macos"]) == .macos)
        #expect(await agent.platform(matching: ["self-hosted"]) == .macos)
        #expect(await agent.platform(matching: ["self-hosted", "linux", "arm64"]) == .linux)
    }

    @Test("declines jobs asking for labels this node doesn't have")
    func rejectsUnknownLabels() async throws {
        let agent = try makeAgent()
        #expect(await agent.platform(matching: ["ubuntu-latest"]) == nil)
        #expect(await agent.platform(matching: ["self-hosted", "macos", "xcode-16"]) == nil)
        #expect(await agent.platform(matching: ["self-hosted", "windows"]) == nil)
    }

    @Test("won't route to a disabled platform")
    func respectsDisabledPlatforms() async throws {
        let agent = try makeAgent { $0.macos.enabled = false }
        #expect(await agent.platform(matching: ["self-hosted", "macos"]) == nil)
        #expect(await agent.platform(matching: ["self-hosted", "linux"]) == .linux)
    }

    @Test("capacity honours Apple's macOS VM limit")
    func capacity() async throws {
        let agent = try makeAgent {
            $0.macos.maxConcurrent = 5
            $0.linux.maxConcurrent = 4
        }
        #expect(await agent.capacity(for: .macos) == 2)
        #expect(await agent.capacity(for: .linux) == 4)
    }

    @Test("derives a stable node id from the name")
    func nodeID() {
        #expect(NodeAgent.stableNodeID(name: "Mac Mini 01") == "mac-mini-01")
        #expect(NodeAgent.stableNodeID(name: "!!!") == "node")
    }
}
