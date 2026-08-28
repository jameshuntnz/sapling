import Foundation
import SaplingCore

/// What `tart run` is doing, for whoever is waiting on the VM it should have
/// started.
///
/// `tart run` is launched into a detached task and blocks for the VM's
/// lifetime, so nothing awaits it. That made every way it can fail invisible:
/// the task's own errors were swallowed, its exit status was discarded, and
/// only stderr was logged — so a `tart run` that printed its complaint on
/// stdout and exited said nothing at all.
///
/// Measured on the node: the process started at 11:39:18.1 and was gone by
/// 11:39:18.2. Sapling waited the full five-minute boot timeout and then
/// reported "VM never reported an IP address", which is true and is not the
/// cause. Five minutes of a macOS slot, and the real message thrown away.
actor VMBootProcess {
    /// Why the VM process is gone, or `nil` while it is still running.
    private(set) var failure: String?

    /// The last few lines it printed, which is where the reason usually is.
    ///
    /// Bounded: a VM that boots normally streams for the whole job, and none
    /// of that is worth holding on to.
    private var recent: [String] = []
    private static let recentLimit = 10

    /// Record a line of the process's output.
    func note(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        recent.append(trimmed)
        if recent.count > Self.recentLimit { recent.removeFirst(recent.count - Self.recentLimit) }
    }

    /// Record that the process has ended, and why.
    ///
    /// First reason wins: a cancellation that arrives after a real failure
    /// must not overwrite the explanation.
    func end(_ reason: String) {
        guard failure == nil else { return }
        failure = reason
    }

    /// The failure with the output that explains it, ready to be a job's exit
    /// reason.
    func explanation(vmName: String) -> String? {
        guard let failure else { return nil }
        let tail = recent.isEmpty ? "it printed nothing" : "it said: \(recent.joined(separator: " / "))"
        return """
            VM \(vmName) never started — \(failure), and \(tail). Failing now rather than \
            waiting out the boot timeout and reporting a missing IP address, which is a \
            symptom of this and not a cause.
            """
    }
}
