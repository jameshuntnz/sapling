import Foundation
import TOMLKit
import Testing

@testable import SaplingAgent
@testable import SaplingCore
@testable import SaplingDB

/// RAM is shared between the platforms and the per-platform counts cannot say so.
///
/// Two macOS slots and two Linux slots describe what each platform may run;
/// nothing in them stops four environments starting at once and over-committing
/// a machine that comfortably fits any two. `node.max_concurrent` is the total.
@Suite("Node-wide concurrency")
struct NodeCapacityTests {
    func makeAgent(_ mutate: (inout SaplingConfig) -> Void = { _ in }) throws -> NodeAgent {
        var config = SaplingConfig()
        config.github.repos = ["acme/widgets"]
        config.github.auth = .pat
        config.github.token = "ghp_example"
        mutate(&config)
        return NodeAgent(config: config, store: try SaplingStore(inMemoryNamed: UUID().uuidString))
    }

    /// The node this was built for: any mix, never more than two.
    @Test("two slots, shared between the platforms")
    func sharedPool() async throws {
        let agent = try makeAgent {
            $0.macos.maxConcurrent = 2
            $0.linux.maxConcurrent = 2
            $0.node.maxConcurrent = 2
        }
        // Each platform can still fill both slots on its own...
        #expect(await agent.capacity(for: .macos) == 2)
        #expect(await agent.capacity(for: .linux) == 2)
        // ...but the machine runs two jobs, not four.
        #expect(await agent.nodeCapacity == 2)
    }

    /// Absent, the node behaves exactly as it did before the cap existed.
    @Test("no cap leaves the per-platform counts in charge")
    func uncapped() async throws {
        let agent = try makeAgent {
            $0.macos.maxConcurrent = 2
            $0.linux.maxConcurrent = 2
        }
        #expect(await agent.nodeCapacity == 4)
    }

    /// A cap above what the platforms offer must not invent slots.
    @Test("the cap is a ceiling, never a floor")
    func neverInventsSlots() async throws {
        let agent = try makeAgent {
            $0.macos.maxConcurrent = 1
            $0.linux.maxConcurrent = 1
            $0.node.maxConcurrent = 8
        }
        #expect(await agent.nodeCapacity == 2)
    }

    /// A disabled platform contributes nothing, so the cap tracks what is left.
    @Test("a disabled platform shrinks the pool")
    func disabledPlatform() async throws {
        let agent = try makeAgent {
            $0.macos.enabled = false
            $0.linux.maxConcurrent = 2
            $0.node.maxConcurrent = 2
        }
        #expect(await agent.nodeCapacity == 2)
        #expect(await agent.capacity(for: .macos) == 0)
    }

    @Test("zero stops the node accepting anything")
    func zeroCap() async throws {
        let agent = try makeAgent { $0.node.maxConcurrent = 0 }
        #expect(await agent.nodeCapacity == 0)
    }

    /// An older config file has no `[node] max_concurrent`, and must stay uncapped.
    @Test("an older config decodes as uncapped")
    func decodesAbsentAsUncapped() throws {
        let old = try TOMLDecoder().decode(
            SaplingConfig.self, from: "[node]\nname = 'mini'\n")
        #expect(old.node.maxConcurrent == nil)
        #expect(old.node.effectiveMaxConcurrent(macOS: 2, linux: 2) == 4)

        let capped = try TOMLDecoder().decode(
            SaplingConfig.self, from: "[node]\nname = 'mini'\nmax_concurrent = 2\n")
        #expect(capped.node.maxConcurrent == 2)
        #expect(capped.node.effectiveMaxConcurrent(macOS: 2, linux: 2) == 2)
    }
}
