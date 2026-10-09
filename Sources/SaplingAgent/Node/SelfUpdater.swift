import CryptoKit
import Foundation
import SaplingCore

/// Replaces the running daemon with a newer release.
///
/// This exists so updating a node needs no `sudo`. The daemon already runs as
/// root, so it can replace its own binary and restart itself; asking a person
/// to do it means a password prompt for every deploy, which during the first
/// bring-up meant roughly ten of them.
///
/// **What this trusts.** The daemon downloads a binary and executes it as
/// root, so the download is the security boundary. The archive is checked
/// against `SHA256SUMS`, and `SHA256SUMS` against an Ed25519 signature over it
/// and the tag, made by a key only the release workflow holds and checked
/// against keys built into this binary (`ReleaseSignature`). A release missing
/// either is refused, so publishing to the repository is not enough to put a
/// binary on a node.
public struct SelfUpdater: Sendable {
    let config: SaplingConfig
    let client: ReleaseClient

    /// Creates an updater for the given configuration.
    public init(config: SaplingConfig) {
        self.config = config
        self.client = ReleaseClient(config: config)
    }

    /// Why an update could not be applied.
    public enum UpdateError: Error, LocalizedError, Sendable {
        case notRoot
        case checksumMismatch(expected: String, actual: String)
        case checksumMissing(String)
        case unpackFailed(String)
        case notAnExecutable
        case restartFailed(String)

        /// A message naming what went wrong and, where there is one, the fix.
        public var errorDescription: String? {
            switch self {
            case .notRoot:
                "updating needs root; the daemon has it, a CLI run by hand does not"
            case .checksumMismatch(let expected, let actual):
                "checksum mismatch: expected \(expected), got \(actual)"
            case .checksumMissing(let name):
                "the release's SHA256SUMS does not list \(name)"
            case .unpackFailed(let detail):
                "could not unpack the release: \(detail)"
            case .notAnExecutable:
                "the downloaded archive contains no runnable sapling binary"
            case .restartFailed(let detail):
                "installed, but the restart failed (\(detail)); the next restart runs it"
            }
        }
    }

    /// Look for a newer version on the configured channel.
    ///
    /// - Returns: The update available, or `nil` when this node is current.
    /// - Throws: If the releases cannot be read.
    public func check() async throws -> AvailableUpdate? {
        guard let current = SemanticVersion(SaplingVersion.current) else { return nil }
        return try await client.latestUpdate(newerThan: current)
    }

    /// The newest release on the channel, whether or not it is newer than
    /// what is running.
    ///
    /// - Returns: The release to install, or `nil` if the channel has none.
    /// - Throws: If the releases cannot be read.
    public func newestRelease() async throws -> AvailableUpdate? {
        try await client.latestUpdate(newerThan: nil)
    }

    /// Download, verify and unpack a release, ready to install.
    ///
    /// Separate from installing so a busy node can fetch and check the
    /// release now, while someone is watching, and install it once its jobs
    /// have finished.
    ///
    /// - Parameter update: The version to fetch.
    /// - Returns: The unpacked release.
    /// - Throws: `UpdateError` if the release cannot be verified or unpacked.
    public func stage(_ update: AvailableUpdate) async throws -> StagedRelease {
        guard getuid() == 0 else { throw UpdateError.notRoot }

        Log.info("downloading \(update.version)")
        let (archive, checksums, signature) = try await client.download(tag: update.tag)
        let staged = StagedRelease(
            version: update.version,
            binary: archive.deletingLastPathComponent().appendingPathComponent("sapling"))
        defer {
            try? FileManager.default.removeItem(at: checksums)
            try? FileManager.default.removeItem(at: signature)
        }
        do {
            try ReleaseSignature.verify(
                signature: try String(contentsOf: signature, encoding: .utf8),
                checksums: try Data(contentsOf: checksums), tag: update.tag)
            try verify(archive: archive, against: checksums)
            Log.info("signature and checksum verified")
            _ = try await unpack(archive)
        } catch {
            discard(staged)
            throw error
        }
        return staged
    }

