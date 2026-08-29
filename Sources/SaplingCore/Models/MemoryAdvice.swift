import Foundation

/// What a job's observed peaks say about the memory it asks for.
///
/// The point of the whole exercise. A `mem:` label is a number somebody had to
/// guess, and guessing it wrong is expensive in both directions: too low and
/// the guest's OOM killer takes the build with no message naming memory, too
/// high and the job holds budget nobody else can use. Sapling already measures
/// what each environment actually reaches, so the number can be read off
/// history instead of guessed.
///
/// This is not hypothetical tuning. The 6GB the Android build asks for was
/// found by running it by hand in containers on the node at 4GB and 6GB and
/// reading `memory.peak` — work this makes unnecessary next time.
public enum MemoryAdvice: Codable, Sendable, Hashable {
    /// Reserving far more than it has ever used.
    case oversized(requestGB: Int, peakGB: Int, suggestGB: Int, runs: Int)
    /// Running close enough to its limit to be at risk of an OOM kill.
    case tight(requestGB: Int, peakGB: Int, runs: Int)

    /// One line, phrased as something to do rather than something to know.
    public var summary: String {
        switch self {
        case .oversized(let request, let peak, let suggest, let runs):
            "peaked at \(peak)GB across \(runs) runs but reserves \(request)GB — "
                + "`mem:\(suggest)` would free \(request - suggest)GB for other jobs"
        case .tight(let request, let peak, let runs):
            "peaked at \(peak)GB against a \(request)GB limit across \(runs) runs — "
                + "close enough to risk an OOM kill; consider raising it"
        }
    }

    /// Whether this is a warning rather than an efficiency note.
    public var isWarning: Bool {
        if case .tight = self { return true }
        return false
    }
}

/// Turns observed peaks into advice about a job's memory request.
public enum MemorySizing {
    /// Fewest runs before saying anything.
    ///
    /// One run is an anecdote and two is a coincidence. A build's peak moves
    /// with what it happens to compile, and advising a smaller label off a
    /// single quiet run is how you cause the OOM you were trying to prevent.
    public static let minimumRuns = 3

    /// Headroom kept above the observed peak, as a multiplier.
    ///
    /// Peaks are a floor, not a ceiling: the next run may pull a larger
    /// dependency or compile more. This buys room for that without giving back
    /// the whole saving.
    public static let headroom = 1.3

    /// Fraction of its request a job must exceed to be called tight.
    public static let tightRatio = 0.9

    /// Advice for a job, or nil when its request looks right or unproven.
    ///
    /// - Parameters:
    ///   - requestGB: What the job reserves.
    ///   - peaks: Observed peak memory, in bytes, one per completed run.
    /// - Returns: Advice worth showing, or nil.
    public static func advise(requestGB: Int, peaks: [Int64]) -> MemoryAdvice? {
        guard requestGB > 0, peaks.count >= minimumRuns else { return nil }
        guard let worst = peaks.max(), worst > 0 else { return nil }

        let peakGB = Int((Double(worst) / 1_073_741_824).rounded(.up))
        if Double(peakGB) >= Double(requestGB) * tightRatio {
            return .tight(requestGB: requestGB, peakGB: peakGB, runs: peaks.count)
        }

        let suggested = max(1, Int((Double(peakGB) * headroom).rounded(.up)))
        // Only worth saying when acting on it frees something. A one-gigabyte
        // saving is noise on a machine that rations in whole gigabytes.
        guard requestGB - suggested >= 2 else { return nil }
        return .oversized(
            requestGB: requestGB, peakGB: peakGB, suggestGB: suggested, runs: peaks.count)
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
