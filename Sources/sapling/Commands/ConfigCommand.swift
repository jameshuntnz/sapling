import ArgumentParser
import Foundation
import SaplingCore

/// `sapling config` — see what the node is running with, and change it without
/// stopping it.
///
/// A daemon holding a two-hour job cannot be restarted to pick up an edit, so
/// the reloadable half of the configuration is swapped in place and the rest is
/// reported. `ConfigReload` in `SaplingCore` owns which is which.
struct Config: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "config",
        abstract: "Show, check, edit and reload the node's configuration.",
        subcommands: [Show.self, Reload.self, Validate.self, Edit.self, Path.self],
        defaultSubcommand: Show.self
    )
}

extension Config {
    /// Marks a field a reload can apply.
    static let liveMark = "↻"

    /// Prints a `key  from → to` block under a heading.
    static func printChanges(_ heading: String, _ changes: [ConfigChange]) {
        guard !changes.isEmpty else { return }
        print("")
        print(Style.bold(heading))
        let width = changes.map { $0.key.count }.max() ?? 0
        for change in changes {
            print("  \(Format.pad(change.key, to: width))  \(change.from) → \(Style.bold(change.to))")
        }
    }

    /// Prints the outcome of a reload, and fails the command if it was rejected.
    ///
    /// Shared with `config edit`, which finishes by reloading and should
    /// report it identically.
    ///
    /// - Parameter response: What the daemon said it did.
    /// - Throws: `ExitCode.failure` if the daemon kept its old configuration.
    static func report(_ response: ConfigReloadResponse) throws {
        if let error = response.error {
            // The daemon kept what it had, so this is a rejected edit rather
            // than a broken node — say which.
            print("\(Style.red("rejected"))  \(error)")
            print(Style.dim(response.message))
            throw ExitCode.failure
        }
        print(response.reloaded ? Style.green(response.message) : Style.dim(response.message))
        printChanges("Applied", response.applied)
        printRestartChanges("Needs a daemon restart", response.pendingRestart)
        printWarnings(response.warnings)
    }

    /// Prints restart-only changes, with the command that applies them.
    ///
    /// The list is only half an answer without it: knowing a field needs a
    /// restart is not knowing that `sapling restart` will wait for the running
    /// jobs if you ask it to.
    static func printRestartChanges(_ heading: String, _ changes: [ConfigChange]) {
        guard !changes.isEmpty else { return }
        printChanges(heading, changes)
        print(Style.dim("  `sudo sapling restart --wait` applies these once the running jobs finish"))
    }

    /// Prints configuration advisories, the same ones `sapling doctor` shows.
    static func printWarnings(_ warnings: [String]) {
        guard !warnings.isEmpty else { return }
        print("")
        print(Style.bold("Warnings"))
        for warning in warnings { print("  \(Style.yellow("!"))  \(warning)") }
    }

    struct Show: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Print the configuration the daemon is running with."
        )

        @OptionGroup var options: ServerOptions

        @Flag(help: "Read the file on disk instead of asking the daemon.")
        var file = false

        @Option(help: "Config file to read. Implies --file.")
        var path: String?

        @Flag(help: "Emit raw JSON.")
        var json = false

        func run() async throws {
            // Naming a file is asking for that file, so it implies --file:
            // otherwise `--path` would be silently ignored whenever a daemon
            // happened to be up.
            let fromDisk = file || path != nil
            let response: ConfigResponse
            do {
                response =
                    fromDisk ? try Self.fromDisk(path: path) : try await options.client().configuration()
            } catch {
                fail(error.localizedDescription)
            }

            if json {
                print(String(decoding: try SaplingJSON.encoder.encode(response), as: UTF8.self))
                return
            }
            Self.render(response, live: !fromDisk)
        }

        /// The local file, rendered as though the daemon had reported it.
        ///
        /// Useful on a machine with no daemon at all — checking a config before
        /// it is copied to a node, which is the one moment nothing can answer.
        static func fromDisk(path: String?) throws -> ConfigResponse {
            let url =
                path.map { URL(fileURLWithPath: SaplingPaths.expandTilde($0)) } ?? SaplingPaths.configFile
            let config = try SaplingConfig.load(from: url)
            return ConfigResponse(
                path: url.path,
                entries: try ConfigReload.entries(of: config),
                warnings: config.warnings())
        }

        static func render(_ response: ConfigResponse, live: Bool) {
            print(
                "\(Style.bold(live ? "Running configuration" : "Configuration on disk"))  \(Style.dim(response.path))"
            )

            let width =
                response.entries
                .map { $0.key.split(separator: ".").dropFirst().joined(separator: ".").count }
                .max() ?? 0
            var section = ""
            for entry in response.entries {
                let parts = entry.key.split(separator: ".")
                let head = String(parts.first ?? "")
                if head != section {
                    section = head
                    print("")
                    print(Style.bold("[\(section)]"))
                }
                let leaf = parts.dropFirst().joined(separator: ".")
                let mark = entry.reloadable ? Style.dim("  \(Config.liveMark)") : ""
                print("  \(Format.pad(leaf, to: width))  \(entry.value)\(mark)")
            }

            print("")
            print(
                Style.dim(
                    "\(Config.liveMark) applied by `sapling config reload`; every other field needs a daemon restart"
                ))

            if let fileError = response.fileError {
                print("")
                print("\(Style.red("config file"))  \(fileError)")
            }
            Config.printChanges("Waiting for a reload", response.pendingReload)
            Config.printRestartChanges("Waiting for a restart", response.pendingRestart)
            Config.printWarnings(response.warnings)
        }
    }

    struct Reload: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Re-read the config file without restarting the daemon."
        )

        @OptionGroup var options: ServerOptions

        @Flag(help: "Emit raw JSON.")
        var json = false

        func run() async throws {
            let response: ConfigReloadResponse
            do {
                response = try await options.client().reloadConfig()
            } catch {
                fail(error.localizedDescription)
            }

            if json {
                print(String(decoding: try SaplingJSON.encoder.encode(response), as: UTF8.self))
                guard response.error == nil else { throw ExitCode.failure }
                return
            }
            try Config.report(response)
        }
    }

    struct Path: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Print the path of the config file this machine uses."
        )

        func run() async throws {
            print(SaplingPaths.configFile.path)
        }
    }
}
