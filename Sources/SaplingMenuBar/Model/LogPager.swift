import Foundation
import SaplingCore

/// The selected job's log, as one unbroken run of events.
///
/// The detail endpoint serves only the newest page, and that window slides as
/// the job writes more. Taking it fresh each poll was fine until someone pages
/// back: the earlier events they loaded and the window would drift apart and
/// leave a gap. So the pager owns the list — it starts from the detail's page,
/// appends what is new since its last event, and prepends what is asked for.
@MainActor
@Observable
final class LogPager {
    /// The job these events belong to.
    private(set) var jobID: String?
    /// Every event loaded so far, oldest first, with no gaps.
    private(set) var events: [RunEvent] = []
    /// Whether the daemon has events older than the first one loaded.
    private(set) var hasEarlier = false
    /// A page back is being fetched.
    private(set) var isLoadingEarlier = false

    /// Forget everything, ready for another job.
    func reset(jobID: String?) {
        self.jobID = jobID
        events = []
        hasEarlier = false
        isLoadingEarlier = false
    }

    /// Bring the log up to date with what the daemon has.
    ///
    /// - Parameters:
    ///   - detail: The job's detail, as just fetched.
    ///   - client: Where to ask for anything newer.
    func sync(with detail: JobDetailResponse, client: SaplingClient) async {
        guard detail.job.id == jobID else { return }
        guard let last = events.last?.id else {
            events = detail.events
            // A daemon from before newest-first serving sends no flag, and its
            // detail started at the top — so there is nothing earlier.
            hasEarlier = detail.hasEarlier ?? false
            return
        }
        guard let newer = try? await client.logs(jobID: detail.job.id, after: last),
            detail.job.id == jobID
        else { return }
        events += newer.events.filter { ($0.id ?? 0) > last }
    }

    /// Load the page before the first event shown.
    ///
    /// - Parameter client: Where to ask.
    func loadEarlier(client: SaplingClient) async {
        guard let jobID, let first = events.first?.id, hasEarlier, !isLoadingEarlier else { return }
        isLoadingEarlier = true
        defer { isLoadingEarlier = false }
        guard let page = try? await client.logs(jobID: jobID, before: first), jobID == self.jobID
        else { return }
        // Filtered as well as trusted: a daemon that ignores `before` answers
        // from the top, which would otherwise duplicate the whole log.
        events = page.events.filter { ($0.id ?? 0) < first } + events
        hasEarlier = page.hasEarlier ?? false
    }
}

extension RunEvent {
    /// The runner's own diagnostic chatter rather than the job's output.
    ///
    /// The runner logs its internals as `[RUNNER …]` and `[WORKER …]` lines,
    /// one of which dumps the whole job message — thousands of lines of JSON
    /// that bury the build output a person opened the log to read.
    var isRunnerDiagnostic: Bool {
        guard event == RunEventName.log, let detail else { return false }
        return detail.hasPrefix("[RUNNER ") || detail.hasPrefix("[WORKER ")
    }
}
