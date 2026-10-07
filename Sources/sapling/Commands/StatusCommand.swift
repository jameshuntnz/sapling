import ArgumentParser
import Foundation
import SaplingCore

struct Status: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Node health and current slot usage."
    )

    @OptionGroup var options: ServerOptions

    @Flag(help: "Emit raw JSON.")
    var json = false

    func run() async throws {
        let status: StatusResponse
        do {
            status = try await options.client().status()
        } catch {
            fail(error.localizedDescription)
        }

        // Best effort: the reasons are an aid, and a status that fails because
        // the job list did not load would be worse than one without them.
        let queued = (try? await options.client().jobs(status: .queued, limit: 50)) ?? []

        if json {
            print(String(decoding: try SaplingJSON.encoder.encode(status), as: UTF8.self))
            return
        }

        print(
            "\(Style.bold(status.node.name))  \(Style.status(status.node.status))  \(Style.dim("sapling \(status.version)"))"
        )
        print("  last seen  \(Format.relative(status.node.lastSeenAt))")
        print("")

        print(Style.bold("Slots"))
        for slot in status.slots {
            let bar =
                String(repeating: "●", count: slot.inUse)
                + String(repeating: "○", count: max(0, slot.capacity - slot.inUse))
            let note =
                slot.platform == .macos && slot.capacity == 2
                ? Style.dim("  (Apple's 2-VM limit)")
                : ""
            print(
                "  \(Format.pad(slot.platform.rawValue, to: 7)) \(bar)  \(slot.inUse)/\(slot.capacity)\(note)"
            )
        }
        if status.memoryBudgetGB > 0 {
            print(
                "  \(Format.pad("memory", to: 7)) \(status.committedMemoryGB)/\(status.memoryBudgetGB)GB"
                    + Style.dim("  (\(status.freeMemoryGB)GB free)"))
        }
        print("")

        printWaiting(queued, status: status)

        print(Style.bold("Jobs"))
        print("  queued            \(status.queuedJobs)")
        print("  running           \(status.runningJobs)")
        print("  completed (24h)   \(Style.green(String(status.completedLast24h)))")
        print(
            "  failed (24h)      \(status.failedLast24h > 0 ? Style.red(String(status.failedLast24h)) : "0")")
        if status.cancelledLast24h > 0 {
            print("  cancelled (24h)   \(Style.dim(String(status.cancelledLast24h)))")
        }
        print("")

        print(Style.bold("GitHub"))
        print(
            "  watching          \(status.watchedRepos.isEmpty ? Style.dim("(none)") : status.watchedRepos.joined(separator: ", "))"
        )
        print("  last poll         \(Format.relative(status.lastPollAt))")
        if status.forkRunsRefused > 0 {
            print(
                "  forks refused     \(status.forkRunsRefused)"
                    + Style.dim("  (runs whose code came from outside the watched repo)"))
        }
        if let error = status.lastPollError {
            print("  \(Style.red("poll error"))        \(error)")
        }
    }

    /// Why each queued job has not started, since free slots alone suggest it should have.
    private func printWaiting(_ jobs: [Job], status: StatusResponse) {
        let queued = QueueExplainer.schedulingOrder(jobs)
        var capacity: [JobPlatform: Int] = [:]
        var inUse: [JobPlatform: Int] = [:]
        for slot in status.slots {
            capacity[slot.platform] = slot.capacity
            inUse[slot.platform] = slot.inUse
        }
        let reasons = QueueExplainer.explain(
            queued: queued, inUse: inUse, capacity: capacity,
            nodeCapacity: status.nodeCapacity,
            committedGB: status.committedMemoryGB, budgetGB: status.memoryBudgetGB,
            sizeOf: status.chargeGB(for:))
        let waiting = queued.filter { reasons[$0.id] != nil }
        guard !waiting.isEmpty else { return }

        print(Style.bold("Waiting"))
        for job in waiting {
            guard let reason = reasons[job.id] else { continue }
            let name = job.name ?? "job \(job.id)"
            print("  \(Format.pad(Format.truncate(name, to: 30), to: 30)) \(Style.dim(reason.summary))")
        }
        print("")
    }
}
