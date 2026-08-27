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
            """
    )

    @OptionGroup var options: ServerOptions

    @Flag(help: "Only report what's available; change nothing.")
    var check = false

    @Flag(help: "Update even while jobs are running. They will be failed and their VMs reaped.")
    var force = false

    func run() async throws {
        let client = options.client()

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
            // --force exists for the case where the newest release is not
            // *newer* — reinstalling the same version, or recovering a node
            // whose reported version outranks anything published.
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
        print("Installing — the daemon will restart, so it'll be briefly unreachable.")

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

        guard result.applying else {
            fail(result.message)
        }
        print("  \(result.message)")
        await confirmRestart(client: client, expecting: available)
    }

    /// Install the newest release on the channel regardless of precedence.
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

            // Compared as versions, not strings. The binary reports build
            // metadata the release tag does not carry, so "0.1.1-dev.2+11da700"
            // and "0.1.1-dev.2" are the same release — and semver says so,
            // while string equality calls a perfectly good update a mismatch
            // and sends the operator to `doctor` for nothing.
            let installed = SemanticVersion(status.version)
            let expected = SemanticVersion(version)
            let matches =
                if let installed, let expected { installed == expected } else { status.version == version }

            if matches {
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
              ssh <node> 'tail ~/.sapling/logs/sapling.err.log'
            The previous binary is kept at \(SaplingPaths.installedBinary).previous
            """)
    }
}
