import Foundation

/// A failed API call, whether the request never landed or the daemon
/// returned an error.
public struct ClientError: Error, LocalizedError, Sendable {
    /// HTTP status, or `nil` if the daemon was never reached.
    public let statusCode: Int?
    /// Explanation suitable for showing to a person.
    public let message: String

    /// The message, for `LocalizedError`.
    public var errorDescription: String? { message }

    /// Creates a client error.
    public init(statusCode: Int?, message: String) {
        self.statusCode = statusCode
        self.message = message
    }
}

/// Thin REST client for the control plane (§9).
///
/// No orchestration logic lives here — it only speaks the API.
public struct SaplingClient: Sendable {
    /// The control plane this client talks to.
    public let baseURL: URL
    private let session: URLSession

    /// Creates a client error.
    public init(baseURL: URL, timeout: TimeInterval = 15) {
        self.baseURL = baseURL
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.httpAdditionalHeaders = ["User-Agent": "sapling-client/\(SaplingVersion.current)"]
        self.session = URLSession(configuration: config)
    }

    private func send<T: Decodable>(_ method: String, _ path: String, as type: T.Type) async throws -> T {
        guard let url = URL(string: path, relativeTo: baseURL) else {
            throw ClientError(statusCode: nil, message: "bad path \(path)")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw ClientError(
                statusCode: nil,
                message: """
                    could not reach the Sapling daemon at \(baseURL.absoluteString): \
                    \(error.localizedDescription)
                    """)
        }

        guard let http = response as? HTTPURLResponse else {
            throw ClientError(statusCode: nil, message: "no HTTP response from \(baseURL.absoluteString)")
        }
        guard (200..<300).contains(http.statusCode) else {
            if let apiError = try? SaplingJSON.decoder.decode(APIErrorResponse.self, from: data) {
                throw ClientError(statusCode: http.statusCode, message: apiError.reason)
            }
            throw ClientError(statusCode: http.statusCode, message: "HTTP \(http.statusCode)")
        }
        do {
            return try SaplingJSON.decoder.decode(T.self, from: data)
        } catch {
            throw ClientError(statusCode: http.statusCode, message: "could not decode response: \(error)")
        }
    }

    /// Fetches node health and slot usage.
    public func status() async throws -> StatusResponse {
        try await send("GET", "api/v1/status", as: StatusResponse.self)
    }

    /// Lists known nodes.
    public func nodes() async throws -> [Node] {
        try await send("GET", "api/v1/nodes", as: NodeListResponse.self).nodes
    }

    /// Lists jobs, most recently updated first.
    ///
    /// - Parameters:
    ///   - status: Only jobs in this state, or all jobs when `nil`.
    ///   - limit: Maximum jobs to return. The daemon clamps this.
    /// - Returns: Matching jobs, most recently updated first.
    /// - Throws: `ClientError` if the daemon is unreachable or returns an error.
    public func jobs(status: JobStatus? = nil, limit: Int = 25) async throws -> [Job] {
        var path = "api/v1/jobs?limit=\(limit)"
        if let status { path += "&status=\(status.rawValue)" }
        return try await send("GET", path, as: JobListResponse.self).jobs
    }

    /// Fetches one job together with its full event log.
    public func job(id: String) async throws -> JobDetailResponse {
        try await send("GET", "api/v1/jobs/\(id)", as: JobDetailResponse.self)
    }

    /// Fetches a job's event log.
    ///
    /// - Parameters:
    ///   - jobID: The job whose log to read.
    ///   - after: Return only events newer than this event id, for tailing
    ///     without refetching.
    /// - Returns: The job's events, oldest first.
    /// - Throws: `ClientError` if the daemon is unreachable or returns an error.
    public func logs(jobID: String, after: Int64? = nil) async throws -> LogsResponse {
        var path = "api/v1/jobs/\(jobID)/logs"
        if let after { path += "?after=\(after)" }
        return try await send("GET", path, as: LogsResponse.self)
    }

    /// Asks whether a newer version is available on the node's channel.
    ///
    /// - Returns: What is available, and what is running now.
    /// - Throws: `ClientError` if the daemon is unreachable.
    public func checkForUpdate() async throws -> UpdateCheckResponse {
        try await send("GET", "api/v1/update", as: UpdateCheckResponse.self)
    }

    /// Tells the daemon to install the newest version on its channel.
    ///
    /// The daemon replies before restarting, so the next request will fail
    /// briefly while it comes back.
    ///
    /// - Parameter force: Update even while jobs are running.
    /// - Returns: What is being applied, or why nothing is.
    /// - Throws: `ClientError` if the daemon is unreachable.
    public func applyUpdate(force: Bool = false) async throws -> UpdateApplyResponse {
        try await send("POST", "api/v1/update?force=\(force)", as: UpdateApplyResponse.self)
    }

    /// Requests a single-use token for enrolling another node.
    public func joinToken() async throws -> JoinTokenResponse {
        try await send("POST", "api/v1/nodes/join-token", as: JoinTokenResponse.self)
    }

    /// Stops accepting new jobs, leaving running ones alone.
    public func drain() async throws -> ControlResponse {
        try await send("POST", "api/v1/drain", as: ControlResponse.self)
    }

    /// Pauses job acceptance.
    public func cordon() async throws -> ControlResponse {
        try await send("POST", "api/v1/cordon", as: ControlResponse.self)
    }

    /// Resumes job acceptance.
    public func uncordon() async throws -> ControlResponse {
        try await send("POST", "api/v1/uncordon", as: ControlResponse.self)
    }
}
