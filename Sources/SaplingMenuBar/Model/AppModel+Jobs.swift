import Foundation
import SaplingCore

/// Things the panel says about a job that the job record alone does not.
extension AppModel {
    /// How long a runner may wait for an assignment before it is worth saying.
    ///
    /// Every job spends a few seconds here between registering and being
    /// given its work. Three minutes is far past that, and far short of the
    /// two-hour job timeout a runner that is never going to be assigned
    /// otherwise waits out.
    static let waitingThreshold: TimeInterval = 180

    /// When this job's runner started waiting for GitHub, if it has waited
    /// long enough to be worth flagging.
    ///
    /// - Parameters:
    ///   - jobID: The job to ask about.
    ///   - now: The time to measure against.
    /// - Returns: The start of the wait, or `nil` if it is not stuck.
    func stuckSince(jobID: String, now: Date = Date()) -> Date? {
        guard let since = status?.awaitingAssignment?[jobID],
            now.timeIntervalSince(since) >= Self.waitingThreshold
        else { return nil }
        return since
    }

    /// Refresh the selected job's steps, unless the job and its steps are done.
    ///
    /// Each refresh is a GitHub request made by the node, so a finished job
    /// is not asked again on every poll.
    func syncSteps(jobID: String, client: SaplingClient) async {
        if let current = selectedJobSteps, current.jobID == jobID, current.isSettled,
            selectedJobDetail?.job.status.isTerminal == true
        {
            return
        }
        let steps: JobStepsResponse
        do {
            steps = try await client.jobSteps(jobID: jobID)
        } catch {
            // A daemon older than the endpoint answers 404; say so, not "loading".
            steps = JobStepsResponse(jobID: jobID, unavailableReason: error.localizedDescription)
        }
        guard selectedJobID == jobID else { return }
        selectedJobSteps = steps
    }
}

extension Job {
    /// The job's page on GitHub, or its repository's Actions page when the
    /// run is not known.
    ///
    /// Prefers the job the runner actually took: a JIT runner can pick up a
    /// different queued job, leaving `id` itself still queued.
    var gitHubURL: URL? {
        if let assignedJobID, let assignedRunID {
            return URL(
                string: "https://github.com/\(repo)/actions/runs/\(assignedRunID)/job/\(assignedJobID)")
        }
        guard let runID = workflowRunID else {
            return URL(string: "https://github.com/\(repo)/actions")
        }
        return URL(string: "https://github.com/\(repo)/actions/runs/\(runID)/job/\(id)")
    }
}
