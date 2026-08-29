import Foundation

/// What happened during a run, and what a node hands out to join it.
///
/// Split from the job and node models to keep each file readable: these
/// describe a run's narrative and enrolment, not the things being scheduled.
public struct RunEvent: Codable, Sendable, Identifiable, Hashable {
    /// Row id, assigned on insert.
    ///
    /// Clients use it to tail incrementally.
    public var id: Int64?
    /// The job this belongs to.
    public var jobID: String
    /// When it happened.
    public var ts: Date
    /// Event name — one of `RunEventName`, or free text.
    public var event: String
    /// Additional context, such as a VM name or a line of runner output.
    public var detail: String?

    /// Creates a log entry.
    public init(id: Int64? = nil, jobID: String, ts: Date = Date(), event: String, detail: String? = nil) {
        self.id = id
        self.jobID = jobID
        self.ts = ts
        self.event = event
        self.detail = detail
    }
}

/// Well-known event names.
///
/// Free-text events are allowed too; these just keep the common path
/// consistent so the log viewer can highlight lifecycle steps.
public enum RunEventName {
    /// The node took ownership of a queued job.
    public static let jobClaimed = "job_claimed"
    /// A VM was cloned from the base image.
    public static let vmCloned = "vm_cloned"
    /// The VM booted and reported an address.
    public static let vmBooted = "vm_booted"
    /// SSH into the VM succeeded.
    public static let sshConnected = "ssh_connected"
    /// The ephemeral runner was configured.
    public static let runnerRegistered = "runner_registered"
    /// The runner process started.
    public static let runnerStarted = "runner_started"
    /// A repository-defined image needed building before the job could start.
    public static let imageBuildStarted = "image_build_started"
    /// That image finished building and is cached for later jobs.
    public static let imageBuildFinished = "image_build_finished"
    /// The image could not be built, so the job never ran.
    public static let imageBuildFailed = "image_build_failed"
    /// A Linux container started.
    public static let containerStarted = "container_started"
    /// The job finished successfully.
    public static let jobCompleted = "job_completed"
    /// The job failed, or couldn't be run.
    public static let jobFailed = "job_failed"
    /// GitHub withdrew the job, so the node stopped running it.
    public static let jobCancelled = "job_cancelled"
    /// The job went back in the queue for another attempt.
    public static let jobRequeued = "job_requeued"
    /// Teardown of the VM or container began.
    public static let cleanupStarted = "cleanup_started"
    /// Teardown finished and the slot was released.
    public static let cleanupFinished = "cleanup_finished"
    /// A line of output from the runner.
    public static let log = "log"
}

/// A single-use token for enrolling another Mac as a node.
///
/// Single-use and short-lived by design, so a leaked token doesn't stay
/// useful.
public struct JoinToken: Codable, Sendable {
    /// The token value itself.
    public var token: String
    /// When it was issued.
    public var createdAt: Date
    /// When it stops being accepted.
    public var expiresAt: Date
    /// When it was redeemed, if it has been.
    public var usedAt: Date?

    /// Creates an enrollment token record.
    public init(token: String, createdAt: Date, expiresAt: Date, usedAt: Date? = nil) {
        self.token = token
        self.createdAt = createdAt
        self.expiresAt = expiresAt
        self.usedAt = usedAt
    }

    /// Whether this token would still be accepted.
    public var isUsable: Bool {
        usedAt == nil && expiresAt > Date()
    }
}
