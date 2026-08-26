import CryptoKit
import Foundation
import Testing

@testable import SaplingAgent
@testable import SaplingCore

/// The updater downloads a binary and runs it as root, so checksum verification is the security boundary.
///
/// These cover it, and the binary swap that has to leave a working daemon behind whatever happens.
@Suite("Self updater")
struct SelfUpdaterTests {
    func makeUpdater() -> SelfUpdater {
        var config = SaplingConfig()
        config.github.auth = .pat
        config.github.token = "ghp_test"
        return SelfUpdater(config: config)
    }

    /// Writes an archive and a SHA256SUMS listing it, as a release does.
    func makeRelease(
        in directory: URL,
        named name: String = "sapling-1.0.0-macos-arm64.tar.gz",
        contents: String = "pretend archive",
        listedAs listedName: String? = nil,
        digest overrideDigest: String? = nil
    ) throws -> (archive: URL, checksums: URL) {
        let archive = directory.appendingPathComponent(name)
        try Data(contents.utf8).write(to: archive)

        let real = SHA256.hash(data: Data(contents.utf8))
            .map { String(format: "%02x", $0) }.joined()
        let checksums = directory.appendingPathComponent("SHA256SUMS")
        try "\(overrideDigest ?? real)  \(listedName ?? name)\n"
            .write(to: checksums, atomically: true, encoding: .utf8)
        return (archive, checksums)
    }

    @Test("accepts an archive matching its published checksum")
    func acceptsMatching() throws {
        let scratch = try TemporaryDirectory()
        let release = try makeRelease(in: scratch.url)
        #expect(throws: Never.self) {
            try makeUpdater().verify(archive: release.archive, against: release.checksums)
        }
    }

    /// The case that matters: a corrupted or substituted download must not be
    /// installed and run as root.
    @Test("refuses an archive whose checksum does not match")
    func refusesMismatch() throws {
        let scratch = try TemporaryDirectory()
        let release = try makeRelease(in: scratch.url, digest: String(repeating: "0", count: 64))

        #expect(throws: SelfUpdater.UpdateError.self) {
            try makeUpdater().verify(archive: release.archive, against: release.checksums)
        }
    }

    /// A release that lists other files but not this one is unverifiable, and
    /// unverifiable must mean refused rather than assumed fine.
    @Test("refuses an archive the checksums don't mention")
    func refusesUnlisted() throws {
        let scratch = try TemporaryDirectory()
        let release = try makeRelease(in: scratch.url, listedAs: "something-else.tar.gz")

        #expect(throws: SelfUpdater.UpdateError.self) {
            try makeUpdater().verify(archive: release.archive, against: release.checksums)
        }
    }

    /// `shasum -b` writes the name with a leading asterisk.
    @Test("understands binary-mode checksum lines")
    func binaryModeLines() throws {
        let scratch = try TemporaryDirectory()
        let release = try makeRelease(
            in: scratch.url, listedAs: "*sapling-1.0.0-macos-arm64.tar.gz")
        #expect(throws: Never.self) {
            try makeUpdater().verify(archive: release.archive, against: release.checksums)
        }
    }

    @Test("picks the right line out of a multi-entry checksum file")
    func multipleEntries() throws {
        let scratch = try TemporaryDirectory()
        let name = "sapling-1.0.0-macos-arm64.tar.gz"
        let archive = scratch.appending(name)
        try Data("pretend archive".utf8).write(to: archive)
        let real = SHA256.hash(data: Data("pretend archive".utf8))
            .map { String(format: "%02x", $0) }.joined()

        let checksums = scratch.appending("SHA256SUMS")
        try """
        \(String(repeating: "a", count: 64))  some-other-file.tar.gz
        \(real)  \(name)
        \(String(repeating: "b", count: 64))  yet-another.tar.gz
        """.write(to: checksums, atomically: true, encoding: .utf8)

        #expect(throws: Never.self) {
            try makeUpdater().verify(archive: archive, against: checksums)
        }
    }

    // MARK: - Installing

    /// The previous binary is kept so a bad update can be backed out.
    @Test("keeps the previous binary when swapping")
    func keepsPrevious() throws {
        let scratch = try TemporaryDirectory()
        let target = scratch.appending("sapling")
        try "old version".write(to: target, atomically: true, encoding: .utf8)

        let replacement = scratch.appending("new-sapling")
        try "new version".write(to: replacement, atomically: true, encoding: .utf8)

        try SelfUpdater.swapBinary(at: target.path, with: replacement.path)

        #expect(try String(contentsOf: target, encoding: .utf8) == "new version")
        #expect(
            try String(contentsOfFile: target.path + ".previous", encoding: .utf8) == "old version")
        let mode = try FileManager.default.attributesOfItem(atPath: target.path)[.posixPermissions]
        #expect(mode as? Int == 0o755)
    }

    /// A failed swap must not leave the node with no binary to start.
    @Test("restores the working binary if the swap fails")
    func rollsBackOnFailure() throws {
        let scratch = try TemporaryDirectory()
        let target = scratch.appending("sapling")
        try "old version".write(to: target, atomically: true, encoding: .utf8)

        #expect(throws: (any Error).self) {
            try SelfUpdater.swapBinary(at: target.path, with: scratch.appending("absent").path)
        }
        // The daemon still has something to restart into.
        #expect(FileManager.default.fileExists(atPath: target.path))
        #expect(try String(contentsOf: target, encoding: .utf8) == "old version")
    }

    @Test("installs cleanly when there is nothing to replace")
    func firstInstall() throws {
        let scratch = try TemporaryDirectory()
        let target = scratch.appending("sapling")
        let replacement = scratch.appending("new-sapling")
        try "new version".write(to: replacement, atomically: true, encoding: .utf8)

        try SelfUpdater.swapBinary(at: target.path, with: replacement.path)
        #expect(try String(contentsOf: target, encoding: .utf8) == "new version")
    }
}
