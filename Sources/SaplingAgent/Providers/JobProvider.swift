import Foundation
import SaplingCore

/// Everything a provider needs to run one job to completion.
struct JobRunRequest: Sendable {
    let jobID: String
    let repo: String
    let runnerName: String
    /// Encoded JIT runner configuration from the GitHub API.
    ///
    /// The runner picks up one matching job and exits.
    let jitConfig: String
    let labels: [String]
    /// Container image for Linux jobs; ignored by the macOS provider.
    let image: String?
    let environment: [String: String]
    /// The host cache proxy's settings, or `nil` when caching is off.
    ///
    /// Passed rather than resolved to an address here: which gateway a job
    /// reaches the proxy on depends on which bridge its environment lands on,
    /// which is not knowable until the environment exists. The environment
    /// resolves it — see `CacheEndpoint`.
    let cache: CacheConfig?
    let bootTimeout: Duration
    let jobTimeout: Duration

    init(
        jobID: String,
        repo: String,
        runnerName: String,
        jitConfig: String,
        labels: [String],
        image: String? = nil,
        environment: [String: String] = [:],
        cache: CacheConfig? = nil,
        bootTimeout: Duration = .seconds(300),
        jobTimeout: Duration = .seconds(7200)
    ) {
        self.jobID = jobID
        self.repo = repo
        self.runnerName = runnerName
        self.jitConfig = jitConfig
        self.labels = labels
        self.image = image
        self.environment = environment
        self.cache = cache
        self.bootTimeout = bootTimeout
        self.jobTimeout = jobTimeout
    }
}

struct JobOutcome: Sendable {
    let exitCode: Int32
    let message: String?
    var succeeded: Bool { exitCode == 0 }

    init(exitCode: Int32, message: String? = nil) {
        self.exitCode = exitCode
        self.message = message
    }
}

/// Where a provider reports progress.
///
/// Implemented by the agent against the `runs` table so the log viewer sees
/// events as they happen (§5.1).
protocol EventSink: Sendable {
    func record(_ event: String, detail: String?) async
}

extension EventSink {
    func record(_ event: String) async {
        await record(event, detail: nil)
    }

    /// Free-text log line, chunked so a single huge write doesn't become one
    /// unreadable row.
    func log(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        for line in trimmed.split(separator: "\n", omittingEmptySubsequences: true) {
            await record(RunEventName.log, detail: String(line))
        }
    }
}

protocol JobProvider: Sendable {
    var platform: JobPlatform { get }

    /// Verify the provider's tooling is usable. Called at daemon startup so a
    /// missing `tart` or `container` surfaces immediately rather than as a
    /// mysterious job failure ten minutes later.
    func preflight() async throws

    func run(_ request: JobRunRequest, events: any EventSink) async throws -> JobOutcome

    /// Remove anything this provider leaked in a previous life — VMs or
    /// containers whose daemon died before teardown.
    func reapOrphans() async -> [String]
}

struct ProviderError: Error, LocalizedError, Sendable {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
