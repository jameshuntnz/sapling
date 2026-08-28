import Foundation

/// Why a queued job has not started yet.
///
/// Worth stating rather than leaving to be inferred. Under memory admission a
/// node can be half-idle by slot count and completely full by memory, so "one
/// of four Linux slots in use" and "nothing else can start" are true at the
/// same time — and a reader with only the first will conclude the scheduler is
/// broken.
///
/// The awkward one is `behindLargerJob`. Admission stops at the first job that
/// does not fit rather than stepping over it, so small jobs that *would* fit
/// are held back on purpose to stop a large one starving. That is deliberate,
/// counter-intuitive, and looks exactly like a bug unless it says so.
public enum QueueReason: Sendable, Hashable {
    /// Every slot this platform has is occupied.
    case platformFull(inUse: Int, capacity: Int)
    /// The node is running as many jobs as it will, whatever the platform.
    case nodeFull(capacity: Int)
    /// Not enough unreserved memory, with what it wants and what is free.
    case waitingForMemory(wantsGB: Int, freeGB: Int)
    /// Held so an older, larger job is not starved by a stream of small ones.
    case behindLargerJob(name: String)

    /// One line, phrased for someone asking why their job has not started.
    public var summary: String {
        switch self {
        case .platformFull(let inUse, let capacity):
            "waiting for a slot (\(inUse)/\(capacity) in use)"
        case .nodeFull(let capacity):
            "waiting — the node runs \(capacity) job(s) at once"
        case .waitingForMemory(let wants, let free):
            "waiting for \(wants)GB — \(free)GB free"
        case .behindLargerJob(let name):
            "waiting behind \"\(name)\", which needs more memory"
        }
    }
}

/// Works out why each queued job is waiting, in the order the scheduler sees them.
///
/// Mirrors `dispatchQueuedJobs` deliberately: it is the same walk, reporting
/// instead of dispatching. Keeping the two in step matters more than sharing
/// code between them — an explanation that disagrees with the scheduler is
/// worse than none, because it will be believed.
public enum QueueExplainer {
    /// Explains a queue against a node's current commitments.
    ///
    /// - Parameters:
    ///   - queued: Queued jobs, oldest first, as the scheduler orders them.
    ///   - inUse: Slots occupied per platform.
    ///   - capacity: Slots available per platform.
    ///   - nodeCapacity: Jobs the node runs at once, across platforms.
    ///   - committedGB: Memory already reserved.
    ///   - budgetGB: Memory jobs may collectively hold.
    ///   - sizeOf: The memory a given job needs.
    /// - Returns: A reason per job id, for those that cannot start yet.
    public static func explain(
        queued: [Job],
        inUse: [JobPlatform: Int],
        capacity: [JobPlatform: Int],
        nodeCapacity: Int,
        committedGB: Int,
        budgetGB: Int,
        sizeOf: (Job) -> Int
    ) -> [String: QueueReason] {
        var reasons: [String: QueueReason] = [:]
        var used = inUse
        var committed = committedGB
        var blocker: Job?

        for job in queued {
            // Once the walk has stopped, everything after it is waiting on the
            // job that stopped it — not on its own size.
            if let blocker {
                reasons[job.id] = .behindLargerJob(name: blocker.name ?? "job \(blocker.id)")
                continue
            }

            let platformUsed = used[job.platform] ?? 0
            let platformCapacity = capacity[job.platform] ?? 0
            if platformUsed >= platformCapacity {
                reasons[job.id] = .platformFull(inUse: platformUsed, capacity: platformCapacity)
                continue
            }
            if used.values.reduce(0, +) >= nodeCapacity {
                reasons[job.id] = .nodeFull(capacity: nodeCapacity)
                continue
            }

            let wants = sizeOf(job)
            guard committed + wants <= budgetGB else {
                reasons[job.id] = .waitingForMemory(
                    wantsGB: wants, freeGB: max(0, budgetGB - committed))
                blocker = job
                continue
            }

            // It would start. Account for it so the jobs behind it are judged
            // against the queue the scheduler will actually have.
            used[job.platform] = platformUsed + 1
            committed += wants
        }
        return reasons
    }
}
