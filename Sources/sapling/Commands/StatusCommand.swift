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
        print("")

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
}
