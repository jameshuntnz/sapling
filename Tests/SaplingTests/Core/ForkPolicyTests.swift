import Foundation
import Testing

@testable import SaplingCore

/// Where a workflow run's code came from, which is the whole admission rule.
///
/// Sapling runs job code unsandboxed, so the only defensible test is that the
/// code came from the repository an operator pointed the node at. These pin
/// the two ways that test could be got wrong: trusting GitHub's `fork` flag
/// instead of the head repository's name, and treating missing provenance as
/// permission.
@Suite("Fork policy")
struct ForkPolicyTests {
    @Test("admits a run whose head commit is on the watched repository")
    func sameRepository() {
        #expect(
            ForkPolicy.origin(
                headRepositoryFullName: "acme/widgets",
                watchedRepo: "acme/widgets",
                event: "push") == .sameRepository)
    }

    @Test("refuses a run whose code came from a fork")
    func forkPullRequest() {
        let origin = ForkPolicy.origin(
            headRepositoryFullName: "outsider/widgets",
            watchedRepo: "acme/widgets",
            event: "pull_request")
        #expect(!origin.isRunnable)
        guard case .foreign(let reason) = origin else {
            Issue.record("expected a refusal")
            return
        }
        // The reason has to name both repositories: "refused a fork" in a log
        // three days later says nothing about which fork, or of what.
        #expect(reason.contains("outsider/widgets"))
        #expect(reason.contains("acme/widgets"))
    }

    /// The trigger most often reached for to "give forks secrets".
    ///
    /// `pull_request_target` runs the base repository's workflow with the
    /// fork's pull request in context. It needs no special case: GitHub still
    /// reports the fork as the head repository, so the name test catches it.
    @Test("refuses pull_request_target from a fork without naming the trigger")
    func pullRequestTarget() {
        #expect(
            !ForkPolicy.origin(
                headRepositoryFullName: "outsider/widgets",
                watchedRepo: "acme/widgets",
                event: "pull_request_target"
            ).isRunnable)
    }

    /// The case this design turns on.
    ///
    /// A repository you maintain as a fork of an upstream project reports
    /// `head_repository.fork == true` on its own branch pushes, so a policy
    /// written against that flag would refuse every commit in it. Identity is
    /// the question; ancestry is not.
    @Test("admits a repository that is itself a fork, pushing its own branch")
    func watchedRepoIsItselfAFork() {
        #expect(
            ForkPolicy.origin(
                headRepositoryFullName: "acme/upstream-fork",
                watchedRepo: "acme/upstream-fork",
                event: "push") == .sameRepository)
    }

    /// Absence of evidence is not evidence of provenance.
    ///
    /// GitHub reports a null head repository when the fork behind a pull
    /// request has been deleted.
    @Test("refuses a run with no head repository at all")
    func missingHeadRepository() {
        #expect(
            !ForkPolicy.origin(
                headRepositoryFullName: nil,
                watchedRepo: "acme/widgets",
                event: "pull_request"
            ).isRunnable)
        #expect(
            !ForkPolicy.origin(
                headRepositoryFullName: "",
                watchedRepo: "acme/widgets"
            ).isRunnable)
    }

    /// GitHub treats repository names case-insensitively.
    ///
    /// It returns whatever case was typed, so comparing exactly would refuse a
    /// node's own repository over how someone capitalised it in the config.
    @Test("matches repository names case-insensitively")
    func caseInsensitiveMatch() {
        #expect(
            ForkPolicy.origin(
                headRepositoryFullName: "Acme/Widgets",
                watchedRepo: "acme/widgets") == .sameRepository)
    }

    /// A fork keeps the upstream repository's name, so only the owner differs.
    ///
    /// Comparing the repository half alone would admit every fork there is.
    @Test("refuses a fork that shares the repository name")
    func sameNameDifferentOwner() {
        #expect(
            !ForkPolicy.origin(
                headRepositoryFullName: "someone-else/widgets",
                watchedRepo: "acme/widgets"
            ).isRunnable)
    }
}
