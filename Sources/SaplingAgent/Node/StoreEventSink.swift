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

    init(store: SaplingStore, jobID: String, stats: JobStatsCollector? = nil) {
        self.store = store
        self.jobID = jobID
        self.stats = stats
    }

    func record(_ event: String, detail: String?) async {
        // Event logging must never be able to fail a job.
        try? await store.appendEvent(jobID: jobID, event: event, detail: detail)
    }

    func environmentStarted(name: String, platform: JobPlatform) async {
        await stats?.track(jobID: jobID, environment: name, platform: platform)
    }
}
