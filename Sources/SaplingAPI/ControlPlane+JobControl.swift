import Foundation
import SaplingAgent
import SaplingCore
import SaplingDB

/// Acting on a single job, rather than reporting on it.
///
/// The rest of the control plane only reads (§5.1). These two write, so they
/// are kept apart: everything here has to say plainly what it did and, just as
/// importantly, what it did not do — neither action touches GitHub.
extension ControlPlane {
    /// Stop running a job.
    ///
    /// Frees the node's slot. It does not cancel the job on GitHub, which has
    /// no per-job cancel — see `NodeAgent.cancel(jobID:reason:)` for why
    /// cancelling the whole run instead is not an acceptable substitute.
    ///
    /// - Parameter id: The job to stop.
    /// - Returns: What happened, or `nil` if there is no such job.
    /// - Throws: If the store cannot be read or written.
    public func cancelJob(id: String) async throws -> JobActionResponse? {
        guard let job = try await store.job(id: id) else { return nil }

        guard let agent else {
            // No agent in this process, so nothing to tear down — the most
            // this can honestly do is record the decision. Mirrors how
            // `setStatus` degrades rather than refusing outright.
            return try await cancelInStore(job)
        }

        switch await agent.cancel(jobID: id, reason: Self.userCancelReason) {
        case .stopped:
            return JobActionResponse(
                status: .cleanup, changed: true,
                message: "stopping job \(id); its environment is being torn down. "
                    + "GitHub was not told — the job stays queued there until its own timeout.")
        case .dropped:
            return JobActionResponse(
                status: .cancelled, changed: true,
                message: "job \(id) cancelled; nothing was running for it here")
        case .alreadyFinished(let status):
            return JobActionResponse(
                status: status, changed: false,
                message: "job \(id) already \(status.rawValue)")
        case .notFound:
            return nil
        }
    }

    /// Queue a finished job to run again.
    ///
    /// Ignores the attempt ceiling on purpose — see
    /// `SaplingStore.retryJob(id:)`. The job is dispatched on the next poll
    /// cycle, and dropped again with a reason if GitHub has since finished
    /// with it.
    ///
    /// - Parameter id: The job to run again.
    /// - Returns: What happened, or `nil` if there is no such job.
    /// - Throws: If the store cannot be read or written.
    public func retryJob(id: String) async throws -> JobActionResponse? {
        switch try await store.retryJob(id: id) {
        case .queued:
            return JobActionResponse(
                status: .queued, changed: true,
                message: "job \(id) is queued again and will start on the next poll")
        case .stillActive(.queued):
            return JobActionResponse(
                status: .queued, changed: false,
                message: "job \(id) is already queued")
        case .stillActive(let status):
            return JobActionResponse(
                status: status, changed: false,
                message: "job \(id) is still \(status.rawValue) — stop it first")
        case .notFound:
            return nil
        }
    }

    /// Recorded on the job and in its event log, so the reason a build stopped
    /// is answerable months later without anyone having to remember.
    static let userCancelReason = "cancelled from the Sapling app"

    private func cancelInStore(_ job: Job) async throws -> JobActionResponse? {
        guard !job.status.isTerminal else {
            return JobActionResponse(
                status: job.status, changed: false,
                message: "job \(job.id) already \(job.status.rawValue)")
        }
        try await store.appendEvent(
            jobID: job.id, event: RunEventName.jobCancelled, detail: Self.userCancelReason)
        try await store.updateJobStatus(
            id: job.id, status: .cancelled, exitReason: Self.userCancelReason, completedAt: Date())
        return JobActionResponse(
            status: .cancelled, changed: true,
            message: "job \(job.id) recorded as cancelled; no agent here to tear anything down")
    }
}
