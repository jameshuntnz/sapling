import Foundation

struct WorkflowJob: Decodable, Sendable {
    let id: Int64
    let runId: Int64
    let name: String
    let status: String
    let conclusion: String?
    let labels: [String]
    /// Commit the job will check out — and the commit its image is built from,
    /// so an image can never drift from the code that needs it.
    let headSha: String?
    let startedAt: Date?
    let completedAt: Date?
    let runnerName: String?

    var isQueued: Bool { status == "queued" }
    var isCompleted: Bool { status == "completed" }
}

struct WorkflowJobsResponse: Decodable {
    let jobs: [WorkflowJob]
}

struct WorkflowRun: Decodable {
    let id: Int64
    let name: String?
    let status: String?
}

struct WorkflowRunsResponse: Decodable {
    let workflowRuns: [WorkflowRun]
}

struct SelfHostedRunner: Decodable, Sendable {
    let id: Int64
    let name: String
    let status: String
    let busy: Bool
}

struct RunnersResponse: Decodable {
    let runners: [SelfHostedRunner]
}

struct JITConfigResponse: Decodable {
    let encodedJitConfig: String
}

struct RegistrationTokenResponse: Decodable {
    let token: String
    let expiresAt: Date
}

/// One entry from the repository contents API.
struct ContentEntry: Decodable, Sendable {
    let name: String
    let path: String
    /// `file`, `dir`, `symlink` or `submodule`.
    let type: String
    /// Blob SHA for a file; **tree** SHA for a directory — which is what makes
    /// this the whole cache key for an image directory.
    let sha: String
}

/// One entry from the git trees API.
struct GitTreeEntry: Decodable, Sendable {
    let path: String
    /// `blob` or `tree`.
    let type: String
    let sha: String
    let mode: String
    let size: Int?
}

struct GitTreeResponse: Decodable, Sendable {
    let sha: String
    let tree: [GitTreeEntry]
    /// Set when the tree exceeded GitHub's response limit.
    let truncated: Bool?
}

struct GitBlobResponse: Decodable, Sendable {
    let content: String
    let encoding: String
}

struct RepositoryResponse: Decodable {
    let visibility: String?
    let `private`: Bool
}

/// Thin async wrapper over the subset of the GitHub REST API Sapling needs.
