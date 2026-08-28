import Foundation
import SaplingCore

actor GitHubClient {
    private let config: GitHubConfig
    private let tokens: GitHubTokenProvider
    private let session: URLSession

    /// Populated from response headers so `sapling status` can show how much
    /// budget the poll loop is actually consuming.
    public private(set) var rateLimitRemaining: Int?
    /// When the current rate-limit window resets.
    public private(set) var rateLimitResetAt: Date?

    init(config: GitHubConfig) {
        self.config = config
        self.tokens = GitHubTokenProvider(config: config)
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.timeoutIntervalForRequest = 30
        sessionConfig.httpAdditionalHeaders = [
            "Accept": "application/vnd.github+json",
            "X-GitHub-Api-Version": "2022-11-28",
            "User-Agent": "sapling/\(SaplingVersion.current)",
        ]
        self.session = URLSession(configuration: sessionConfig)
    }

    // MARK: - Request plumbing
    //
    // Internal rather than private only so the extensions in the neighbouring
    // files can use them. Everything that talks to GitHub goes through these
    // two, which is what keeps auth retry and rate-limit accounting in one
    // place.

    func request<T: Decodable>(
        _ method: String,
        _ path: String,
        body: [String: Any]? = nil,
        as type: T.Type,
        retryOnAuthFailure: Bool = true
    ) async throws -> T {
        let data = try await requestData(method, path, body: body, retryOnAuthFailure: retryOnAuthFailure)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(T.self, from: data)
    }

    @discardableResult
    func requestData(
        _ method: String,
        _ path: String,
        body: [String: Any]? = nil,
        retryOnAuthFailure: Bool = true
    ) async throws -> Data {
        let token = try await tokens.token()
        guard let url = URL(string: path.hasPrefix("http") ? path : "\(config.apiBaseURL)\(path)") else {
            throw GitHubError(statusCode: -1, message: "bad URL: \(path)")
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw GitHubError(statusCode: -1, message: "no HTTP response")
        }

        if let remaining = http.value(forHTTPHeaderField: "x-ratelimit-remaining") {
            rateLimitRemaining = Int(remaining)
        }
        if let reset = http.value(forHTTPHeaderField: "x-ratelimit-reset"), let epoch = Double(reset) {
            rateLimitResetAt = Date(timeIntervalSince1970: epoch)
        }

        if http.statusCode == 401, retryOnAuthFailure {
            // An installation token can be revoked or invalidated by clock
            // skew; drop the cache and try exactly once more.
            await tokens.invalidate()
            return try await requestData(method, path, body: body, retryOnAuthFailure: false)
        }

        guard (200..<300).contains(http.statusCode) else {
            throw GitHubError(
                statusCode: http.statusCode,
                message: String(decoding: data, as: UTF8.self).prefix(500).description
            )
        }
        return data
    }

    // MARK: - Job discovery

    /// Every job GitHub currently reports as queued for a repo.
    ///
    /// There's no "list queued jobs for a repo" endpoint, so this walks the
    /// runs that could plausibly contain one — `queued` runs, plus
    /// `in_progress` runs, which routinely have later jobs still waiting.
    func queuedJobs(repo: String) async throws -> [WorkflowJob] {
        var runIDs: [Int64] = []
        for status in ["queued", "in_progress"] {
            let response = try await request(
                "GET",
                "/repos/\(repo)/actions/runs?status=\(status)&per_page=50",
                as: WorkflowRunsResponse.self
            )
            runIDs.append(contentsOf: response.workflowRuns.map(\.id))
        }

        var jobs: [WorkflowJob] = []
        for runID in Set(runIDs) {
            let response = try await request(
                "GET",
                "/repos/\(repo)/actions/runs/\(runID)/jobs?per_page=100",
                as: WorkflowJobsResponse.self
            )
            jobs.append(contentsOf: response.jobs.filter(\.isQueued))
        }
        return jobs
    }

    /// Every job in one workflow run.
    ///
    /// Needed before cancelling a run: GitHub has no per-job cancel — the only
    /// endpoint is "cancel this run", which takes every sibling with it. So
    /// the siblings have to be looked at first.
    func jobs(repo: String, runID: Int64) async throws -> [WorkflowJob] {
        try await request(
            "GET",
            "/repos/\(repo)/actions/runs/\(runID)/jobs?per_page=100",
            as: WorkflowJobsResponse.self
        ).jobs
    }

    /// Current state of one job, used to reconcile what actually happened
    /// after a runner exits.
    func job(repo: String, jobID: Int64) async throws -> WorkflowJob {
        try await request("GET", "/repos/\(repo)/actions/jobs/\(jobID)", as: WorkflowJob.self)
    }

    // MARK: - Installation

    /// Every repository this App installation can reach.
    ///
    /// Lets a node leave `github.repos` empty and watch whatever it has been
    /// granted, so adding a repository is done once on GitHub rather than
    /// twice — there and again in the node's config.
    ///
    /// Public repositories are **excluded**. Sapling does not sandbox against
    /// adversarial job code, so a public repo reaching this list by way of an
    /// installation nobody re-read is exactly the accident worth preventing.
    /// A public repo named explicitly in config still runs, with a warning:
    /// naming it is a decision, inheriting it is not.
    func installationRepositories() async throws -> (private: [String], skippedPublic: [String]) {
        var accepted: [String] = []
        var skipped: [String] = []
        var page = 1
        while true {
            let response = try await request(
                "GET",
                "/installation/repositories?per_page=100&page=\(page)",
                as: InstallationRepositoriesResponse.self
            )
            if response.repositories.isEmpty { break }
            for repository in response.repositories {
                if repository.private {
                    accepted.append(repository.fullName)
                } else {
                    skipped.append(repository.fullName)
                }
            }
            guard accepted.count + skipped.count < response.totalCount else { break }
            page += 1
            // GitHub caps pagination; without this a bad total_count loops.
            if page > 20 { break }
        }
        return (accepted, skipped)
    }

    /// Cancel a whole workflow run.
    ///
    /// The bluntest tool GitHub offers, and the only one: there is no endpoint
    /// that cancels a single job, so this stops the run's siblings too. Callers
    /// are expected to have been told to do this explicitly.
    func cancelRun(repo: String, runID: Int64) async throws {
        try await requestData("POST", "/repos/\(repo)/actions/runs/\(runID)/cancel")
    }

    // MARK: - Runner registration

    /// Mint a just-in-time runner config.
    ///
    /// JIT config is preferred over a registration token: the runner is
    /// created already-configured, runs exactly one job, and removes itself,
    /// so there's no separate `config.sh` step and no window where a
    /// half-registered runner is sitting in the repo's runner list.
    func jitConfig(
        repo: String,
        runnerName: String,
        labels: [String],
        runnerGroupID: Int = 1,
        workFolder: String = "_work"
    ) async throws -> String {
        let response = try await request(
            "POST",
            "/repos/\(repo)/actions/runners/generate-jitconfig",
            body: [
                "name": runnerName,
                "runner_group_id": runnerGroupID,
                "labels": labels,
                "work_folder": workFolder,
            ],
            as: JITConfigResponse.self
        )
        return response.encodedJitConfig
    }

    /// Fallback path for runner versions that predate JIT config.
    func registrationToken(repo: String) async throws -> String {
        try await request(
            "POST",
            "/repos/\(repo)/actions/runners/registration-token",
            as: RegistrationTokenResponse.self
        ).token
    }

    func runners(repo: String) async throws -> [SelfHostedRunner] {
        try await request("GET", "/repos/\(repo)/actions/runners?per_page=100", as: RunnersResponse.self)
            .runners
    }

    func deleteRunner(repo: String, runnerID: Int64) async throws {
        try await requestData("DELETE", "/repos/\(repo)/actions/runners/\(runnerID)")
    }

    /// Ephemeral runners normally remove themselves.
    ///
    /// Ones left behind by a crashed VM don't, and they accumulate in the
    /// repo's runner list, so sweep anything offline that we clearly created.
    ///
    /// - Parameters:
    ///   - repo: The repository to sweep.
    ///   - namePrefix: Only runners named with this prefix are ours to delete.
    ///   - inFlight: Runner names this node has just minted and is still
    ///     starting. They have to be spared: a JIT runner that has been created
    ///     but has not connected yet is `offline` and not `busy`, which is
    ///     indistinguishable from a leaked one. Deleting it kills the job — the
    ///     runner gets as far as "Connected to GitHub" and then fails with "the
    ///     runner registration has been deleted from the server". Measured on
    ///     the node: minted at 19:20:39, deleted by this sweep at 19:20:40,
    ///     dead at 19:20:43.
    /// - Returns: How many stale registrations were removed.
    /// - Throws: If the repository's runner list cannot be read.
    @discardableResult
    func pruneOfflineRunners(
        repo: String, namePrefix: String, inFlight: Set<String> = []
    ) async throws -> Int {
        let stale = try await runners(repo: repo).filter {
            $0.name.hasPrefix(namePrefix) && $0.status == "offline" && !$0.busy
                && !inFlight.contains($0.name)
        }
        for runner in stale {
            try? await deleteRunner(repo: repo, runnerID: runner.id)
        }
        return stale.count
    }

    // MARK: - Repo metadata

    /// §8 requires a loud warning if a watched repo is public, because public
    /// repos can accept workflow runs from fork PRs and Sapling explicitly
    /// does not defend against untrusted job code.
    func isPublic(repo: String) async throws -> Bool {
        let response = try await request("GET", "/repos/\(repo)", as: RepositoryResponse.self)
        if let visibility = response.visibility { return visibility == "public" }
        return !response.private
    }

    func currentRateLimit() -> (remaining: Int?, resetAt: Date?) {
        (rateLimitRemaining, rateLimitResetAt)
    }
}
