import Foundation

/// The platform a job runs on.
///
/// Determines which provider the agent uses: `.macos` runs in a Tart VM,
/// `.linux` in an Apple `container`.
public enum JobPlatform: String, Codable, Sendable, CaseIterable {
    /// Runs in an ephemeral macOS VM cloned from the configured base image.
    case macos
    /// Runs in an ephemeral Apple `container`.
    case linux
}

/// Where a job has got to, from the node's point of view.
///
/// This is Sapling's own view, not GitHub's: it tracks the lifecycle of the
/// environment the job runs in. A job's final pass/fail is reconciled against
/// the GitHub API before `completed` or `failed` is recorded.
public enum JobStatus: String, Codable, Sendable, CaseIterable {
    /// Seen on GitHub and eligible for this node, but not yet started.
    case queued
    /// A VM or container is being created for it.
    case provisioning
    /// The runner is attached and working.
    case running
    /// The job finished; its environment is being torn down.
    case cleanup
    /// Finished successfully.
    case completed
    /// Finished unsuccessfully, or could not be run at all.
    case failed
    /// GitHub withdrew the job, so it never ran to a result here.
    ///
    /// Distinct from `failed` because nothing went wrong: counting a
    /// cancellation as a failure is how a healthy node comes to look like a
    /// broken one.
    case cancelled

    /// Whether this state is final.
    ///
    /// Terminal jobs are never rescheduled and never hold a slot.
    public var isTerminal: Bool {
        switch self {
        case .completed, .failed, .cancelled: true
        case .queued, .provisioning, .running, .cleanup: false
        }
    }

    /// Whether a job in this state occupies a concurrency slot on the node.
    public var occupiesSlot: Bool {
        switch self {
        case .provisioning, .running, .cleanup: true
        case .queued, .completed, .failed, .cancelled: false
        }
    }

    /// Whether this node should ever start the job again.
    ///
    /// Every finished job except a cancelled one: a local failure is this
    /// node's problem and worth another attempt, whereas a cancellation is
    /// GitHub's decision and stands. Retrying a cancelled job would clone a VM
    /// for work that has been called off.
    public var isRetryable: Bool {
        isTerminal && self != .cancelled
    }
}

/// Whether a node is available, and if not, why.
public enum NodeStatus: String, Codable, Sendable, CaseIterable {
    /// Running and accepting jobs.
    case online
    /// Not reachable, or the daemon isn't running.
    case offline
    /// Finishing what it started, then stopping. On the way to shutdown.
    case draining
    /// Deliberately paused. Still discovers queued work, but won't take it.
    case cordoned

    /// Whether the node will take on new work.
    ///
    /// Draining and cordoned nodes both refuse; they differ only in intent.
    public var acceptsNewJobs: Bool {
        self == .online
    }
}

/// A Mac that can run jobs.
///
/// v1 only ever has one, but the control plane is shaped for more so that
/// adding a node later is configuration rather than a rewrite.
public struct Node: Codable, Sendable, Identifiable, Hashable {
    /// Stable identifier, derived from the node's name so a restart doesn't
    /// orphan its job history.
    public var id: String
    /// Human-readable name, shown in the CLI and the menu bar app.
    public var name: String
    /// Architecture triple, for example `darwin/arm64`.
    public var platform: String
    /// When the node last reported in. `nil` if it never has.
    public var lastSeenAt: Date?
    /// Current availability.
    public var status: NodeStatus

    /// Creates a node record.
    public init(id: String, name: String, platform: String, lastSeenAt: Date?, status: NodeStatus) {
        self.id = id
        self.name = name
        self.platform = platform
        self.lastSeenAt = lastSeenAt
        self.status = status
    }
}

/// One GitHub Actions job, as Sapling tracks it.
///
/// `id` is GitHub's own job id, which is what makes discovery idempotent: the
/// same queued job seen on every poll cycle maps to one record.
public struct Job: Codable, Sendable, Identifiable, Hashable {
    /// GitHub's job id, as a string.
    public var id: String
    /// The node that claimed it, if any.
    public var nodeID: String?
    /// Repository in `owner/repo` form.
    public var repo: String
    /// The workflow run this job belongs to.
    public var workflowRunID: String?
    /// Which provider runs it.
    public var platform: JobPlatform
    /// The labels the workflow asked for, used to decide eligibility.
    public var labels: [String]
    /// Current lifecycle state.
    public var status: JobStatus
    /// The job's name from the workflow file.
    public var name: String?
    /// When Sapling first saw it queued.
    public var queuedAt: Date?
    /// When provisioning began.
    public var startedAt: Date?
    /// When it reached a terminal state.
    public var completedAt: Date?
    /// Why it ended the way it did, when that isn't obvious from `status`.
    public var exitReason: String?
    /// Image the job actually ran in, once resolved.
    ///
    /// Recorded rather than recomputed so the answer survives a restart and a
    /// later config change — "which image was this built in" has to stay
    /// answerable for a job that already ran.
    public var imageRef: String?
    /// Memory reserved for this job, in GB, once it has been sized.
    ///
    /// Recorded rather than recomputed for the same reason as `imageRef`, and
    /// one more: the scheduler rations memory against it, so a daemon that
    /// restarts mid-job has to know what the survivors are holding. Recomputing
    /// from config would silently change a running job's reservation the moment
    /// somebody edited a default.
    public var memoryGB: Int?

    /// Creates a job record.
    public init(
        id: String,
        nodeID: String? = nil,
        repo: String,
        workflowRunID: String? = nil,
        platform: JobPlatform,
        labels: [String],
        status: JobStatus,
        name: String? = nil,
        queuedAt: Date? = nil,
        startedAt: Date? = nil,
        completedAt: Date? = nil,
        exitReason: String? = nil,
        imageRef: String? = nil,
        memoryGB: Int? = nil
    ) {
        self.id = id
        self.nodeID = nodeID
        self.repo = repo
        self.workflowRunID = workflowRunID
        self.platform = platform
        self.labels = labels
        self.status = status
        self.name = name
        self.queuedAt = queuedAt
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.exitReason = exitReason
        self.imageRef = imageRef
        self.memoryGB = memoryGB
    }

    /// How long the job has been running, or how long it ran.
    ///
    /// Measured to now while the job is still going, so a UI can show a
    /// ticking duration. `nil` before it starts.
    public var duration: TimeInterval? {
        guard let startedAt else { return nil }
        return (completedAt ?? Date()).timeIntervalSince(startedAt)
    }
}

/// One append-only entry in the per-job event log (the `runs` table).
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
