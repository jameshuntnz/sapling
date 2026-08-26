import ArgumentParser
import Foundation
import SaplingCore

struct Drain: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Stop accepting new jobs and wait for running ones to finish."
    )

    @OptionGroup var options: ServerOptions

    @Flag(help: "Return immediately instead of waiting.")
    var noWait = false

    func run() async throws {
        let client = options.client()
        do {
            let response = try await client.drain()
            print("\(Style.status(response.status)): \(response.message)")
            guard !noWait else { return }

            while true {
                let status = try await client.status()
                let running = status.slots.reduce(0) { $0 + $1.inUse }
                if running == 0 {
                    print(Style.green("drained — nothing running"))
                    return
                }
                print(Style.dim("  waiting on \(running) job(s)…"))
                try await Task.sleep(for: .seconds(5))
            }
        } catch {
            fail(error.localizedDescription)
        }
    }
}

struct Cordon: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Pause job acceptance.")

    @OptionGroup var options: ServerOptions

    func run() async throws {
        do {
            let response = try await options.client().cordon()
            print("\(Style.status(response.status)): \(response.message)")
        } catch {
            fail(error.localizedDescription)
        }
    }
}

struct Uncordon: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Resume job acceptance.")

    @OptionGroup var options: ServerOptions

    func run() async throws {
        do {
            let response = try await options.client().uncordon()
            print("\(Style.status(response.status)): \(response.message)")
        } catch {
            fail(error.localizedDescription)
        }
    }
}

/// §11 step 8 defers multi-node enrollment until there's a real second node to
/// test against.
///
/// The command exists so the shape is visible and `nodes join-token` has
/// something to point at, but it refuses rather than pretending to work.
struct Join: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Enrol this Mac as an additional node (not implemented in v1)."
    )

    @Option(help: "Control plane URL.")
    var controlPlane: String

    @Option(help: "Enrollment token from `sapling nodes join-token`.")
    var token: String

    func run() async throws {
        fail(
            """
            `sapling join` is deferred to v2 (§11 step 8) — it is not built speculatively \
            without a second node to test against. The control plane, the join-token \
            endpoint, and the `nodes` table already support it; what's missing is the \
            agent-only run mode.
            """)
    }
}
