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
