import ArgumentParser
import Foundation
import SaplingCore

/// `sapling update` — install a newer release.
///
/// Deliberately goes through the daemon rather than doing the work locally.
/// The daemon already runs as root, so it can replace its own binary and
/// restart itself; doing it from the CLI would need `sudo` every time, which
/// during the first node bring-up meant a password prompt for every deploy.
struct Update: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Update the node to the newest release on its channel.",
        discussion: """
            The daemon downloads the release, checks it against the published \
            checksums, replaces its own binary and restarts. No sudo, because \
            the daemon is already root.

            Which releases a node will take is set by `update.channel` in its \
            config: `stable` ignores rc and dev builds, `rc` takes candidates \
            and releases, `dev` takes whatever is newest.

            A busy node is safe to update. The release is downloaded and \
            verified straight away, then the node drains and installs it once \
            the last running job finishes. This command follows along; Ctrl-C \
            leaves the update scheduled, and --cancel calls it off.

            Runs against whichever node `--server` resolves to, so it updates a \
            headless node from the Mac you watch from — you do not have to log \
            into the node to update it.
            """
    )

    @OptionGroup var options: ServerOptions

    @Flag(help: "Only report what's available; change nothing.")
    var check = false

    @Flag(help: "Install now even while jobs are running. They will be failed and their VMs reaped.")
    var force = false

    @Flag(help: "Call off an update that is waiting for running jobs to finish.")
    var cancel = false

    func run() async throws {
        let client = options.client()

        if cancel {
            do {
                print("  \(try await client.cancelUpdate().message)")
            } catch {
                fail(error.localizedDescription)
            }
            return
        }

        let status: UpdateCheckResponse
        do {
            status = try await client.checkForUpdate()
        } catch {
            fail(error.localizedDescription)
        }

        if let error = status.error {
            fail("could not check for updates: \(error)")
        }

        print("  running   \(status.current)  \(Style.dim("(\(status.channel.rawValue) channel)"))")

        guard let available = status.available else {
            // --force reinstalls the same version. The daemon refuses an
            // older one; that is `sapling upgrade --binary` on the node.
            guard force, !check else {
                print("  \(Style.green("up to date"))")
                return
            }
            print("  \(Style.dim("no newer release; reinstalling the newest anyway (--force)"))")
            await forceReinstall(client: client)
            return
        }

        let published = status.publishedAt.map { " · published \(Format.relative($0))" } ?? ""
        print("  available \(Style.bold(available))\(Style.dim(published))")

        if check {
            print("")
            print("Run `sapling update` to install it.")
            return
        }

        print("")
        print("Downloading and verifying \(available)…")

        let result: UpdateApplyResponse
        do {
            result = try await client.applyUpdate(force: force)
        } catch let error as ClientError where error.statusCode == nil {
            // The daemon restarting mid-reply looks exactly like it going away,
            // because it did. Confirm by asking the new one what it is.
            print("  \(Style.dim("connection dropped — checking whether it came back"))")
            await confirmRestart(client: client, expecting: available)
            return
        } catch {
            fail(error.localizedDescription)
        }

        if result.waitingOnJobs != nil {
            print("  \(result.message)")
            await followScheduled(client: client, expecting: result.version ?? available)
            return
        }
        guard result.applying else {
            fail(result.message)
        }
        print("  \(result.message)")
        await confirmRestart(client: client, expecting: available)
    }

    /// Follow an install the daemon is holding until its jobs finish.
    ///
    /// Only watching: the daemon does the waiting, so interrupting this
    /// changes nothing.
    private func followScheduled(client: SaplingClient, expecting version: String) async {
        print(Style.dim("  Ctrl-C leaves it scheduled; `sapling update --cancel` calls it off."))
        var lastCount: Int?
        while true {
            try? await Task.sleep(for: .seconds(5))
            guard let status = try? await client.status() else {
                print("  \(Style.dim("daemon restarting"))")
                await confirmRestart(client: client, expecting: version)
                return
            }
            guard status.pendingUpdate != nil else {
                // Restarted between two polls, or called off or failed.
                guard Self.isRunning(version, status) else {
                    fail("\(version) was not installed — called off, or it failed; check the daemon's log")
                }
                print("  \(Style.green("now running \(status.version)"))")
                return
            }
            if status.runningJobs != lastCount {
                print(Style.dim("  waiting on \(status.runningJobs) job(s)…"))
                lastCount = status.runningJobs
            }
        }
    }

    /// Reinstall the newest release on the channel, if it is not older than the running one.
    func forceReinstall(client: SaplingClient) async {
        do {
            let result = try await client.applyUpdate(force: true)
            guard result.applying else { fail(result.message) }
            print("  \(result.message)")
            await confirmRestart(client: client, expecting: result.version ?? "")
        } catch let error as ClientError where error.statusCode == nil {
            print("  \(Style.dim("connection dropped — checking whether it came back"))")
            await confirmRestart(client: client, expecting: "")
        } catch {
            fail(error.localizedDescription)
        }
    }

    /// Wait for the daemon to come back, and report what version it is now.
    ///
    /// Worth doing rather than assuming: a failed restart leaves the node down,
    /// and the operator should hear that from the tool rather than discover it
    /// when a job doesn't run.
    private func confirmRestart(client: SaplingClient, expecting version: String) async {
        for attempt in 1...20 {
            try? await Task.sleep(for: .seconds(2))
            guard let status = try? await client.status() else { continue }

            if Self.isRunning(version, status) {
                print("  \(Style.green("now running \(status.version)")) after \(attempt * 2)s")
            } else {
                print(
                    "  \(Style.yellow("came back on \(status.version)")), expected \(version) — "
                        + "check `sapling doctor`")
            }
            return
        }
        fail(
            """
            the daemon did not come back within 40s. Check it with:
              ssh <node> 'tail /Library/Logs/Sapling/sapling.err.log'
            The previous binary is kept at \(SaplingPaths.installedBinary).previous
            """)
    }

    /// Whether the daemon reports running `version`.
    ///
    /// Compared as versions, not strings. The binary reports build metadata
    /// the release tag does not carry, so "0.1.1-dev.2+11da700" and
    /// "0.1.1-dev.2" are the same release — and semver says so, while string
    /// equality calls a perfectly good update a mismatch.
    static func isRunning(_ version: String, _ status: StatusResponse) -> Bool {
        if let installed = SemanticVersion(status.version), let expected = SemanticVersion(version) {
            return installed == expected
        }
        return status.version == version
    }
}
