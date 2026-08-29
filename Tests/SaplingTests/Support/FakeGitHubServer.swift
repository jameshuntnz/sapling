import Foundation
import Vapor

@testable import SaplingAgent
@testable import SaplingCore

/// Records what the client asked for, so tests can assert on request shape
/// and call counts rather than only on decoded responses.
final class FakeGitHubState: @unchecked Sendable {
    private let lock = NSLock()
    private var _jobsRequests: [Int64] = []
    private var _jitBodies: [[String: Any]] = []
    private var _deletedRunners: [Int64] = []
    private var _cancelledRuns: [Int64] = []
    private var _authAttempts = 0

    var jobsRequests: [Int64] { lock.withLock { _jobsRequests } }
    var jitBodies: [[String: Any]] { lock.withLock { _jitBodies } }
    var deletedRunners: [Int64] { lock.withLock { _deletedRunners } }
    var cancelledRuns: [Int64] { lock.withLock { _cancelledRuns } }
    var authAttempts: Int { lock.withLock { _authAttempts } }

    func recordJobsRequest(_ runID: Int64) { lock.withLock { _jobsRequests.append(runID) } }
    func recordJIT(_ body: [String: Any]) { lock.withLock { _jitBodies.append(body) } }
    func recordDelete(_ id: Int64) { lock.withLock { _deletedRunners.append(id) } }
    func recordCancelledRun(_ id: Int64) { lock.withLock { _cancelledRuns.append(id) } }
    func nextAuthAttempt() -> Int {
        lock.withLock {
            _authAttempts += 1
            return _authAttempts
        }
    }
}

/// Which runs and jobs the fake API should report.
struct FakeGitHubFixtures {
    var queuedRunIDs: [Int64] = [100]
    var inProgressRunIDs: [Int64] = []
    /// Raw `.../runs/:id/jobs` payload per run id.
    var jobsByRun: [Int64: String] = [:]
    /// Raw `.../actions/jobs/:id` payload per job id.
    ///
    /// These are the single-job lookups the agent uses to find out what GitHub
    /// did with a job. Ids absent here answer 404, itself a case worth testing.
    var jobByID: [Int64: String] = [:]
    /// Repos whose run listing should fail, for testing that one unreachable
    /// repo doesn't distort what we believe about the others.
    var failingRepos: Set<String> = []
    /// Runs whose head repository is a fork, in the shape GitHub reports a
    /// pull request opened from one.
    var forkRunIDs: Set<Int64> = []
    /// Runs GitHub reports with a null head repository — what it does when the
    /// fork behind a pull request has since been deleted.
    var runsWithoutHeadRepository: Set<Int64> = []
    /// Runs whose head repository differs from the watched repo only in case.
    var mixedCaseRunIDs: Set<Int64> = []
}

/// A stand-in for the GitHub REST API.
///
/// `github.api_base_url` is configurable precisely so this is possible: the
/// real HTTP stack, the real JSON shapes GitHub returns, and the real retry
/// logic all run, without a token or a network.
struct FakeGitHubServer {
    let app: Application
    let state: FakeGitHubState
    let baseURL: String

