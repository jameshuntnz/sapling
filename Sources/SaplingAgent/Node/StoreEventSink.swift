import Foundation
import SaplingCore
import SaplingDB

/// Writes provider progress into the `runs` table, which is what the API and
/// the log viewer read (§5.1 — nothing inspects live processes).
struct StoreEventSink: EventSink {
    let store: SaplingStore
    let jobID: String
    /// Where per-job resource sampling is tracked.
    ///
    /// Optional so a sink that only wants the event log needs nothing else.
    let stats: JobStatsCollector?
    /// What the runner said it was running, read back when GitHub's answer
    /// about the job looks wrong.
    let announcements: RunnerAnnouncements

    init(
        store: SaplingStore, jobID: String, stats: JobStatsCollector? = nil,
        announcements: RunnerAnnouncements = RunnerAnnouncements()
    ) {
        self.store = store
        self.jobID = jobID
        self.stats = stats
        self.announcements = announcements
    }

    func record(_ event: String, detail: String?) async {
        if event == RunEventName.log, let detail {
            await announcements.observe(detail)
        }
        // Event logging must never be able to fail a job.
        try? await store.appendEvent(jobID: jobID, event: event, detail: detail)
    }

    func environmentStarted(name: String, platform: JobPlatform) async {
        await stats?.track(jobID: jobID, environment: name, platform: platform)
    }
}

/// The job a runner announced it was running, taken from its own output.
///
/// GitHub is the authority on how a job ended, but not always promptly. A job
/// that finished in thirteen seconds was still reported `queued` for twelve
/// seconds after its runner exited, and reading that as "our runner ran
/// something else" put a finished job back in the queue — whose next runner
/// then waited two hours for an assignment that was never coming. The runner's
/// own "Running job:" line is what says that answer is stale.
actor RunnerAnnouncements {
    private static let marker = "Running job: "
    private static let listening = "Listening for Jobs"

    /// The name of the last job the runner said it was running, if any.
    private(set) var jobName: String?
    /// When the runner said it was listening, while it has not been given a job.
    private(set) var listeningSince: Date?

    /// Picks the job name out of a runner line, if it carries one.
    ///
    /// Matches both the console line and the diagnostic copy the runner logs
    /// of it; they name the same job.
    ///
    /// - Parameters:
    ///   - line: One line of runner output.
    ///   - now: When it arrived.
    func observe(_ line: String, at now: Date = Date()) {
        if jobName == nil, listeningSince == nil, line.contains(Self.listening) {
            listeningSince = now
        }
        guard let range = line.range(of: Self.marker, options: .backwards) else { return }
        let name = line[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty {
            jobName = name
            listeningSince = nil
        }
    }
}
