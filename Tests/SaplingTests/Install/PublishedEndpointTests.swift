import Foundation
import Testing

@testable import SaplingCore
@testable import SaplingInstall

extension EnvironmentDependentTests {
    /// Nested under the serialized parent because these read `SAPLING_HOME`,
    /// which is process-wide — a sibling suite clearing it mid-test is exactly
    /// the flake this arrangement exists to prevent.
    @Suite("Published endpoint")
    struct PublishedEndpointTests {
        /// With `bind = "tailscale"` the daemon listens on an address only it
        /// can resolve, so it publishes that address for local clients.
        ///
        /// The address is the first in Tailscale's 100.64.0.0/10 range rather
        /// than any node's real one: nothing here resolves it, and a real
        /// address in a public repository is a detail about someone's tailnet
        /// that the test does not need.
        @Test("prefers the address the local daemon published")
        func prefersPublishedEndpoint() async throws {
            try await TemporaryHome.run { home in
                try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
                try "http://100.64.0.1:8734".write(
                    to: SaplingPaths.endpointFile, atomically: true, encoding: .utf8)

                #expect(ServerEndpoint.resolve().absoluteString == "http://100.64.0.1:8734")

                // An explicit address still outranks it.
                #expect(
                    ServerEndpoint.resolve(explicit: "other-host:9000").absoluteString
                        == "http://other-host:9000")
            }
        }

        @Test("falls back to loopback when nothing is published")
        func loopbackFallback() async throws {
            try await TemporaryHome.run { _ in
                #expect(ServerEndpoint.resolve().absoluteString == "http://127.0.0.1:8734")
            }
        }
    }
}
