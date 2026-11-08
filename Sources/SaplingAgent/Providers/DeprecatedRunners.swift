import Foundation

/// Runner versions GitHub has refused on this node.
///
/// A base image's baked-in runner goes stale on GitHub's schedule, not ours.
/// Remembering the refusal lets the next VM replace that runner instead of
/// failing the same way until someone rebuilds the image.
actor DeprecatedRunners {
    /// The node-wide record; refusals are seen per job but apply to every VM.
    static let shared = DeprecatedRunners()

    private var newestRefused: [Int]?

    /// Note a version GitHub refused.
    func record(_ version: String) {
        guard let parsed = Self.components(version) else { return }
        if let current = newestRefused, !current.lexicographicallyPrecedes(parsed) { return }
        newestRefused = parsed
    }

    /// Whether `version` is at or below one GitHub has refused.
    func isRefused(_ version: String) -> Bool {
        guard let refused = newestRefused, let parsed = Self.components(version) else { return false }
        return !refused.lexicographicallyPrecedes(parsed)
    }

    /// The version named in the runner's refusal, if `text` contains one.
    ///
    /// The runner prints `Runner version v2.336.0 is deprecated and cannot
    /// receive messages.` and then exits without taking a job.
    static func refusedVersion(in text: String) -> String? {
        guard let match = text.firstMatch(of: /Runner version v?([0-9]+(?:\.[0-9]+)+) is deprecated/) else {
            return nil
        }
        return String(match.1)
    }

    private static func components(_ version: String) -> [Int]? {
        let trimmed = version.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: ".").map { Int($0) }
        guard !parts.isEmpty, parts.allSatisfy({ $0 != nil }) else { return nil }
        return parts.compactMap { $0 }
    }
}