    /// Swap in a staged release and restart into it.
    ///
    /// Does not return on success: `launchctl kickstart` replaces this
    /// process. The caller should treat a return as a failure.
    ///
    /// - Parameter staged: A release from `stage(_:)`.
    /// - Throws: If the binary cannot be swapped or the restart fails.
    public func install(_ staged: StagedRelease) async throws {
        guard getuid() == 0 else { throw UpdateError.notRoot }
        try Self.swapBinary(at: SaplingPaths.installedBinary, with: staged.binary.path)
        discard(staged)
        Log.info("installed \(staged.version); restarting")
        try await restart()
    }

    /// Delete a staged release that will not be installed.
    public func discard(_ staged: StagedRelease) {
        try? FileManager.default.removeItem(at: staged.binary.deletingLastPathComponent())
    }

    // MARK: - Steps

    /// Check the archive against the release's published checksums.
    func verify(archive: URL, against checksums: URL) throws {
        let name = archive.lastPathComponent
        let text = try String(contentsOf: checksums, encoding: .utf8)

        var expected: String?
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 2 else { continue }
            // shasum writes "<digest>  <name>", and the name may carry a
            // leading "*" in binary mode.
            let listed = parts[1].trimmingCharacters(in: CharacterSet(charactersIn: "*"))
            if listed == name { expected = String(parts[0]) }
        }
        guard let expected else { throw UpdateError.checksumMissing(name) }

        let digest = SHA256.hash(data: try Data(contentsOf: archive))
        let actual = digest.map { String(format: "%02x", $0) }.joined()
        guard actual == expected else {
            throw UpdateError.checksumMismatch(expected: expected, actual: actual)
        }
    }

    /// Extract the binary from the archive.
    func unpack(_ archive: URL) async throws -> URL {
        let directory = archive.deletingLastPathComponent()
        // Only the one member, and owned by root rather than the release
        // builder's uid, which bsdtar run as root would otherwise restore.
        let result = try await ProcessRunner.run(
            "/usr/bin/tar", ["--no-same-owner", "-xzf", archive.path, "-C", directory.path, "sapling"],
            timeout: .seconds(120))
        guard result.succeeded else {
            throw UpdateError.unpackFailed(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let binary = directory.appendingPathComponent("sapling")
        guard FileManager.default.isExecutableFile(atPath: binary.path) else {
            throw UpdateError.notAnExecutable
        }
        return binary
    }

    /// Replace the binary at `target`, keeping the previous one alongside it.
    ///
    /// Paths are explicit so this can be tested without writing to
    /// `/usr/local/bin` — it is the step that can leave a node unable to
    /// start, so it is worth testing directly.
    ///
    /// - Parameters:
    ///   - target: Path to replace.
    ///   - replacement: Path to the new binary.
    /// - Throws: If the replacement cannot be put in place. The previous
    ///   binary is restored before rethrowing.
    static func swapBinary(at target: String, with replacement: String) throws {
        let backup = target + ".previous"
        let fileManager = FileManager.default

        // Move aside rather than overwrite: writing over a running
        // executable's file is how you get "Text file busy".
        if fileManager.fileExists(atPath: backup) {
            try fileManager.removeItem(atPath: backup)
        }
        let movedAside = fileManager.fileExists(atPath: target)
        if movedAside {
            try fileManager.moveItem(atPath: target, toPath: backup)
        }
        do {
            try BinaryInstall.copy(from: replacement, to: target)
        } catch {
            // Put the working binary back rather than leaving the node with
            // nothing to start — but only one this call moved, or a failed
            // swap undoes someone else's successful one.
            if movedAside {
                try? fileManager.removeItem(atPath: target)
                try? fileManager.moveItem(atPath: backup, toPath: target)
            }
            throw error
        }
    }

    /// Restart the daemon into the new binary.
    ///
    /// `kickstart -k` kills and relaunches, so this process does not come
    /// back — launchd starts a fresh one from the replaced binary.
    func restart() async throws {
        let result = try await LaunchControl.restart()
        guard result.succeeded else { throw UpdateError.restartFailed(LaunchControl.explain(result)) }
    }
}

/// A release downloaded, verified and unpacked, waiting to be installed.
public struct StagedRelease: Sendable {
    /// The version it contains.
    public let version: String
    /// The unpacked binary.
    public let binary: URL
}
