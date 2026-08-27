import Foundation

/// Slot accounting for one platform.
///
/// `capacity` for macOS is hard-capped at 2 by Apple's virtualization
/// licensing and is not configurable upward.
public struct SlotUsage: Codable, Sendable, Hashable {
    /// Which platform these slots belong to.
    public var platform: JobPlatform
    /// How many slots currently hold a job.
    public var inUse: Int
    /// How many slots exist, after clamping to any hard limit.
    public var capacity: Int

    /// Creates a slot usage summary.
    public init(platform: JobPlatform, inUse: Int, capacity: Int) {
        self.platform = platform
        self.inUse = inUse
        self.capacity = capacity
    }

    /// Free slots, never negative.
    ///
    /// Clamped so a stale count can't report phantom capacity.
    public var available: Int { max(0, capacity - inUse) }
}

/// Response body for `GET /api/v1/status`.
public struct StatusResponse: Codable, Sendable {
    /// Daemon version, so a client can spot a version mismatch.
    public var version: String
    /// The node this control plane manages.
    public var node: Node
    /// Slot usage, one entry per platform.
    public var slots: [SlotUsage]
    /// Jobs discovered but not yet started.
    public var queuedJobs: Int
    /// Jobs currently holding a slot.
    public var runningJobs: Int
    /// Jobs that finished successfully in the last 24 hours.
    public var completedLast24h: Int
    /// Jobs that failed in the last 24 hours.
    public var failedLast24h: Int
    /// Repositories being polled, in `owner/repo` form.
    public var watchedRepos: [String]
    /// When GitHub was last polled successfully.
    public var lastPollAt: Date?
    /// Why the last poll failed, if it did.
    public var lastPollError: String?
    /// What the hardware is doing, when the node is reporting it.
    public var metrics: NodeMetrics?

    /// Creates a status summary.
    public init(
        version: String,
        node: Node,
        slots: [SlotUsage],
        queuedJobs: Int,
        runningJobs: Int,
        completedLast24h: Int,
        failedLast24h: Int,
        watchedRepos: [String],
        lastPollAt: Date?,
        lastPollError: String?,
        metrics: NodeMetrics? = nil
    ) {
        self.version = version
        self.node = node
        self.slots = slots
        self.queuedJobs = queuedJobs
        self.runningJobs = runningJobs
        self.completedLast24h = completedLast24h
        self.failedLast24h = failedLast24h
        self.watchedRepos = watchedRepos
        self.lastPollAt = lastPollAt
        self.lastPollError = lastPollError
        self.metrics = metrics
    }
}

/// Response body for `GET /api/v1/jobs/:id`.
public struct JobDetailResponse: Codable, Sendable {
    /// The job itself.
    public var job: Job
    /// Its full event log, oldest first.
    public var events: [RunEvent]

    /// Creates a job detail response.
    public init(job: Job, events: [RunEvent]) {
        self.job = job
        self.events = events
    }
}

/// Response body for `GET /api/v1/jobs`.
public struct JobListResponse: Codable, Sendable {
    /// Matching jobs, most recently updated first.
    public var jobs: [Job]

    /// Creates a job list response.
    public init(jobs: [Job]) { self.jobs = jobs }
}

/// Response body for `GET /api/v1/nodes`.
public struct NodeListResponse: Codable, Sendable {
    /// Known nodes, ordered by name.
    public var nodes: [Node]

    /// Creates a node list response.
    public init(nodes: [Node]) { self.nodes = nodes }
}

/// Response body for `GET /api/v1/jobs/:id/logs`.
public struct LogsResponse: Codable, Sendable {
    /// The job these events belong to.
    public var jobID: String
    /// Events, oldest first, starting after any requested offset.
    public var events: [RunEvent]

    /// Creates a log response.
    public init(jobID: String, events: [RunEvent]) {
        self.jobID = jobID
        self.events = events
    }
}

/// Response body for `POST /api/v1/nodes/join-token`.
public struct JoinTokenResponse: Codable, Sendable {
    /// The single-use enrollment token.
    public var token: String
    /// When the token stops being accepted.
    public var expiresAt: Date
    /// The control plane URL the new node should point at.
    public var controlPlaneURL: String

    /// Creates an enrollment token response.
    public init(token: String, expiresAt: Date, controlPlaneURL: String) {
        self.token = token
        self.expiresAt = expiresAt
        self.controlPlaneURL = controlPlaneURL
    }
}

/// Response body for the drain, cordon, and uncordon endpoints.
public struct ControlResponse: Codable, Sendable {
    /// The node's status after the change.
    public var status: NodeStatus
    /// A human-readable summary of what happened.
    public var message: String

    /// Creates a control response.
    public init(status: NodeStatus, message: String) {
        self.status = status
        self.message = message
    }
}

/// Response body for `GET /api/v1/update`.
public struct UpdateCheckResponse: Codable, Sendable {
    /// The version running now.
    public var current: String
    /// Which release stream this node follows.
    public var channel: ReleaseChannel
    /// The version available, or `nil` when the node is current.
    public var available: String?
    /// That version's release tag.
    public var tag: String?
    /// When it was published.
    public var publishedAt: Date?
    /// Why the check failed, when it did.
    public var error: String?

    /// Creates an update check result.
    public init(
        current: String,
        channel: ReleaseChannel,
        available: String? = nil,
        tag: String? = nil,
        publishedAt: Date? = nil,
        error: String? = nil
    ) {
        self.current = current
        self.channel = channel
        self.available = available
        self.tag = tag
        self.publishedAt = publishedAt
        self.error = error
    }
}

/// Response body for `POST /api/v1/update`.
///
/// Applying an update restarts the daemon, so a successful response is sent
/// before the restart and the connection then drops. That is expected.
public struct UpdateApplyResponse: Codable, Sendable {
    /// Whether the update was accepted and is being applied.
    public var applying: Bool
    /// The version being installed, when one is.
    public var version: String?
    /// What happened, phrased for a person.
    public var message: String

    /// Creates an update apply result.
    public init(applying: Bool, version: String? = nil, message: String) {
        self.applying = applying
        self.version = version
        self.message = message
    }
}

/// The body returned for any non-2xx API response.
///
/// Errors use the same JSON shape as everything else so clients never have to
/// parse an HTML error page.
public struct APIErrorResponse: Codable, Sendable, Error {
    /// Machine-readable error code, for example `not_found`.
    public var error: String
    /// Human-readable explanation.
    public var reason: String

    /// Creates an error body.
    public init(error: String, reason: String) {
        self.error = error
        self.reason = reason
    }
}

/// JSON coding shared by the server and both clients.
///
/// Centralised so date handling can never drift between the daemon that
/// encodes a response and the CLI or menu bar app that decodes it.
public enum SaplingJSON {
    /// Encoder used for every API response and stored payload.
    public static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return encoder
    }

    /// Decoder matching `encoder`.
    public static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

/// The version this build reports.
public enum SaplingVersion {
    /// Semantic version string, surfaced by `--version` and `GET /status`.
    ///
    /// A development placeholder, replaced by the release pipeline when a
    /// version is cut. It sorts below every published release deliberately:
    /// a locally-built binary must never look newer than a real one, or a node
    /// running a working build refuses every update as a downgrade. The first
    /// attempt used "0.1.0", which is a *stable* version, so every
    /// `0.1.0-dev.N` release read as older and the node sat there reporting
    /// itself up to date.
    public static let current = "0.1.0"
}
