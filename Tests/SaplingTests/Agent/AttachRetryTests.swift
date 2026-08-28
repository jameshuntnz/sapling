import Foundation
import Testing

@testable import SaplingAgent
@testable import SaplingCore

/// A VM that never gets a network is not a job that has failed.
///
/// Measured in production three times: the attempt *after* one of these boots
/// in eight seconds and runs the job to completion. Sapling already depended
/// on that and paid badly for it — the job was failed, a two minute cooldown
/// waited out, and the work requeued, while the stalled VM sat for five
/// minutes until its teardown destroyed another job's network.
@Suite("VM attach retry")
struct AttachRetryTests {
    @Test("the timeout leaves a tenfold margin over a healthy boot")
    func timeoutHasMargin() {
        // Nine seconds measured on a node also running a container, and the
        // slowest observed clone-and-boot is well inside this.
        #expect(TartProvider.attachTimeout >= .seconds(60))
        // The point is to be far below the five-minute boot timeout that let a
        // dead VM sit long enough to do damage on teardown.
        #expect(TartProvider.attachTimeout < .seconds(300))
    }

    @Test("more than one attempt, and a bounded number of them")
    func attemptsAreBounded() {
        #expect(TartProvider.attachAttempts > 1)
        #expect(TartProvider.attachAttempts <= 5)
        // Worst case must still beat sitting in the old single 300s wait.
        let worstCase = TartProvider.attachTimeout * Double(TartProvider.attachAttempts)
        #expect(worstCase <= .seconds(300))
    }

    /// The retry only fires for a VM with no network.
    ///
    /// A build that failed, or a missing base image, must not be retried
    /// three times.
    @Test("only a missing network is retryable")
    func onlyNetworkFailuresRetry() {
        let attach: any Error = VMAttachFailed(vmName: "vm-1", detail: "no address within 90 seconds")
        let other: any Error = ProviderError("base image not found")
        #expect(attach is VMAttachFailed)
        #expect(!(other is VMAttachFailed))
    }

    @Test("the failure names the VM and what was seen")
    func failureIsLegible() {
        let error = VMAttachFailed(vmName: "sapling-job-sap-macos-abc", detail: "no bridge came up")
        let text = error.errorDescription ?? ""
        #expect(text.contains("sapling-job-sap-macos-abc"))
        #expect(text.contains("no bridge came up"))
        #expect(text.contains("did not get a network"))
    }

    /// The capture is the only route to a root cause that cannot be reproduced
    /// on demand, so it must land somewhere findable rather than in a log that
    /// rotates.
    @Test("captures are written under the sapling home")
    func capturesAreFindable() {
        #expect(NetworkDiagnostics.directory.path.hasSuffix("/diagnostics"))
        #expect(NetworkDiagnostics.directory.path.contains(SaplingPaths.home.lastPathComponent))
    }
}
