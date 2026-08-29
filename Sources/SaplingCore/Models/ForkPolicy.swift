import Foundation

/// Where the code in a workflow run came from.
public enum RunOrigin: Sendable, Equatable {
    /// The run's head commit lives on the watched repository itself, so its
    /// code is as trusted as push access to that repository.
    case sameRepository
    /// The code came from somewhere else, or from somewhere that could not be
    /// proven to be the watched repository. Carries a reason fit for a log.
    case foreign(reason: String)

    /// Whether this node may run the jobs in the run.
    public var isRunnable: Bool { self == .sameRepository }
}

/// Whether a workflow run's code originated in the repository being watched.
///
/// Sapling runs job code directly on the machine and does not sandbox against
/// an adversary, so the only defensible admission rule is that the code came
/// from the repository an operator pointed the node at. Anything else — a
/// fork's pull request, a run whose provenance GitHub did not report — is
/// refused, whether the repository is public or private.
///
/// It is unconditional and has no configuration switch on purpose. There is no
/// setting that would make running a stranger's code on an unsandboxed node
/// safe, so there is no setting.
public enum ForkPolicy {
    /// Decides whether a run's code came from the watched repository.
    ///
    /// The test is the head repository's **full name**, not GitHub's
    /// `head_repository.fork` flag. That flag says the head repository is
    /// itself a fork of something, which is true of every branch push in a
    /// repository you maintain as a fork of an upstream project — trusting it
    /// would refuse that repository's own commits. Identity is the question
    /// actually being asked: did this code come from the repository I was told
    /// to watch?
    ///
    /// Comparing names also covers `pull_request_target`, `workflow_run` and
    /// `issue_comment` triggers without naming any of them: for all of them, a
    /// run that originates in a fork reports the fork as its head repository.
    ///
    /// Unknown provenance is refused rather than admitted. GitHub reports a
    /// null head repository when the fork behind a pull request has been
    /// deleted, and "the field was missing" is not evidence of anything.
    ///
    /// - Parameters:
    ///   - headRepositoryFullName: `head_repository.full_name` from the run,
    ///     in `owner/repo` form, or `nil` if GitHub did not report one.
    ///   - watchedRepo: The repository this node is polling, `owner/repo`.
    ///   - event: The run's triggering event, used only to say why in the log.
    /// - Returns: `.sameRepository` only on a positive match.
    public static func origin(
        headRepositoryFullName: String?,
        watchedRepo: String,
        event: String? = nil
    ) -> RunOrigin {
        let trigger = event.map { " (\($0))" } ?? ""
        guard let head = headRepositoryFullName, !head.isEmpty else {
            return .foreign(
                reason:
                    "GitHub reported no head repository for this run\(trigger) — the fork behind it "
                    + "may have been deleted. Refusing rather than guessing at where the code came from"
            )
        }
        guard head.compare(watchedRepo, options: .caseInsensitive) == .orderedSame else {
            return .foreign(
                reason:
                    "its code comes from \(head)\(trigger), not \(watchedRepo). Sapling does not "
                    + "sandbox against adversarial job code, so it only runs commits from the "
                    + "repository it watches"
            )
        }
        return .sameRepository
    }
}
