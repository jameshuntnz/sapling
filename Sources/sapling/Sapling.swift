import ArgumentParser
import Foundation
import SaplingCore

@main
struct Sapling: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "sapling",
        abstract: "Self-hosted GitHub Actions orchestration for Apple Silicon.",
        version: SaplingVersion.current,
        subcommands: [
            Serve.self,
            Install.self,
            Doctor.self,
            Upgrade.self,
            Uninstall.self,
            Status.self,
            Jobs.self,
            Nodes.self,
            Drain.self,
            Cordon.self,
            Uncordon.self,
            Join.self,
            Demo.self,
        ],
        defaultSubcommand: Status.self
    )
}

/// Shared connection flag for every command that talks to the API.
struct ServerOptions: ParsableArguments {
    @Option(
        name: [.customLong("server"), .customShort("s")],
        help:
            "Control plane URL or host[:port]. Defaults to $SAPLING_SERVER, then ~/.sapling/client.toml, then the local daemon."
    )
    var server: String?

    func client() -> SaplingClient {
        SaplingClient(baseURL: ServerEndpoint.resolve(explicit: server))
    }
}

/// Report a failure the way a CLI should: a plain message on stderr and a
/// non-zero exit, not a Swift error dump.
func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    Foundation.exit(1)
}
