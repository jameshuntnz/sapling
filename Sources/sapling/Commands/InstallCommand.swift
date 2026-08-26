import ArgumentParser
import Foundation
import SaplingCore
import SaplingInstall

struct Install: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Bootstrap this Mac into a Sapling node. Safe to re-run.",
        discussion: """
            Checks every dependency and fills in whatever is missing, then registers the \
            daemon so it starts on boot. Re-running after a partial failure, a macOS \
            update, or a wipe converges to the same state rather than erroring.

            Two steps cannot be automated and will be printed as instructions: the \
            one-time Tailscale login, and building the base macOS VM image (Apple's Setup \
            Assistant has no scriptable path).
            """
    )

    @Option(help: "GitHub personal access token (quick-start path).")
    var githubToken: String?

    @Option(help: "GitHub App ID (recommended over a PAT).")
    var githubAppId: String?

    @Option(help: "GitHub App installation ID.")
    var githubInstallationId: String?

    @Option(help: "Path to the GitHub App private key (.pem).")
    var githubPrivateKey: String?

    @Option(
        name: .customLong("repo"), parsing: .singleValue,
        help: "Repository to watch, as owner/repo. Repeatable.")
    var repos: [String] = []

    @Option(help: "Name for this node.")
    var nodeName: String?

    @Option(help: "Run the daemon as this user instead of root. Note: the egress filter needs root.")
    var runAs: String?

    @Flag(help: "Never prompt; fail instead of asking. For scripted re-provisioning.")
    var nonInteractive = false

    @Flag(help: "Do everything except registering the LaunchDaemon.")
    var skipDaemon = false

    func run() async throws {
        let options = InstallOptions(
            githubToken: githubToken,
            githubAppID: githubAppId,
            githubInstallationID: githubInstallationId,
            githubPrivateKeyPath: githubPrivateKey,
            repos: repos,
            nodeName: nodeName,
            runAsUser: runAs,
            nonInteractive: nonInteractive,
            skipDaemon: skipDaemon
        )

        if !InstallContext.isRoot {
            print(
                Style.yellow(
                    """
                    Not running as root. Installing Homebrew packages works, but writing \
                    /usr/local/bin/sapling, the pf anchor, and the LaunchDaemon does not.
                    Re-run with `sudo sapling install` to complete those steps.
                    """))
            print("")
        }

        print(Style.bold("Installing Sapling \(SaplingVersion.current)"))
        print("  home: \(InstallContext.saplingHome)")
        print("")

        let report = await Installer(options: options).install()

        print("")
        if !report.completed.isEmpty {
            print(Style.bold("Changed"))
            for entry in report.completed { print("  • \(entry)") }
            print("")
        }

        if !report.manual.isEmpty {
            print(Style.bold(Style.yellow("Manual steps remaining")))
            for entry in report.manual {
                print("")
                print(Style.yellow("  \(entry.step): \(entry.summary)"))
                for line in entry.instructions.components(separatedBy: .newlines) {
                    print("  \(line)")
                }
            }
            print("")
        }

        if !report.failed.isEmpty {
            print(Style.bold(Style.red("Failed")))
            for entry in report.failed {
                print(Style.red("  • \(entry.step): \(entry.reason)"))
            }
            print("")
            print("Fix the above and re-run `sapling install` — it only redoes what's missing.")
            throw ExitCode.failure
        }

        if report.isComplete {
            print(Style.green("Sapling is installed and running."))
            print("  Check it with:  sapling status")
            print("  Follow logs:    tail -f \(InstallContext.saplingHome)/logs/sapling.err.log")
        } else {
            print("Re-run `sapling install` once the manual steps above are done.")
        }
    }
}
