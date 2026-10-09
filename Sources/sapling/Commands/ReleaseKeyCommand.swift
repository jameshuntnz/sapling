import ArgumentParser
import Foundation
import SaplingCore

/// `sapling release-key` — make and use the key nodes check releases against.
///
/// Hidden: only the maintainer and the release workflow need it.
struct ReleaseKey: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "release-key",
        abstract: "Generate the release signing key, or sign a release's checksums.",
        shouldDisplay: false,
        subcommands: [Generate.self, Sign.self]
    )

    /// `sapling release-key generate` — write a new private key, print its public key.
    struct Generate: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Write a new private key to a file and print the public key for ReleaseSignature.")

        @Option(help: "Where to write the private key. Refuses to overwrite.")
        var out: String

        func run() throws {
            guard !FileManager.default.fileExists(atPath: out) else {
                fail("\(out) already exists")
            }
            let pair = ReleaseSignature.generateKeyPair()
            guard
                FileManager.default.createFile(
                    atPath: out, contents: Data(pair.privateKey.utf8), attributes: [.posixPermissions: 0o600])
            else {
                fail("could not write \(out)")
            }
            print(pair.publicKey)
        }
    }

    /// `sapling release-key sign` — sign `SHA256SUMS` for a tag.
    struct Sign: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract:
                "Print the signature of a SHA256SUMS file for a tag. The key is read from $\(keyVariable).")

        static let keyVariable = "SAPLING_RELEASE_SIGNING_KEY"

        @Option(help: "The release tag being published.")
        var tag: String

        @Argument(help: "The SHA256SUMS file.")
        var checksums: String

        func run() throws {
            guard let key = ProcessInfo.processInfo.environment[Self.keyVariable], !key.isEmpty else {
                fail("$\(Self.keyVariable) is not set")
            }
            let data = try Data(contentsOf: URL(fileURLWithPath: checksums))
            print(try ReleaseSignature.sign(checksums: data, tag: tag, privateKey: key))
        }
    }
}
