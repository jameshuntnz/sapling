import ArgumentParser
import Foundation
import SaplingCore
import SaplingInstall

struct Upgrade: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Replace the installed binary and restart the daemon."
    )

    @Option(help: "Binary to install. Defaults to the one you're running.")
    var binary: String?

    func run() async throws {
        do {
            for action in try await Installer().upgrade(from: binary) {
                print("  • \(action)")
            }
            print(Style.green("Upgraded. Check with `sapling status`."))
        } catch {
            fail(error.localizedDescription)
        }
    }
}

/// `sapling restart` — ask the daemon to restart itself, or start it if it is
/// not there.
///
/// No `sudo` in the normal case: the daemon runs as root under launchd, so it
/// can kickstart itself, exactly as `sapling update` has it do after swapping
/// the binary. Root is only needed for the case the API cannot cover — a
/// daemon that has crashed or was never started, where there is nothing to ask
/// and launchd has to be told directly.
///
/// Deliberately has no `--server`: launchd is local, so this always acts on
/// this Mac's daemon. A workstation whose `client.toml` points at the node
/// would otherwise read the node's job count and restart the laptop.
struct Restart: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Restart the daemon on this machine.",
        discussion: """
            No sudo while the daemon is answering — it is already root, so it \
            restarts itself. A daemon that is down has to be started through \
            launchd instead, and that does need sudo.

            A restart fails every job that is running: the VM or container is reaped \
            with the process that owns it, and GitHub is told the job failed. So it \
            is refused while the node is busy unless you say what to do about that — \
            --wait finishes the running jobs first, --force takes them down.

            The node comes back accepting jobs: registering on startup sets it \
            online, so a --wait restart does not leave it drained.
            """
    )

    @Flag(help: "Stop accepting new jobs and wait for the running ones to finish first.")
    var wait = false

    @Flag(name: .shortAndLong, help: "Restart even while jobs are running.")
    var force = false

    @Option(help: "Give up waiting for jobs after this many seconds.")
    var waitTimeout = 3600

    func run() async throws {
        let client = SaplingClient(baseURL: ServerEndpoint.local)

        guard let running = await Self.runningJobs(client) else {
            // Nothing answering is a daemon that crashed or was never started
            // — exactly when someone reaches for a restart, and the one case
            // the API cannot serve, so launchd is asked directly.
            print(
                Style.dim(
                    "no daemon answering on \(ServerEndpoint.local.absoluteString) — starting it through launchd"
                ))
            try await Self.kickstartLocally()
            await Self.waitForDaemon(client)
            return
        }

        try await handleRunningJobs(running, client: client)
        try await askDaemonToRestart(client)
        await Self.waitForDaemon(client)
    }

    /// Ask the running daemon to restart itself, falling back to launchd.
    private func askDaemonToRestart(_ client: SaplingClient) async throws {
        do {
            let response = try await client.restartDaemon(force: force)
            if let error = response.error {
                // It is up but cannot kickstart itself — a daemon started by
                // hand rather than by launchd, most likely. Say so, then do it
                // the way that works.
                print("\(Style.yellow("the daemon cannot restart itself"))  \(error)")
                try await Self.kickstartLocally()
                return
            }
            print(Style.green(response.message))
        } catch let error as ClientError where error.statusCode == nil {
            // The reply raced the process going down. That is the restart, not
            // a failure — `waitForDaemon` settles which.
            print(Style.green("restarting"))
        } catch {
            print("\(Style.yellow("could not ask the daemon to restart"))  \(error.localizedDescription)")
            try await Self.kickstartLocally()
        }
    }

    /// Tell launchd directly, which is the path that needs root.
    static func kickstartLocally() async throws {
        guard InstallContext.isRoot else {
            fail(
                "the daemon can't be asked to restart itself, so launchd has to be told directly "
                    + "— re-run with sudo")
        }
        let result: CommandResult
        do {
            result = try await LaunchControl.restart()
        } catch {
            fail(error.localizedDescription)
        }
        guard result.succeeded else {
            fail(LaunchControl.explain(result))
        }
        print(Style.green("restarted \(SaplingPaths.launchDaemonLabel)"))
    }

    /// Refuse, wait, or warn — the node is busy and something has to give.
    private func handleRunningJobs(_ running: Int, client: SaplingClient) async throws {
        guard running > 0 else { return }
        guard wait || force else {
            fail(
                "\(running) job(s) are running — a restart would fail them. "
                    + "Use --wait to finish them first, or --force to take them down.")
        }
        guard wait else {
            print(Style.yellow("forcing a restart with \(running) job(s) running — they will fail"))
            return
        }

        do {
            let response = try await client.drain()
            print("\(Style.status(response.status)): \(response.message)")
        } catch {
            fail("could not stop job acceptance: \(error.localizedDescription)")
        }
        let deadline = Date().addingTimeInterval(TimeInterval(waitTimeout))
        while Date() < deadline {
            guard let left = await Self.runningJobs(client), left > 0 else {
                print(Style.green("nothing running"))
                return
            }
            print(Style.dim("  waiting on \(left) job(s)…"))
            try await Task.sleep(for: .seconds(5))
        }
        fail("still busy after \(waitTimeout)s — the node is left draining, and no restart was done")
    }

    /// How many jobs the local daemon has running, or `nil` if it isn't answering.
    static func runningJobs(_ client: SaplingClient) async -> Int? {
        guard let status = try? await client.status() else { return nil }
        return status.slots.reduce(0) { $0 + $1.inUse }
    }

    /// Wait for the daemon to answer again, so the command ends on a fact.
    ///
    /// launchd throttles restarts to ten seconds, so a daemon that is coming
    /// back has not necessarily bound its listener yet when this starts.
    static func waitForDaemon(_ client: SaplingClient, attempts: Int = 20) async {
        for _ in 0..<attempts {
            if let status = try? await client.status() {
                print(
                    "\(Style.bold(status.node.name))  \(Style.status(status.node.status))  "
                        + Style.dim("sapling \(status.version)"))
                return
            }
            try? await Task.sleep(for: .seconds(2))
        }
        print(
            Style.yellow("the daemon has not answered yet")
                + Style.dim(" — check \(SaplingPaths.logsDirectory.path)/sapling.err.log"))
    }
}

struct Uninstall: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Remove the daemon. Keeps config and job history unless --purge."
    )

    @Flag(help: "Also remove ~/.sapling (config, credentials, database) and Sapling's VMs.")
    var purge = false

    @Flag(name: .shortAndLong, help: "Don't ask for confirmation.")
    var force = false

    func run() async throws {
        if purge && !force {
            print(
                Style.yellow(
                    "--purge removes \(InstallContext.saplingHome): GitHub credentials, job history, and Sapling's VM clones."
                ))
            guard Prompt.confirm("Continue?", default: false) else {
                print("Cancelled.")
                return
            }
        }
        do {
            for action in try await Installer().uninstall(purge: purge) {
                print("  • \(action)")
            }
            print(Style.green("Uninstalled."))
        } catch {
            fail(error.localizedDescription)
        }
    }
}
