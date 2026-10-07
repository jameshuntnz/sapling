import Foundation
import SaplingCore

/// Learning which GitHub job each of this node's runners actually took.
extension NodeAgent {
    /// Records, for every runner this node has in flight, the job GitHub gave
    /// it — which is not necessarily the job it was started for.
    ///
    /// - Parameter assigned: In-progress jobs from this poll, keyed by runner.
    func recordAssignments(_ assigned: [String: WorkflowJob]) async {
        for (jobID, runnerName) in runnerNames {
            guard let remote = assigned[runnerName] else { continue }
            try? await store.setJobAssignment(
                id: jobID, jobID: String(remote.id), runID: String(remote.runId))
        }
    }
}
