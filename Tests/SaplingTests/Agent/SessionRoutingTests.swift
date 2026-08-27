import Foundation
import Testing

@testable import SaplingAgent

/// Guards the rule that every `tart` and `container` call goes through
/// `SessionCommand`.
///
/// Both tools need the console user's session — `container` for its apiserver,
/// Virtualization for its keychain — and running them as root fails in ways
/// that surface far from the cause. A single missed call site is enough: an
/// invocation left direct produced a root-owned VM clone, and the failure
/// showed up one step later as `utimes(2): Operation not permitted` from a
/// completely different command.
///
/// This is a source-level check rather than a behavioural one because the
/// failure mode is "someone adds a call site and doesn't know the rule" —
/// which no runtime test would catch.
@Suite("Session routing")
struct SessionRoutingTests {
    static var sourcesDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // Agent
            .deletingLastPathComponent()  // SaplingTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // repository root
            .appendingPathComponent("Sources")
    }

    @Test("no source file invokes tart or container directly")
    func allInvocationsGoThroughSessionCommand() throws {
        let pattern = try Regex(#"ProcessRunner\.(run|runChecked|stream)\(\s*"(tart|container)""#)
            .dotMatchesNewlines()

        // Without this, a wrong path scans nothing, finds no offenders, and
        // reports success — the one outcome this test must never produce.
        var scanned = 0
        #expect(
            FileManager.default.fileExists(atPath: Self.sourcesDirectory.path),
            "Sources not found at \(Self.sourcesDirectory.path)")

        var offenders: [String] = []
        let enumerator = FileManager.default.enumerator(
            at: Self.sourcesDirectory, includingPropertiesForKeys: nil)
        while let url = enumerator?.nextObject() as? URL {
            guard url.pathExtension == "swift" else { continue }
            scanned += 1
            let source = try String(contentsOf: url, encoding: .utf8)
            // Matched against the whole file, not line by line. Scanning lines
            // let a real offender through for months: swift-format had wrapped
            //   ProcessRunner.run(
            //       "container", ["images", "pull", image], ...)
            // across two lines, so neither line matched on its own and the
            // guard reported clean while the call ran unrouted as root.
            for match in source.matches(of: pattern) {
                let line = source[..<match.range.lowerBound].split(
                    separator: "\n", omittingEmptySubsequences: false
                ).count
                offenders.append("\(url.lastPathComponent):\(line)")
            }
        }

        #expect(scanned > 50, "expected to scan the whole source tree, saw \(scanned) files")
        #expect(
            offenders.isEmpty,
            """
            These call tart/container directly instead of via SessionCommand, so they \
            will run as root and fail: \(offenders.joined(separator: " | "))
            """)
    }

    /// The rule only holds if the helper actually exists to be used.
    @Test("the session helpers are present")
    func helpersExist() throws {
        let tart = try String(
            contentsOf: Self.sourcesDirectory
                .appendingPathComponent("SaplingAgent/Providers/TartProvider.swift"),
            encoding: .utf8)
        #expect(tart.contains("static func tart("))
    }
}
