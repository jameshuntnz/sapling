import Foundation
import SaplingCore

/// Serialises every write to the pf anchor, and skips the ones that would
/// change nothing.
///
/// `NetworkGuard.apply()` runs before *every* job, and two jobs dispatched in
/// the same poll cycle run it concurrently — which is the normal case on a
/// node running both platforms. Two unsynchronised callers is a problem for
/// three separate reasons:
///
/// - **A flush leaves a window with no rules at all.** `pfctl -a sapling -F
///   all` empties the anchor before the new ruleset is loaded. One caller
///   flushing while the other believes it has just finished loading means
///   jobs running unfiltered, which is the one outcome §8 rules out.
/// - **They can compute different rulesets.** The rules include whatever
///   bridges are currently up, and a bridge appearing between the two reads
///   changes the answer — so each reload undoes the other's, indefinitely.
/// - **pf refuses a reload whose tables are still referenced**, with
///   `cannot define table ...: Resource busy`. Two overlapping loads make that
///   far more likely, and a job refuses to start when the filter cannot be
///   applied — so the failure is a job that never runs.
///
/// Actor isolation makes the read-decide-write sequence atomic, which is all
/// this needs. It also remembers what it loaded, so the common case — a second
/// job wanting exactly the rules already in force — costs nothing.
actor AnchorWriter {
    /// The one writer. pf is a single global resource, so this is too.
    static let shared = AnchorWriter()

    /// The ruleset last successfully loaded by this process.
    private var loaded: String?

    /// Load these rules, unless they are already in force.
    ///
    /// - Parameters:
    ///   - rules: The complete anchor contents.
    ///   - path: Where the anchor file lives.
    ///   - anchor: The pf anchor name.
    /// - Throws: `NetworkGuardError.loadFailed` if pf rejects the ruleset.
    func load(rules: String, path: String, anchor: String) async throws {
        // Two ways to already be correct: this process loaded these rules, or
        // the file on disk matches and pf confirms a block rule is live. The
        // second covers the first apply after a daemon restart.
        if loaded == rules, await NetworkGuard.verify().isLoaded { return }
        let existing = try? String(contentsOfFile: path, encoding: .utf8)
        if existing == rules, await NetworkGuard.verify().isLoaded {
            loaded = rules
            return
        }

        try rules.write(toFile: path, atomically: true, encoding: .utf8)

        // The rules genuinely changed, so the old ones have to go first —
        // reloading an anchor whose tables are still referenced fails with
        // "Resource busy". This leaves a brief unfiltered window, which is why
        // it only happens when something actually changed, and why it happens
        // under this actor rather than from two callers at once.
        _ = try? await ProcessRunner.run("pfctl", ["-a", anchor, "-F", "all"], timeout: .seconds(20))

        // pf may be disabled entirely on a fresh machine; -E enables it and
        // bumps a reference count, which is safe to call repeatedly.
        _ = try? await ProcessRunner.run("pfctl", ["-E"], timeout: .seconds(20))

        let load = try await ProcessRunner.run(
            "pfctl", ["-a", anchor, "-f", path], timeout: .seconds(30))
        guard load.succeeded else {
            throw NetworkGuardError.loadFailed(
                load.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        loaded = rules
    }
}
