import Foundation
import Testing

@testable import SaplingCore

@Suite("Client error handling")
struct ClientErrorTests {
    /// The menu bar app shows this text verbatim when it can't reach the
    /// node, so it has to name the address it tried.
    @Test("explains an unreachable daemon")
    func unreachableDaemon() async {
        let client = SaplingClient(baseURL: URL(string: "http://127.0.0.1:19999")!, timeout: 2)
        do {
            _ = try await client.status()
            Issue.record("expected a connection failure")
        } catch let error as ClientError {
            #expect(error.statusCode == nil)
            #expect(error.message.contains("could not reach"))
            #expect(error.message.contains("19999"))
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
    }
}
