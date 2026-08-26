import ArgumentParser
import Foundation
import SaplingCore

struct Jobs: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "List recent and running jobs.",
        subcommands: [JobLogs.self]
    )

    @OptionGroup var options: ServerOptions

    @Option(help: "Only jobs with this status.")
    var status: String?

    @Option(name: [.customShort("n"), .long], help: "How many to show.")
    var limit: Int = 25

    @Flag(help: "Emit raw JSON.")
    var json = false

    func run() async throws {
        var filter: JobStatus?
        if let status {
            guard let parsed = JobStatus(rawValue: status) else {
                fail(
                    "unknown status \"\(status)\"; expected one of \(JobStatus.allCases.map(\.rawValue).joined(separator: ", "))"
                )
            }
            filter = parsed
        }

        let jobs: [Job]
        do {
            jobs = try await options.client().jobs(status: filter, limit: limit)
        } catch {
            fail(error.localizedDescription)
        }

        if json {
            print(String(decoding: try SaplingJSON.encoder.encode(jobs), as: UTF8.self))
            return
        }

        let rows = jobs.map { job in
            [
                job.id,
                Style.status(job.status),
                job.platform.rawValue,
                Format.truncate(job.repo, to: 28),
                Format.truncate(job.name ?? "—", to: 34),
                Format.duration(job.duration),
                Format.relative(job.queuedAt),
            ]
        }
        print(
            Format.table(
                headers: ["ID", "STATUS", "PLATFORM", "REPO", "JOB", "DURATION", "QUEUED"],
                rows: rows
            ))
        if !jobs.isEmpty {
            print("")
            print(Style.dim("sapling jobs logs <id>  for the event log"))
        }
    }
}

struct JobLogs: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "logs",
        abstract: "Show the event log for one job."
    )

    @OptionGroup var options: ServerOptions

    @Argument(help: "Job ID.")
    var id: String

    @Flag(name: .shortAndLong, help: "Keep watching for new events.")
    var follow = false

    func run() async throws {
        let client = options.client()

        let detail: JobDetailResponse
        do {
            detail = try await client.job(id: id)
        } catch {
            fail(error.localizedDescription)
        }

        let job = detail.job
        print("\(Style.bold(job.repo)) \(Style.dim("#\(job.id)"))  \(Style.status(job.status))")
        if let name = job.name { print("  \(name)") }
        print("  \(job.platform.rawValue) · \(job.labels.joined(separator: ", "))")
        if let reason = job.exitReason { print("  \(Style.red(reason))") }
        print("")

        var lastID = printEvents(detail.events)

        guard follow else { return }
        while true {
            // Terminal jobs never gain events, so stop rather than poll
            // forever on a finished job.
            if let current = try? await client.job(id: id), current.job.status.isTerminal {
                _ = printEvents(current.events.filter { ($0.id ?? 0) > (lastID ?? 0) })
                print("")
                print(Style.dim("job \(current.job.status.rawValue)"))
                return
            }
            try await Task.sleep(for: .seconds(2))
            guard let logs = try? await client.logs(jobID: id, after: lastID) else { continue }
            if let newest = printEvents(logs.events) { lastID = newest }
        }
    }

    @discardableResult
    private func printEvents(_ events: [RunEvent]) -> Int64? {
        for event in events {
            let time = Style.dim(Format.timestamp(event.ts))
            if event.event == RunEventName.log {
                print("\(time)  \(event.detail ?? "")")
            } else {
                print("\(time)  \(Style.blue(event.event))\(event.detail.map { " \($0)" } ?? "")")
            }
        }
        return events.last?.id
    }
}
