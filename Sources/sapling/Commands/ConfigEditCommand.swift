import ArgumentParser
import Foundation
import SaplingCore

/// Checking a config file, and editing one safely.
///
/// Both work on a file rather than on individual keys. There is no
/// `config set`: the file is hand-written TOML with comments explaining why a
/// node is tuned the way it is, and re-encoding it from a decoded struct — the
/// only way a `set` could write it back — would throw all of that away.
extension Config {
    struct Validate: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Parse and check a config file without applying it."
        )

        @Option(help: "Config file to check. Defaults to this machine's own.")
        var path: String?

        @Flag(help: "Fail on warnings too, not just errors.")
        var strict = false

        func run() async throws {
            let url = Config.resolve(path)
            let config: SaplingConfig
            do {
                config = try SaplingConfig.load(from: url)
                try config.validate()
            } catch {
                print("\(Style.red("invalid"))  \(url.path)")
                print("  \(error.localizedDescription)")
                throw ExitCode.failure
            }

            let warnings = config.warnings()
            Config.printWarnings(warnings)
            guard !strict || warnings.isEmpty else {
                print("")
                print("\(Style.red("failed"))  \(warnings.count) warning(s), and --strict was given")
                throw ExitCode.failure
            }
            print(Style.green("\(url.path) parses and validates"))
        }
    }

    struct Edit: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Edit the config in $EDITOR, check it, then reload the daemon.",
            discussion: """
                The file is edited through a copy: a config that fails to parse or \
                validate is never written back, so a slip cannot leave the node \
                unable to start. The daemon's own config is mode 0600 and owned by \
                whoever installed it, so this may need sudo.
                """
        )

        @OptionGroup var options: ServerOptions

        @Option(help: "Config file to edit. Defaults to this machine's own.")
        var path: String?

        @Option(help: "Editor command. Defaults to $VISUAL, then $EDITOR, then vi.")
        var editor: String?

        @Flag(help: "Save the file but don't ask the daemon to reload it.")
        var noReload = false

        func run() async throws {
            let url = Config.resolve(path)
            let original: String
            do {
                original = try String(contentsOf: url, encoding: .utf8)
            } catch {
                fail("could not read \(url.path): \(error.localizedDescription)")
            }
            // Said up front rather than refused: a config that already fails
            // to parse is exactly the one someone opens an editor to fix.
            if (try? SaplingConfig.load(from: url)) == nil {
                print(Style.yellow("note: \(url.path) does not parse as it stands"))
            }

            let scratch = FileManager.default.temporaryDirectory
                .appendingPathComponent("sapling-config-\(UUID().uuidString).toml")
            do {
                try original.write(to: scratch, atomically: true, encoding: .utf8)
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o600], ofItemAtPath: scratch.path)
                try Self.launchEditor(Self.editorCommand(editor), on: scratch)
            } catch {
                try? FileManager.default.removeItem(at: scratch)
                fail(error.localizedDescription)
            }

            let edited: String
            do {
                edited = try String(contentsOf: scratch, encoding: .utf8)
            } catch {
                fail("could not read the edited file at \(scratch.path): \(error.localizedDescription)")
            }
            guard edited != original else {
                try? FileManager.default.removeItem(at: scratch)
                print(Style.dim("unchanged — nothing to apply"))
                return
            }

            do {
                let candidate = try SaplingConfig.load(from: scratch)
                try candidate.validate()
                Config.printWarnings(candidate.warnings())
            } catch {
                // The edit is kept: making someone retype it because the
                // parser rejected one line is the worst possible answer here.
                print("\(Style.red("not saved"))  \(error.localizedDescription)")
                print(Style.dim("your edit is at \(scratch.path)"))
                throw ExitCode.failure
            }

            do {
                try edited.write(to: url, atomically: true, encoding: .utf8)
                // `atomically` writes a new file, so the mode has to be put
                // back — this one holds a PAT or an App key path (§8).
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o600], ofItemAtPath: url.path)
            } catch {
                print("\(Style.red("could not write \(url.path)"))  \(error.localizedDescription)")
                print(Style.dim("your edit is at \(scratch.path)"))
                throw ExitCode.failure
            }
            try? FileManager.default.removeItem(at: scratch)
            print(Style.green("saved \(url.path)"))

            guard !noReload else {
                print(Style.dim("run `sapling config reload` when you want the daemon to pick it up"))
                return
            }
            do {
                try Config.report(try await options.client().reloadConfig())
            } catch let error as ClientError {
                // The file is saved either way; a daemon that isn't running is
                // not a failed edit.
                print("\(Style.yellow("not reloaded"))  \(error.message)")
            }
        }

        /// The editor to run, in the order a Unix tool is expected to look.
        static func editorCommand(_ override: String?) -> String {
            let environment = ProcessInfo.processInfo.environment
            for candidate in [override, environment["VISUAL"], environment["EDITOR"]] {
                if let candidate, !candidate.trimmingCharacters(in: .whitespaces).isEmpty {
                    return candidate
                }
            }
            return "vi"
        }

        /// Runs the editor on a file, inheriting the terminal.
        ///
        /// Through `sh` so `EDITOR="code --wait"` works — an editor setting is
        /// a command line, not a binary path.
        ///
        /// - Parameters:
        ///   - command: The editor command line.
        ///   - url: The file to open.
        /// - Throws: If the editor cannot be started, or exits non-zero.
        static func launchEditor(_ command: String, on url: URL) throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", "\(command) \"$1\"", "sapling", url.path]
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw ConfigError("\(command) exited \(process.terminationStatus); nothing was changed")
            }
        }
    }

    /// The config file a subcommand should act on.
    static func resolve(_ path: String?) -> URL {
        path.map { URL(fileURLWithPath: SaplingPaths.expandTilde($0)) } ?? SaplingPaths.configFile
    }
}
