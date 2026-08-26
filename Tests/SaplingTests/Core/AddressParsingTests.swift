import Foundation
import Testing

@testable import SaplingCore

@Suite("Server endpoint resolution")
struct EndpointTests {
    @Test("normalises the shapes a person actually types")
    func normalisation() {
        #expect(ServerEndpoint.normalize("mini")?.absoluteString == "http://mini:8734")
        #expect(ServerEndpoint.normalize("mini:9000")?.absoluteString == "http://mini:9000")
        #expect(ServerEndpoint.normalize("https://mini:9000")?.absoluteString == "https://mini:9000")
        #expect(ServerEndpoint.normalize("  ") == nil)
    }
}
