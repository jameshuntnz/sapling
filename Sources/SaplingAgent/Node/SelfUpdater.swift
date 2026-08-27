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
/// root, so the download is the security boundary. Three things guard it: the
/// release is fetched over HTTPS from the configured repository only, the
/// archive is checked against the `SHA256SUMS` published alongside it, and a
/// release without checksums is refused rather than installed unverified.
///
/// What is *not* guarded: the checksums come from the same place as the
/// archive, so this detects corruption and interrupted downloads, not a
/// compromised repository. Code signing with a Developer ID would close that,
/// and is the obvious next step — see docs/AUTOMATION-GAPS.md.
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
        case busy(Int)
        case checksumMismatch(expected: String, actual: String)
        case checksumMissing(String)
        case unpackFailed(String)
        case notAnExecutable

        /// A message naming what went wrong and, where there is one, the fix.
        public var errorDescription: String? {
            switch self {
            case .notRoot:
                "updating needs root; the daemon has it, a CLI run by hand does not"
            case .busy(let count):
                "\(count) job(s) are running — updating now would orphan their VMs"
            case .checksumMismatch(let expected, let actual):
                "checksum mismatch: expected \(expected), got \(actual)"
            case .checksumMissing(let name):
                "the release's SHA256SUMS does not list \(name)"
            case .unpackFailed(let detail):
                "could not unpack the release: \(detail)"
            case .notAnExecutable:
                "the downloaded archive contains no runnable sapling binary"
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

    /// Download, verify, install, and restart into a new version.
    ///
    /// Does not return on success: `launchctl kickstart` replaces this
    /// process. The caller should treat a return as a failure.
    ///
    /// - Parameters:
    ///   - update: The version to install.
    ///   - runningJobs: How many jobs are in flight; refuses unless zero.
    ///   - force: Install even while jobs are running.
    /// - Throws: `UpdateError` if the update cannot be applied safely.
    public func apply(_ update: AvailableUpdate, runningJobs: Int, force: Bool) async throws {
        guard getuid() == 0 else { throw UpdateError.notRoot }
        // Replacing the binary restarts the daemon, and a restart marks every
        // in-flight job failed and reaps its VM.
        guard runningJobs == 0 || force else { throw UpdateError.busy(runningJobs) }

        Log.info("downloading \(update.version)")
        let (archive, checksums) = try await client.download(tag: update.tag)
        defer {
            try? FileManager.default.removeItem(at: archive.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: checksums.deletingLastPathComponent())
        }

        try verify(archive: archive, against: checksums)
        Log.info("checksum verified")

        let binary = try await unpack(archive)
        try install(binary)
        Log.info("installed \(update.version); restarting")

        try await restart()
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
        let result = try await ProcessRunner.run(
            "tar", ["xzf", archive.path, "-C", directory.path], timeout: .seconds(120))
        guard result.succeeded else {
            throw UpdateError.unpackFailed(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let binary = directory.appendingPathComponent("sapling")
        guard FileManager.default.isExecutableFile(atPath: binary.path) else {
            throw UpdateError.notAnExecutable
        }
        return binary
    }

    /// Put the new binary in place, keeping the old one to fall back to.
    func install(_ binary: URL) throws {
        try Self.swapBinary(at: SaplingPaths.installedBinary, with: binary.path)
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
        if fileManager.fileExists(atPath: target) {
            try fileManager.moveItem(atPath: target, toPath: backup)
        }
        do {
            try fileManager.copyItem(atPath: replacement, toPath: target)
            try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: target)
        } catch {
            // Put the working binary back rather than leaving the node with
            // nothing to start.
            if fileManager.fileExists(atPath: backup) {
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
        _ = try await ProcessRunner.run(
            "launchctl", ["kickstart", "-k", "system/\(SaplingPaths.launchDaemonLabel)"],
            timeout: .seconds(60))
    }
}
