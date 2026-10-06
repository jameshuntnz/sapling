import Foundation

/// Response body for `POST /api/v1/jobs/:id/cancel` and
/// `POST /api/v1/jobs/:id/retry`.
///
/// Both actions are idempotent in the sense that matters — asking twice is
/// harmless — but the second ask does nothing, and a UI that reports success
/// either way teaches you to distrust it. `changed` is what a client should
/// key off; `message` is what it should show.
public struct JobActionResponse: Codable, Sendable {
    /// The job's status after the request.
    public var status: JobStatus
    /// Whether this request actually moved the job.
    ///
    /// False for the no-op cases: cancelling something already finished,
    /// retrying something still running.
    public var changed: Bool
    /// What happened, phrased for a person.
    public var message: String

    /// Creates a job action result.
    public init(status: JobStatus, changed: Bool, message: String) {
        self.status = status
        self.changed = changed
        self.message = message
    }
}
