import Foundation
import Testing

/// Guards the rule that only suites nested under `EnvironmentDependentTests`
/// touch the process-wide environment Sapling reads its paths from.
///
/// `.serialized` on a suite of its own orders only that suite's tests. One that
/// set `SAPLING_HOME` from outside the parent ran alongside the suites inside
/// it, swapped the home out mid-test, and failed CI on main — holding back a
/// release. Source-level for the same reason as `SessionRoutingTests`: the
/// failure is someone adding a suite without knowing the rule, and it only
/// shows up as an occasional flake.
@Suite("Environment isolation")
struct EnvironmentIsolationTests {
    static var testsDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // Install
            .deletingLastPathComponent()  // SaplingTests
    }

    @Test("every suite that changes SAPLING_HOME or SAPLING_SERVER is serialized with the rest")
    func environmentWritersAreNested() throws {
        let writes = try Regex(#"TemporaryHome\.run|setenv\("SAPLING_(HOME|SERVER)""#)
        var scanned = 0
        var offenders: [String] = []

        let files = FileManager.default.enumerator(at: Self.testsDirectory, includingPropertiesForKeys: nil)
        while let url = files?.nextObject() as? URL {
            guard url.pathExtension == "swift", url.lastPathComponent != "TestSupport.swift" else {
                continue
            }
            scanned += 1
            let source = try String(contentsOf: url, encoding: .utf8)
            if source.contains(writes), !source.contains("extension EnvironmentDependentTests") {
                offenders.append(url.lastPathComponent)
            }
        }

        // A wrong path scans nothing and passes, which is the one outcome
        // this must never produce.
        #expect(scanned > 20, "only scanned \(scanned) files under \(Self.testsDirectory.path)")
        #expect(offenders.isEmpty, "not nested under EnvironmentDependentTests: \(offenders)")
    }
}
