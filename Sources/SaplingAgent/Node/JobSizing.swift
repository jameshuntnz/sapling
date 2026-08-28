import Foundation
import SaplingCore

/// Works out how much memory a job gets, and whether this node can ever give it.
///
/// Memory is the resource jobs actually contend for, and the one that fails
/// silently when it runs short: a container over its cap is SIGKILLed by the
/// guest kernel, and the tool that survives reports its worker vanishing rather
/// than anything about memory. Rationing it explicitly is cheaper than
/// diagnosing that.
///
/// Slot counts stay as a backstop for what memory cannot see — disk for
/// checkouts and image layers, CPU oversubscription, and the container system's
/// own limits — so a node is bounded even when every job is small.
enum JobSizing {
    /// Memory a job should get, in GB.
    ///
    /// The `mem:` label wins, clamped to the platform ceiling. Absent or
    /// unparseable, the platform default applies; absent that, the tool's own
    /// default, which is only ever right by accident.
    ///
    /// - Parameters:
    ///   - labels: The job's `runs-on` labels.
    ///   - platform: Which provider will run it.
    ///   - config: The node's configuration.
    /// - Returns: Memory in GB, or nil when nothing has an opinion.
    static func memoryGB(
        labels: [String], platform: JobPlatform, config: SaplingConfig
    ) -> Int? {
        let requested = RunnerImageSelector.parse(labels).memoryGB
        let (fallback, ceiling) =
            switch platform {
            case .macos: (config.macos.memoryGB, config.macos.maxMemoryGB)
            case .linux: (config.linux.memoryGB, config.linux.maxMemoryGB)
            }
        guard let requested else { return fallback }
        guard let ceiling else { return requested }
        return min(requested, ceiling)
    }

    /// Why a job can never run here, or nil when it could.
    ///
    /// Checked before the job is queued rather than at dispatch. A request the
    /// node can never satisfy is not a job waiting for capacity, it is a job
    /// waiting forever, and a queue that silently holds one of those is worse
    /// than a workflow that fails saying why.
    ///
    /// - Parameters:
    ///   - memoryGB: What the job asked for, once sized.
    ///   - budgetGB: What jobs may collectively hold on this machine.
    ///   - ceilingGB: The platform's own ceiling on a request, if it has one.
    /// - Returns: A message naming the request and the limit, or nil.
    static func unschedulableReason(
        memoryGB: Int?, budgetGB: Int, ceilingGB: Int?
    ) -> String? {
        guard let memoryGB else { return nil }
        if let ceilingGB, memoryGB > ceilingGB {
            return
                "the job asks for \(memoryGB)GB, above this node's per-job ceiling of "
                + "\(ceilingGB)GB — raise max_memory_gb or lower the mem: label"
        }
        if memoryGB > budgetGB {
            return
                "the job asks for \(memoryGB)GB, more than the \(budgetGB)GB this node has "
                + "for jobs at all — no amount of waiting will free it"
        }
        return nil
    }

    /// Whether a job of this size fits alongside what is already running.
    ///
    /// - Parameters:
    ///   - memoryGB: What this job needs.
    ///   - committedGB: What running jobs already hold.
    ///   - budgetGB: What jobs may collectively hold.
    /// - Returns: Whether it can start now.
    static func fits(memoryGB: Int, committedGB: Int, budgetGB: Int) -> Bool {
        committedGB + memoryGB <= budgetGB
    }
}
