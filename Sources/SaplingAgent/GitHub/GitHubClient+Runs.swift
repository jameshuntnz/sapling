import Foundation
import SaplingCore

/// Finding queued work on GitHub, and refusing the runs that are not ours.
///
/// Split from `GitHubClient` because the provenance check belongs at the run
/// level, before a run's jobs are ever fetched — see `queuedWork(repo:)`.
extension GitHubClient {
    /// A workflow run this node will not look inside, and why.
    struct RefusedRun: Sendable, Equatable {
        /// GitHub's run id.
        let id: Int64
        /// A sentence naming what was refused, fit for a log line.
        let reason: String
    }

    /// What a poll of one repository found.
    struct QueuedWork: Sendable {
        /// Queued jobs from runs whose code came from the watched repository.
        let jobs: [WorkflowJob]
        /// Runs skipped on provenance, so the caller can say so once.
        let refusedRuns: [RefusedRun]
    }

    /// Every job GitHub currently reports as queued for a repo, minus anything
    /// that did not come from that repo.
    ///
    /// There's no "list queued jobs for a repo" endpoint, so this walks the
    /// runs that could plausibly contain one — `queued` runs, plus
    /// `in_progress` runs, which routinely have later jobs still waiting.
    ///
    /// `ForkPolicy` is applied to each run **before** its jobs are fetched, for
    /// two reasons. Provenance is a property of the run, so nothing is learned
    /// by asking about its jobs; and a job that never enters the pipeline can
    /// never reach `RunnerImageBuilder`, which reads a repository's image
    /// definitions at the job's own commit and builds them on the node, outside
    /// any container. Refusing later than this would mean a fork's Dockerfile
    /// had already run. It also saves one request per fork pull request, which
    /// is the difference between a busy public repository being pollable and
    /// not.
    func queuedWork(repo: String) async throws -> QueuedWork {
        var runs: [Int64: WorkflowRun] = [:]
        for status in ["queued", "in_progress"] {
            let response = try await request(
                "GET",
                "/repos/\(repo)/actions/runs?status=\(status)&per_page=50",
                as: WorkflowRunsResponse.self
            )
            for run in response.workflowRuns { runs[run.id] = run }
        }

        var jobs: [WorkflowJob] = []
        var refused: [RefusedRun] = []
        for run in runs.values.sorted(by: { $0.id < $1.id }) {
            let origin = ForkPolicy.origin(
                headRepositoryFullName: run.headRepository?.fullName,
                watchedRepo: repo,
                event: run.event)
            if case .foreign(let reason) = origin {
                refused.append(RefusedRun(id: run.id, reason: reason))
                continue
            }
            let response = try await request(
                "GET",
                "/repos/\(repo)/actions/runs/\(run.id)/jobs?per_page=100",
                as: WorkflowJobsResponse.self
            )
            jobs.append(contentsOf: response.jobs.filter(\.isQueued))
        }
        return QueuedWork(jobs: jobs, refusedRuns: refused)
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
}
