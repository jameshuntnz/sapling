import Foundation
import GRDB
import SaplingCore

/// Storage-layer mirrors of the §6 schema.
///
/// These are deliberately separate from the `SaplingCore` models: the core
/// models are the wire format shared with the CLI and menu bar app, and
/// letting the database schema and the API contract drift independently is
/// worth a little conversion boilerplate.

struct NodeRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "nodes"

    var id: String
    var name: String
    var platform: String
    var lastSeenAt: Date?
    var status: String

    enum CodingKeys: String, CodingKey {
        case id, name, platform, status
        case lastSeenAt = "last_seen_at"
    }

    init(_ node: Node) {
        id = node.id
        name = node.name
        platform = node.platform
        lastSeenAt = node.lastSeenAt
        status = node.status.rawValue
    }

    var model: Node {
        Node(
            id: id,
            name: name,
            platform: platform,
            lastSeenAt: lastSeenAt,
            status: NodeStatus(rawValue: status) ?? .offline
        )
    }
}

struct JobRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "jobs"

    var id: String
    var nodeId: String?
    var repo: String
    var workflowRunId: String?
    var platform: String
    /// JSON array — the schema in §6 stores labels as a JSON string rather
    /// than a join table, since nothing ever queries by individual label.
    var labels: String
    var status: String
    var name: String?
    var queuedAt: Date?
    var startedAt: Date?
    var completedAt: Date?
    var exitReason: String?
    var imageRef: String?
    var memoryGB: Int?
    var updatedAt: Date
    /// How many times this node has started the job, counting from one.
    ///
    /// One past the ceiling means this node gave up, which is what stops the
    /// poll loop reporting the same exhaustion on every cycle. Storage-only:
    /// the API contract has no need for it, but requeueing without it has no
    /// way to stop.
    var attempts: Int

    enum CodingKeys: String, CodingKey {
        case id, repo, platform, labels, status, name, attempts
        case imageRef = "image_ref"
        case memoryGB = "memory_gb"
        case nodeId = "node_id"
        case workflowRunId = "workflow_run_id"
        case queuedAt = "queued_at"
        case startedAt = "started_at"
        case completedAt = "completed_at"
        case exitReason = "exit_reason"
        case updatedAt = "updated_at"
    }

    init(_ job: Job, updatedAt: Date = Date(), attempts: Int = 0) {
        id = job.id
        nodeId = job.nodeID
        repo = job.repo
        workflowRunId = job.workflowRunID
        platform = job.platform.rawValue
        labels = Self.encodeLabels(job.labels)
        status = job.status.rawValue
        name = job.name
        queuedAt = job.queuedAt
        startedAt = job.startedAt
        completedAt = job.completedAt
        exitReason = job.exitReason
        imageRef = job.imageRef
        memoryGB = job.memoryGB
        self.updatedAt = updatedAt
        self.attempts = attempts
    }

    var model: Job {
        Job(
            id: id,
            nodeID: nodeId,
            repo: repo,
            workflowRunID: workflowRunId,
            platform: JobPlatform(rawValue: platform) ?? .linux,
            labels: Self.decodeLabels(labels),
            status: JobStatus(rawValue: status) ?? .failed,
            name: name,
            queuedAt: queuedAt,
            startedAt: startedAt,
            completedAt: completedAt,
            exitReason: exitReason,
            imageRef: imageRef,
            memoryGB: memoryGB
        )
    }

    static func encodeLabels(_ labels: [String]) -> String {
        guard let data = try? JSONEncoder().encode(labels) else { return "[]" }
        return String(decoding: data, as: UTF8.self)
    }

    static func decodeLabels(_ raw: String) -> [String] {
        (try? JSONDecoder().decode([String].self, from: Data(raw.utf8))) ?? []
    }
}

struct RunEventRecord: Codable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "runs"

    var id: Int64?
    var jobId: String
    var ts: Date
    var event: String
    var detail: String?

    enum CodingKeys: String, CodingKey {
        case id, ts, event, detail
        case jobId = "job_id"
    }

    init(_ event: RunEvent) {
        id = event.id
        jobId = event.jobID
        ts = event.ts
        self.event = event.event
        detail = event.detail
    }

    var model: RunEvent {
        RunEvent(id: id, jobID: jobId, ts: ts, event: event, detail: detail)
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

struct JoinTokenRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "join_tokens"

    var token: String
    var createdAt: Date
    var expiresAt: Date
    var usedAt: Date?

    enum CodingKeys: String, CodingKey {
        case token
        case createdAt = "created_at"
        case expiresAt = "expires_at"
        case usedAt = "used_at"
    }

    init(_ token: JoinToken) {
        self.token = token.token
        createdAt = token.createdAt
        expiresAt = token.expiresAt
        usedAt = token.usedAt
    }

    var model: JoinToken {
        JoinToken(token: token, createdAt: createdAt, expiresAt: expiresAt, usedAt: usedAt)
    }
}

/// Small key/value table for daemon state that outlives a restart but doesn't
/// deserve a table of its own (last poll time, last poll error).
struct StateRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "daemon_state"

    var key: String
    var value: String
    var updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case key, value
        case updatedAt = "updated_at"
    }
}
