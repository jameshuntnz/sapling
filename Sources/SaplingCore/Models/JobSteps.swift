import Foundation

/// One step of a job, as GitHub reports it on the job's page.
public struct JobStep: Codable, Sendable, Hashable, Identifiable {
    /// Where a step has got to, folded from GitHub's status and conclusion.
    public enum State: String, Codable, Sendable {
        /// Not started yet.
        case pending
        /// Running now.
        case running
        /// Finished successfully.
        case succeeded
        /// Finished and failed the job.
        case failed
        /// Skipped by an `if:` or an earlier failure.
        case skipped
        /// Cancelled before it finished.
        case cancelled
    }

    /// The step's position in the job, from 1.
    public var number: Int
    /// The step's name as the workflow gives it.
    public var name: String
    /// `queued`, `in_progress` or `completed`.
    public var status: String
    /// `success`, `failure`, `skipped`, `cancelled` and so on, once completed.
    public var conclusion: String?
    /// When the step started.
    public var startedAt: Date?
    /// When the step finished.
    public var completedAt: Date?

    /// Identifies the step within its job.
    public var id: Int { number }

    /// Creates a step.
    public init(
        number: Int, name: String, status: String, conclusion: String? = nil,
        startedAt: Date? = nil, completedAt: Date? = nil
    ) {
        self.number = number
        self.name = name
        self.status = status
        self.conclusion = conclusion
        self.startedAt = startedAt
        self.completedAt = completedAt
    }

    /// The step's state, for drawing.
    public var state: State {
        switch status {
        case "completed":
            switch conclusion {
            case "success", "neutral": return .succeeded
            case "skipped": return .skipped
            case "cancelled": return .cancelled
            default: return .failed
            }
        case "in_progress": return .running
        default: return .pending
        }
    }

    /// How long the step took, or has taken so far.
    ///
    /// - Parameter now: The time to measure a running step against.
    /// - Returns: The duration, or `nil` if the step has not started.
    public func duration(now: Date = Date()) -> TimeInterval? {
        guard let startedAt else { return nil }
        return (completedAt ?? now).timeIntervalSince(startedAt)
    }
}

/// Response body for `GET /api/v1/jobs/:id/steps`.
public struct JobStepsResponse: Codable, Sendable {
    /// The job asked about.
    public var jobID: String
    /// The job's steps in order, empty until GitHub assigns the job a runner.
    public var steps: [JobStep]
    /// Why there are no steps to show, when the node could not ask GitHub.
    public var unavailableReason: String?

    /// Creates a steps response.
    public init(jobID: String, steps: [JobStep] = [], unavailableReason: String? = nil) {
        self.jobID = jobID
        self.steps = steps
        self.unavailableReason = unavailableReason
    }

    /// Whether every step has finished, so asking again would change nothing.
    public var isSettled: Bool {
        !steps.isEmpty && steps.allSatisfy { $0.status == "completed" }
    }
}
