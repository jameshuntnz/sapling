import Foundation
import SaplingCore

extension NetworkGuard {
    /// What pf actually has loaded — or the fact that we could not find out.
    ///
    /// The third case is the point. `pfctl -sr` needs root and the CLI is not,
    /// so `sapling doctor` used to print "anchor wired; rules are written when
    /// the first job starts" whether the rules were loaded, absent, or
    /// unreadable. Reporting green on an unknown is worse than reporting
    /// nothing: it was still saying `ok` throughout an outage.
    public enum AnchorState: Sendable {
        /// The anchor is loaded and carries a block rule.
        case loaded([String])
        /// pf answered, and the anchor has no block rule in it.
        case empty
        /// pf could not be read, with the reason.
        case unverifiable(String)
        /// The anchor may hold rules, but pf is not evaluating them.
        case inactive(String)

        /// Whether the filter is known to be in force.
        public var isLoaded: Bool { if case .loaded = self { true } else { false } }
    }

    /// Read back what pf actually has loaded, rather than trusting that our
    /// write succeeded. `sapling doctor` uses this.
    public static func verify() async -> AnchorState {
        guard getuid() == 0 else {
            return .unverifiable("`pfctl -sr` needs root; run `sudo sapling doctor` to check the rules")
        }
        // Rules in an anchor do nothing while pf is off, and macOS loads
        // pf.conf at boot without enabling it.
        guard let info = try? await ProcessRunner.run("pfctl", ["-s", "info"], timeout: .seconds(20)),
            info.succeeded
        else {
            return .unverifiable("`pfctl -s info` failed")
        }
        guard info.stdout.contains("Status: Enabled") else {
            return .inactive("pf is disabled")
        }
        guard let main = try? await ProcessRunner.run("pfctl", ["-sr"], timeout: .seconds(20)),
            main.succeeded
        else {
            return .unverifiable("`pfctl -sr` failed")
        }
        guard main.stdout.contains("anchor \"\(anchorName)\"") else {
            return .inactive(
                "the main ruleset does not evaluate the \(anchorName) anchor; run `sudo sapling install`")
        }
        guard
            let result = try? await ProcessRunner.run(
                "pfctl", ["-a", anchorName, "-sr"], timeout: .seconds(20)),
            result.succeeded
        else {
            return .unverifiable("`pfctl -a \(anchorName) -sr` failed")
        }
        let rules = result.stdout
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        // An anchor that exists but has no block rule is worse than none at
        // all, because it looks configured.
        return rules.contains { $0.hasPrefix("block") } ? .loaded(rules) : .empty
    }

    /// Removes Sapling's rules from pf, leaving the anchor in place.
    public static func flush() async {
        _ = try? await ProcessRunner.run("pfctl", ["-a", anchorName, "-F", "rules"], timeout: .seconds(20))
    }
}
