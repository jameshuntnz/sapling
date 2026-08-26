import ArgumentParser
import Foundation
import SaplingCore

struct Nodes: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "List nodes.",
        subcommands: [JoinToken.self]
    )

    @OptionGroup var options: ServerOptions

    func run() async throws {
        let nodes: [Node]
        do {
            nodes = try await options.client().nodes()
        } catch {
            fail(error.localizedDescription)
        }
        let rows = nodes.map {
            [$0.name, $0.id, $0.platform, Style.status($0.status), Format.relative($0.lastSeenAt)]
        }
        print(Format.table(headers: ["NAME", "ID", "PLATFORM", "STATUS", "LAST SEEN"], rows: rows))
    }
}

struct JoinToken: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "join-token",
        abstract: "Generate a single-use token for enrolling another Mac node."
    )

    @OptionGroup var options: ServerOptions

    func run() async throws {
        let token: JoinTokenResponse
        do {
            token = try await options.client().joinToken()
        } catch {
            fail(error.localizedDescription)
        }
        print(
            "Run this on the new node (expires \(Format.relative(token.expiresAt).replacingOccurrences(of: " ago", with: " from now"))):"
        )
        print("")
        print("  sapling join --control-plane=\(token.controlPlaneURL) --token=\(token.token)")
        print("")
        print(
            Style.dim("Note: `sapling join` is deferred until there is a second node to test against (§11)."))
    }
}
