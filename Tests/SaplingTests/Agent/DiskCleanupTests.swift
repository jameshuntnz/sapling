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
}
