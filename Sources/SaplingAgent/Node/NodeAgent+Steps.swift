import Foundation
import SaplingCore

/// A job's steps, read from GitHub for the panel's job view.
extension NodeAgent {
    /// The steps of the GitHub job this node's runner took.
    ///
    /// Asks about the assigned job rather than `id`: a JIT runner can pick up
    /// a different queued job, leaving `id` itself still queued with no steps.
    ///
    /// - Parameter job: The job to report on.
    /// - Returns: Its steps, or the reason they could not be read.
    public func steps(for job: Job) async -> JobStepsResponse {
        guard let githubID = Int64(job.assignedJobID ?? job.id) else {
            return JobStepsResponse(jobID: job.id, unavailableReason: "not a GitHub job id")
        }
        do {
            let remote = try await github.job(repo: job.repo, jobID: githubID)
            let steps = (remote.steps ?? []).map {
                JobStep(
                    number: $0.number, name: $0.name, status: $0.status, conclusion: $0.conclusion,
                    startedAt: $0.startedAt, completedAt: $0.completedAt)
            }
            return JobStepsResponse(jobID: job.id, steps: steps)
        } catch {
            return JobStepsResponse(jobID: job.id, unavailableReason: error.localizedDescription)
        }
    }
}
