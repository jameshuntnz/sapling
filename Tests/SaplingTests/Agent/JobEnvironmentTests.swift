import Foundation
import Testing

@testable import SaplingAgent
@testable import SaplingCore
@testable import SaplingDB

@Suite("Job environment")
struct JobEnvironmentTests {
    @Test("injects no cache variables when caching is off")
    func cacheDisabled() async throws {
        var config = SaplingConfig()
        config.github.repos = ["acme/widgets"]
        config.github.auth = .pat
        config.github.token = "ghp_x"
        config.cache.enabled = false

        let agent = NodeAgent(config: config, store: try SaplingStore(inMemoryNamed: UUID().uuidString))
        #expect(await agent.jobEnvironment(for: .linux).isEmpty)
        #expect(await agent.jobEnvironment(for: .macos).isEmpty)
    }

    /// Without a VM bridge there is no address a job could reach the cache
    /// on, so pointing GOPROXY at one would break every build.
    @Test("injects nothing when there is no bridge to serve the cache on")
    func noBridgeMeansNoProxy() async throws {
        var config = SaplingConfig()
        config.github.repos = ["acme/widgets"]
        config.github.auth = .pat
        config.github.token = "ghp_x"
        config.cache.enabled = true

        let agent = NodeAgent(config: config, store: try SaplingStore(inMemoryNamed: UUID().uuidString))
        let environment = await agent.jobEnvironment(for: .linux)
        if let gateway = await agent.cacheGatewayHint() {
            #expect(environment["GOPROXY"]?.contains(gateway) == true)
        } else {
            #expect(environment.isEmpty)
        }
    }
}
