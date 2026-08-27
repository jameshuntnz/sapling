import Foundation
import SaplingCore

/// Proves a job environment can reach GitHub before a runner is started in it.
///
/// The job network is built on demand and can be broken in ways nothing else
/// notices: a container bridge whose host-side gateway is absent hands out
/// addresses on a network that does not exist, and every packet then fails with
/// `EHOSTUNREACH`. Nothing in `container system status`, `tart list` or
/// `sapling doctor` reports any of that — all three said "ok" throughout an
/// outage where no job could reach GitHub at all.
///
/// What the runner does with such an environment is the worst part: it retries
/// with backoff for minutes and then reports "lost communication with the
/// server", which describes the symptom and names no cause. A macOS VM in the
/// same state hung hard enough that the host could not SSH to it, and Sapling
/// waited out the two-hour job timeout holding a slot.
///
/// One request answers all of it. Checking by symptom rather than by cause also
/// covers the next variant of this — DNS, a too-broad pf rule, a proxy — none of
/// which need to be enumerated here.
enum EgressCheck {
    /// Endpoint every runner must reach before it can accept work.
    ///
    /// The API root rather than a broker endpoint: it answers unauthenticated,
    /// so any response at all proves the path, and it is the same host the
    /// runner talks to first.
    static let probeURL = "https://api.github.com"

    /// How long the environment gets to prove itself.
    ///
    /// Short: a working environment answers in well under a second, and this
    /// runs on the critical path of every job.
    static let timeout = 15

    /// Exit status used when the probe fails inside a job environment.
    ///
    /// Distinct so a provider can tell "this environment has no network" apart
    /// from a build that legitimately failed.
    static let failureStatus: Int32 = 78

    /// Shell that proves egress, for splicing into a job environment's script.
    ///
    /// Written to be portable between a Linux container and a macOS VM, so
    /// `curl` only — no `getent`, no `ip`, neither of which exists in both.
    static var probeScript: String {
        """
        if ! curl -fsS -m \(timeout) -o /dev/null \(probeURL); then
          echo "sapling: this environment cannot reach \(probeURL)." >&2
          echo "sapling: the job network is broken; refusing to start a runner that would" >&2
          echo "sapling: retry into a void and report 'lost communication with the server'." >&2
          exit \(failureStatus)
        fi
        """
    }

    /// Human-readable explanation for `failureStatus`.
    static let failureReason =
        "the job environment could not reach \(probeURL) — the job network is broken "
        + "(a container bridge whose host gateway is missing does this, and reports itself healthy)"

    /// Whether an exit status means the environment had no network.
    static func isEgressFailure(_ status: Int32) -> Bool {
        status == failureStatus
    }
}
