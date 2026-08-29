import Foundation

/// What a job's history says about the memory it asks for.
///
/// Deliberately narrow, because the obvious signal does not support the
/// obvious advice. `JobResourceSample.memoryFootprint` is what the *host* has
/// committed to an environment, and a guest spends its spare memory on page
/// cache and never hands it back — so the figure climbs to whatever the job
/// was given and stays there, whatever the job actually needed. Measured on
/// this node: an Android build reserving 6GB peaked at 6.16GB and passed, and
/// a macOS job reserving 6GB peaked at 6.02GB and passed. Reading either as
/// "nearly out of memory" would warn on every healthy job, and reading a low
/// peak as "oversized" would never fire at all.
///
/// What is left is the signal that means exactly one thing: the guest kernel's
/// OOM counter. A job that was killed for memory was too small, and no
/// interpretation is required.
///
/// Advising a job *down* needs the guest's own anonymous memory rather than
/// the host's footprint — `memory.stat`'s `anon` inside the container, which
/// the OOM watcher is already positioned to read. Until that exists this says
/// nothing about oversizing, because it has nothing to say.
public enum MemoryAdvice: Codable, Sendable, Hashable {
    /// Killed for memory in recent runs at this size.
    case killedBefore(requestGB: Int, kills: Int, runs: Int)

    /// One line, phrased as something to do rather than something to know.
    public var summary: String {
        switch self {
        case .killedBefore(let request, let kills, let runs):
            "killed for memory in \(kills) of the last \(runs) runs at \(request)GB — "
                + "raise its `mem:` label"
        }
    }

    /// Whether this is a warning rather than an efficiency note.
    public var isWarning: Bool { true }
}

/// Turns a job's history into advice about the memory it asks for.
public enum MemorySizing {
    /// Fewest runs before saying anything.
    ///
    /// One kill can be a bad day on a loaded node. A pattern is what justifies
    /// telling somebody to change a number in their workflow.
    public static let minimumRuns = 3

    /// Advice for a job, or nil when its history says nothing useful.
    ///
    /// - Parameters:
    ///   - requestGB: What the job reserves.
    ///   - outcomes: Why recent runs of this job ended, most recent first.
    /// - Returns: Advice worth showing, or nil.
    public static func advise(requestGB: Int, outcomes: [FailureKind]) -> MemoryAdvice? {
        guard requestGB > 0, outcomes.count >= minimumRuns else { return nil }
        let kills = outcomes.filter { $0 == .memoryKill }.count
        guard kills > 0 else { return nil }
        return .killedBefore(requestGB: requestGB, kills: kills, runs: outcomes.count)
    }
}

/// Classifies a failure the node caused from one the build caused.
///
/// Both arrive as a failed job with a reason, and they call for opposite
/// responses: one is a workflow or node setting to change, the other is code
/// to fix. Flattening them is the mistake this whole area exists to undo — a
/// build OOM-killed by the guest kernel is indistinguishable from a compile
/// error unless something says otherwise, which cost a day of looking in the
/// wrong place.
public enum FailureKind: Sendable, Hashable {
    /// The build ran and failed on its own merits.
    case build
    /// The guest kernel killed something for memory.
    case memoryKill
    /// The node would never have been able to run this job.
    case refused

    /// Reads the kind out of a job's recorded reason.
    ///
    /// Matched on the phrases Sapling itself writes, not on anything a build
    /// tool emits — those are the strings this code controls.
    ///
    /// - Parameter reason: A job's `exitReason`.
    /// - Returns: What kind of failure it was.
    public static func of(reason: String?) -> FailureKind {
        guard let reason = reason?.lowercased() else { return .build }
        if reason.contains("oom-killed") || reason.contains("killed for memory") {
            return .memoryKill
        }
        if reason.contains("more than the") || reason.contains("per-job ceiling") {
            return .refused
        }
        return .build
    }

    /// An SF Symbol that distinguishes it at a glance.
    public var symbol: String {
        switch self {
        case .build: "xmark.circle.fill"
        case .memoryKill: "memorychip.fill"
        case .refused: "hand.raised.fill"
        }
    }

    /// What the reader should understand the failure to be.
    public var label: String? {
        switch self {
        case .build: nil
        case .memoryKill: "out of memory"
        case .refused: "refused — the node cannot run this"
        }
    }
}
