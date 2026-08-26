import Foundation

struct WorkflowJob: Decodable, Sendable {
    let id: Int64
    let runId: Int64
    let name: String
    let status: String
    let conclusion: String?
    let labels: [String]
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

struct RepositoryResponse: Decodable {
    let visibility: String?
    let `private`: Bool
}

/// Thin async wrapper over the subset of the GitHub REST API Sapling needs.
