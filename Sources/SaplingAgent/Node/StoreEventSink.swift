import Foundation
import SaplingCore
import SaplingDB

/// Writes provider progress into the `runs` table, which is what the API and
/// the log viewer read (§5.1 — nothing inspects live processes).
struct StoreEventSink: EventSink {
    let store: SaplingStore
    let jobID: String

    init(store: SaplingStore, jobID: String) {
        self.store = store
        self.jobID = jobID
    }

    func record(_ event: String, detail: String?) async {
        // Event logging must never be able to fail a job.
        try? await store.appendEvent(jobID: jobID, event: event, detail: detail)
    }
}
