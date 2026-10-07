import Foundation
import Testing

@testable import SaplingAgent
@testable import SaplingCore
@testable import SaplingDB

/// The API has no auth, so the cleanup endpoint must refuse what matters
/// before it ever asks Tart — deleting the base image costs an hour's rebuild.
@Suite("Disk cleanup")
struct DiskCleanupTests {
    func agent() throws -> NodeAgent {
        var config = SaplingConfig()
        config.macos.baseImage = "sapling-macos-base"
        return NodeAgent(config: config, store: try SaplingStore(inMemoryNamed: UUID().uuidString))
    }

    @Test("refuses the base image and job clones, whatever the request says")
    func refusesManagedVMs() async throws {
        let agent = try agent()
        for target in ["sapling-macos-base", TartProvider.vmPrefix + "sap-macos-1234", ""] {
            let result = await agent.cleanDisk(.init(action: .deleteVM, target: target))
            #expect(result.error != nil, "\(target) must be refused")
        }
    }

    @Test("refuses to reset the image builder while a Linux job is running")
    func refusesBuilderResetDuringLinuxJob() async throws {
        let store = try SaplingStore(inMemoryNamed: UUID().uuidString)
        try await store.saveJob(
            Job(id: "1", repo: "acme/widgets", platform: .linux, labels: [], status: .running))
        let agent = NodeAgent(config: SaplingConfig(), store: store)
        let result = await agent.cleanDisk(.init(action: .resetBuilder))
        #expect(result.error?.contains("Linux job") == true)
    }
}