    /// Binds an ephemeral port rather than a fixed one.
    ///
    /// Fixed ports collide: a server from a previous test can still hold the
    /// socket when the next one binds, which fails as
    /// `Address already in use` on whichever machine happens to be slower.
    /// Letting the kernel choose removes the whole class of flake.
    static func start(fixtures: FakeGitHubFixtures) async throws -> FakeGitHubServer {
        let state = FakeGitHubState()

        var environment = Environment.testing
        environment.arguments = ["fake-github"]
        let app = try await Application.make(environment)
        app.http.server.configuration.hostname = "127.0.0.1"
        app.http.server.configuration.port = 0
        app.logger.logLevel = .critical

        app.get("repos", ":owner", ":repo", "actions", "runs") { request -> Response in
            let repo =
                "\(request.parameters.get("owner") ?? "")/\(request.parameters.get("repo") ?? "")"
            guard !fixtures.failingRepos.contains(repo) else {
                return Self.json(#"{"message":"Server Error"}"#, status: .internalServerError)
            }
            let status = (try? request.query.get(String.self, at: "status")) ?? ""
            let ids = status == "queued" ? fixtures.queuedRunIDs : fixtures.inProgressRunIDs
            let runs = ids.map { id -> String in
                let provenance: String
                if fixtures.runsWithoutHeadRepository.contains(id) {
                    provenance = #""event":"pull_request","head_repository":null"#
                } else if fixtures.forkRunIDs.contains(id) {
                    // `fork: true` on a head repository that is not the watched
                    // one — the ordinary contributor's pull request.
                    provenance =
                        #""event":"pull_request","head_repository":{"full_name":"outsider/widgets","fork":true}"#
                } else if fixtures.mixedCaseRunIDs.contains(id) {
                    provenance =
                        #""event":"push","head_repository":{"full_name":"\#(repo.uppercased())","fork":false}"#
                } else {
                    provenance =
                        #""event":"push","head_repository":{"full_name":"\#(repo)","fork":false}"#
                }
                return #"{"id":\#(id),"name":"CI","status":"\#(status)","head_branch":"main",\#(provenance)}"#
            }
            return Self.json(#"{"workflow_runs":[\#(runs.joined(separator: ","))]}"#)
        }

        app.get("repos", ":owner", ":repo", "actions", "runs", ":runID", "jobs") { request -> Response in
            // A failing repo fails this endpoint too. Without that, code which
            // is supposed to hold back when GitHub cannot be asked was tested
            // against a GitHub that answered "no jobs" — the opposite of not
            // knowing, and the two lead to opposite decisions.
            let repo =
                "\(request.parameters.get("owner") ?? "")/\(request.parameters.get("repo") ?? "")"
            guard !fixtures.failingRepos.contains(repo) else {
                return Self.json(#"{"message":"Server Error"}"#, status: .internalServerError)
            }
            let runID = Int64(request.parameters.get("runID") ?? "0") ?? 0
            state.recordJobsRequest(runID)
            return Self.json(fixtures.jobsByRun[runID] ?? #"{"jobs":[]}"#)
        }

        app.get("repos", ":owner", ":repo", "actions", "jobs", ":jobID") { request -> Response in
            let jobID = Int64(request.parameters.get("jobID") ?? "") ?? 0
            if let payload = fixtures.jobByID[jobID] {
                return Self.json(payload)
            }
            guard jobID == 9001 else {
                return Self.json(#"{"message":"Not Found"}"#, status: .notFound)
            }
            return Self.json(
                """
                {"id":9001,"run_id":100,"name":"build","status":"completed","conclusion":"success",
                 "labels":["self-hosted","macos"],"started_at":"2026-08-24T10:00:00Z",
                 "completed_at":"2026-08-24T10:05:00Z","runner_name":"sap-macos-abc"}
                """)
        }

        app.post("repos", ":owner", ":repo", "actions", "runs", ":runID", "cancel") { request -> Response in
            state.recordCancelledRun(Int64(request.parameters.get("runID") ?? "0") ?? 0)
            return Response(status: .accepted)
        }

        app.post("repos", ":owner", ":repo", "actions", "runners", "generate-jitconfig") {
            request -> Response in
            if let buffer = request.body.data,
                let object = try? JSONSerialization.jsonObject(with: Data(buffer.readableBytesView))
                    as? [String: Any]
            {
                state.recordJIT(object)
            }
            return Self.json(#"{"encoded_jit_config":"ZmFrZS1qaXQtY29uZmln"}"#)
        }

        app.post("repos", ":owner", ":repo", "actions", "runners", "registration-token") { _ -> Response in
            Self.json(#"{"token":"AABBCC","expires_at":"2026-08-24T11:00:00Z"}"#)
        }

        app.get("repos", ":owner", ":repo", "actions", "runners") { _ -> Response in
            Self.json(
                """
                {"runners":[
                  {"id":1,"name":"sap-macos-dead","status":"offline","busy":false},
                  {"id":2,"name":"sap-linux-live","status":"online","busy":true},
                  {"id":3,"name":"someone-elses-runner","status":"offline","busy":false},
                  {"id":4,"name":"sap-linux-idle-offline","status":"offline","busy":false}
                ]}
                """)
        }

        app.delete("repos", ":owner", ":repo", "actions", "runners", ":runnerID") { request -> Response in
            state.recordDelete(Int64(request.parameters.get("runnerID") ?? "0") ?? 0)
            return Response(status: .noContent)
        }

        // Fails authorization once, then succeeds — the client should retry
        // exactly one time and recover.
        app.get("repos", "flaky", "endpoint") { _ -> Response in
            state.nextAuthAttempt() == 1
                ? Self.json(#"{"message":"Bad credentials"}"#, status: .unauthorized)
                : Self.json(#"{"visibility":"private","private":true}"#)
        }

        app.get("repos", "public-owner", "public-repo") { _ -> Response in
            Self.json(#"{"visibility":"public","private":false}"#)
        }

        app.get("repos", ":owner", ":repo") { _ -> Response in
            Self.json(#"{"visibility":"private","private":true}"#)
        }

        try await app.startup()
        guard let boundPort = app.http.server.shared.localAddress?.port else {
            try? await app.asyncShutdown()
            throw ProviderError("fake GitHub server reported no bound port")
        }
        return FakeGitHubServer(app: app, state: state, baseURL: "http://127.0.0.1:\(boundPort)")
    }

    static func json(_ raw: String, status: HTTPResponseStatus = .ok) -> Response {
        var headers = HTTPHeaders()
        headers.contentType = .json
        // Mirror the rate-limit headers the client reads off every response.
        headers.add(name: "x-ratelimit-remaining", value: "4321")
        headers.add(name: "x-ratelimit-reset", value: "2000000000")
        return Response(status: status, headers: headers, body: .init(string: raw))
    }

    /// A GitHub config pointed at this fake instead of the real API.
    func githubConfig() -> GitHubConfig {
        var config = GitHubConfig()
        config.auth = .pat
        config.token = "ghp_test"
        config.apiBaseURL = baseURL
        config.repos = ["acme/widgets"]
        return config
    }

    func shutdown() async {
        try? await app.asyncShutdown()
    }
}

/// One `.../actions/jobs/:id` payload, in the shape GitHub returns.
func fakeRemoteJob(
    id: Int64, status: String, conclusion: String?, labels: [String] = ["self-hosted", "macos"]
) -> String {
    let quoted = labels.map { #""\#($0)""# }.joined(separator: ",")
    let concluded = conclusion.map { #""\#($0)""# } ?? "null"
    return #"""
        {"id":\#(id),"run_id":100,"name":"build","status":"\#(status)","conclusion":\#(concluded),
         "labels":[\#(quoted)],"started_at":null,"completed_at":null,"runner_name":null}
        """#
}

enum FakeGitHubFixtureLibrary {
    /// Run 100 holds one queued and one already-running job; only the queued
    /// one should ever be picked up.
    static let mixedStatuses = """
        {"jobs":[
          {"id":9001,"run_id":100,"name":"build","status":"queued","conclusion":null,
           "labels":["self-hosted","macos"],"started_at":null,"completed_at":null,"runner_name":null},
          {"id":9002,"run_id":100,"name":"lint","status":"in_progress","conclusion":null,
           "labels":["self-hosted","linux"],"started_at":"2026-08-24T10:00:00Z","completed_at":null,"runner_name":"sap-linux-1"}
        ]}
        """

    static let queuedBehindRunningRun = """
        {"jobs":[
          {"id":9003,"run_id":200,"name":"test","status":"queued","conclusion":null,
           "labels":["self-hosted","linux","arm64"],"started_at":null,"completed_at":null,"runner_name":null}
        ]}
        """

    /// One job for each platform, plus one this node can never run.
    static let threePlatforms = """
        {"jobs":[
          {"id":9001,"run_id":100,"name":"build","status":"queued","conclusion":null,
           "labels":["self-hosted","macos"],"started_at":null,"completed_at":null,"runner_name":null},
          {"id":9002,"run_id":100,"name":"test","status":"queued","conclusion":null,
           "labels":["self-hosted","linux"],"started_at":null,"completed_at":null,"runner_name":null},
          {"id":9003,"run_id":100,"name":"windows","status":"queued","conclusion":null,
           "labels":["self-hosted","windows"],"started_at":null,"completed_at":null,"runner_name":null}
        ]}
        """
}
