import Foundation
import SaplingCore

/// Asking GitHub how a job ended, once this node's runner has exited.
extension NodeAgent {
    /// What GitHub says became of a job.
    enum RemoteConclusion: Equatable {
        case success
        /// GitHub finished the job, with this conclusion.
        case concluded(String)
        /// GitHub still has the job waiting for a runner, so whatever our
        /// runner did, it wasn't this.
        case stillQueued
        /// No answer: GitHub unreachable, or the job never concluded.
        case unknown
    }

    /// Ask GitHub how the job ended, allowing for its result lagging slightly
    /// behind the runner exiting.
    ///
    /// GitHub is the authority for two separate reasons. A JIT runner picks up
    /// whichever queued job matches its labels, not necessarily the one that
    /// prompted the launch — so the exit code describes the runner, not this
    /// job. And a runner can exit cleanly without doing any work at all, which
    /// an exit code cannot distinguish from success.
    /// - Parameters:
    ///   - job: The job to ask about.
    ///   - runnerRan: The job name our runner announced, if it announced one.
    ///     When it matches this job, a `queued` answer is treated as GitHub
    ///     lagging rather than as a hand-off.
    ///   - attempts: How many times to ask before giving up.
    ///   - retryDelay: Gap between attempts.
    ///   - grace: Extra time allowed while GitHub's answer looks stale — the
    ///     job still *in progress*, or still queued after our runner said it
    ///     ran it. Defaults to none when `retryDelay` is zero, so a test asking
    ///     once still asks once.
    /// - Returns: What GitHub says became of the job.
    func remoteConclusion(
        for job: Job,
        runnerRan: String? = nil,
        attempts: Int? = nil,
        retryDelay: Duration? = nil,
        grace: Duration? = nil
    ) async -> RemoteConclusion {
        let attempts = attempts ?? conclusionAttempts
        let retryDelay = retryDelay ?? conclusionRetryDelay
        let grace = grace ?? (retryDelay == .zero ? .zero : Self.inProgressGrace)
        guard let jobID = Int64(job.id) else { return .unknown }

        // A short job can go queued → running → completed faster than GitHub's
        // job endpoint catches up: one ran 19:34:30–19:34:43 and was still
        // reported `queued` twelve seconds after its runner exited. Our runner
        // naming this very job is what tells that apart from a hand-off. A
        // different name is a real hand-off and is returned promptly; a
        // same-named sibling only costs the wait, never a wrong answer.
        let queuedMayBeStale = runnerRan != nil && runnerRan == job.name

        let started = ContinuousClock.now
        var lastSeenQueued = false
        var lastSeenRunning = false
        var attempt = 0

        while true {
            if attempt > 0 {
                try? await Task.sleep(for: retryDelay)
            }
            attempt += 1

            if let remote = try? await github.job(repo: job.repo, jobID: jobID) {
                if remote.isCompleted {
                    switch remote.conclusion {
                    case "success": return .success
                    case let conclusion?: return .concluded(conclusion)
                    case nil: return .unknown
                    }
                }
                // Still waiting for a runner after our runner has exited means
                // our runner ran something else. Still *running* means the
                // opposite — GitHub has it, and simply hasn't finished with it.
                lastSeenQueued = remote.isQueued
                lastSeenRunning = !remote.isQueued
            }

            if attempt >= attempts {
                // The base attempts cover GitHub lagging a second or two behind
                // a runner exiting. This covers something else: the runner has
                // exited and the job is still finishing on GitHub's side, with
                // post-steps and log upload to go. Fifteen seconds did not
                // cover it — an iOS job GitHub concluded as `failure`, and a
                // release that published successfully, were both recorded here
                // as "runner exited without the job completing". Those are the
                // failures that make a working node look broken.
                let looksStale = lastSeenRunning || (lastSeenQueued && queuedMayBeStale)
                guard looksStale, ContinuousClock.now - started < grace else { break }
            }
        }
        return lastSeenQueued ? .stillQueued : .unknown
    }
}
