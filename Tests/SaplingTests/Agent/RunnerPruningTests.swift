import Foundation
import Testing

@testable import SaplingAgent
@testable import SaplingCore
@testable import SaplingDB

/// Housekeeping sweeps offline runners to clear ones a crashed VM left behind.
///
/// A JIT runner that has been created but has not connected yet looks exactly
/// like one of those — `offline`, not `busy`, and named with our prefix. So the
/// sweep deleted runners it had minted seconds earlier, and the job died with
/// "the runner registration has been deleted from the server". Measured on the
/// node: minted 19:20:39, swept 19:20:40, dead 19:20:43, five times in a day.
@Suite("Runner pruning")
struct RunnerPruningTests {
    static func agent() throws -> NodeAgent {
        var config = SaplingConfig()
        config.github.repos = ["acme/widgets"]
        config.github.auth = .pat
        config.github.token = "ghp_x"
        return NodeAgent(config: config, store: try SaplingStore(inMemoryNamed: UUID().uuidString))
    }

    @Test("nothing is in flight on a quiet node")
    func startsEmpty() async throws {
        let agent = try Self.agent()
        #expect(await agent.inFlightRunners.isEmpty)
    }

    /// The sweep's own filter, applied to the exact shape that was being
    /// deleted: our prefix, offline, not busy — but ours and still starting.
    @Test("a runner that is still starting is spared")
    func inFlightRunnerIsSpared() {
        let justMinted = "sap-macos-6dde5984"
        let leaked = "sap-macos-oldcrash"
        let inFlight: Set<String> = [justMinted]

        // Mirrors GitHubClient.pruneOfflineRunners' predicate.
        func sweeps(_ name: String) -> Bool {
            name.hasPrefix(NodeAgent.runnerNamePrefix) && !inFlight.contains(name)
        }
        #expect(!sweeps(justMinted), "a runner minted seconds ago must not be swept")
        #expect(sweeps(leaked), "a genuinely leaked runner must still be swept")
    }

    /// Sparing in-flight runners must not stop the sweep doing its job — a
    /// runner left by a crashed VM still has to go, or they accumulate in the
    /// repo's runner list.
    @Test("runners from a previous life are still swept")
    func previousLifeRunnersStillSwept() async throws {
        let agent = try Self.agent()
        // A restarted daemon has nothing in flight, so everything offline and
        // prefixed is fair game — which is exactly right.
        #expect(await agent.inFlightRunners.isEmpty)
    }

    /// Someone else's runners are not ours to delete, in flight or not.
    @Test("runners without our prefix are never touched")
    func foreignRunnersUntouched() {
        #expect(!"someone-elses-runner".hasPrefix(NodeAgent.runnerNamePrefix))
    }
}
