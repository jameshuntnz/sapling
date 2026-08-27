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

    private func request<T: Decodable>(
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
    private func requestData(
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

    /// Current state of one job, used to reconcile what actually happened
    /// after a runner exits.
    func job(repo: String, jobID: Int64) async throws -> WorkflowJob {
        try await request("GET", "/repos/\(repo)/actions/jobs/\(jobID)", as: WorkflowJob.self)
    }

    // MARK: - Repository contents

    /// Tree SHA of one directory at a commit, or `nil` if it isn't there.
    ///
    /// This is the whole fast path for repository-defined images: git already
    /// hashes a directory's exact contents, so one call answers "has this
    /// image definition changed" without fetching a byte of it. A cache hit
    /// costs exactly this request.
    func directoryTreeSHA(repo: String, path: String, ref: String) async throws -> String? {
        let parent = (path as NSString).deletingLastPathComponent
        let name = (path as NSString).lastPathComponent
        let encoded =
            parent.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? parent
        let entries: [ContentEntry]
        do {
            entries = try await request(
                "GET", "/repos/\(repo)/contents/\(encoded)?ref=\(ref)", as: [ContentEntry].self)
        } catch let error as GitHubError where error.statusCode == 404 {
            return nil
        }
        return entries.first { $0.name == name && $0.type == "dir" }?.sha
    }

    /// Every file in a tree, as path/bytes pairs.
    ///
    /// Only called on a cache miss. Symlinks and submodules are skipped rather
    /// than followed — a build context is files, and following either would
    /// reach outside the directory the workflow named.
    func treeFiles(repo: String, treeSHA: String) async throws -> [(path: String, data: Data)] {
        let tree = try await request(
            "GET", "/repos/\(repo)/git/trees/\(treeSHA)?recursive=1", as: GitTreeResponse.self)
        if tree.truncated == true {
            throw ProviderError(
                "image directory is too large for one tree response; keep build contexts small")
        }

        var files: [(path: String, data: Data)] = []
        for entry in tree.tree where entry.type == "blob" {
            // 120000 is a symlink; anything else non-regular is skipped too.
            guard entry.mode == "100644" || entry.mode == "100755" else { continue }
            let blob = try await request(
                "GET", "/repos/\(repo)/git/blobs/\(entry.sha)", as: GitBlobResponse.self)
            guard blob.encoding == "base64",
                let data = Data(base64Encoded: blob.content, options: .ignoreUnknownCharacters)
            else {
                throw ProviderError("unexpected blob encoding \(blob.encoding) for \(entry.path)")
            }
            files.append((entry.path, data))
        }
        return files
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
    /// Ones left behind by a crashed VM don't, and they accumulate in the repo's
    /// runner list, so sweep anything offline that we clearly created.
    @discardableResult
    func pruneOfflineRunners(repo: String, namePrefix: String) async throws -> Int {
        let stale = try await runners(repo: repo).filter {
            $0.name.hasPrefix(namePrefix) && $0.status == "offline" && !$0.busy
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
