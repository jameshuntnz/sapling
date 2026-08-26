import Foundation

/// Runs external tools.
///
/// Sapling shells out to `tart`, `container`, `pfctl`, and `ssh` rather
/// than reimplementing them, so this is a load-bearing path.
public enum ProcessRunner {
    /// launchd gives daemons a minimal PATH that excludes Homebrew, so every
    /// child process gets these prepended.
    ///
    /// Without this, `tart` and `container` resolve fine in an interactive shell
    /// and mysteriously don't when running under the LaunchDaemon.
    public static let extraPaths = [
        "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin",
    ]

    /// The environment child processes inherit, with Homebrew on `PATH`.
    ///
    /// - Parameter overrides: Extra variables to set or replace.
    /// - Returns: The environment to hand to a child process.
    public static func defaultEnvironment(overrides: [String: String] = [:]) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let existing = (env["PATH"] ?? "").split(separator: ":").map(String.init)
        var seen = Set<String>()
        let merged = (extraPaths + existing).filter { seen.insert($0).inserted }
        env["PATH"] = merged.joined(separator: ":")
        for (key, value) in overrides { env[key] = value }
        return env
    }

    /// Absolute path of `name`, or nil when it isn't on PATH.
    public static func which(_ name: String) -> String? {
        if name.contains("/") {
            return FileManager.default.isExecutableFile(atPath: name) ? name : nil
        }
        for dir in defaultEnvironment()["PATH"]?.split(separator: ":").map(String.init) ?? [] {
            let candidate = (dir as NSString).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    /// Run a command to completion, capturing stdout and stderr.
    ///
    /// stdout and stderr are drained concurrently — draining them in sequence
    /// deadlocks as soon as a build writes more than one pipe buffer's worth
    /// to the stream we aren't reading yet.
    @discardableResult
    public static func run(
        _ executable: String,
        _ arguments: [String] = [],
        environment: [String: String]? = nil,
        currentDirectory: URL? = nil,
        standardInput: String? = nil,
        timeout: Duration? = nil
    ) async throws -> CommandResult {
        guard let resolved = which(executable) else {
            throw ExecutableNotFound(name: executable)
        }

        let display = ([executable] + arguments).joined(separator: " ")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: resolved)
        process.arguments = arguments
        process.environment = environment ?? defaultEnvironment()
        if let currentDirectory { process.currentDirectoryURL = currentDirectory }

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        if let standardInput {
            let inPipe = Pipe()
            process.standardInput = inPipe
            let data = Data(standardInput.utf8)
            DispatchQueue.global(qos: .userInitiated).async {
                inPipe.fileHandleForWriting.write(data)
                try? inPipe.fileHandleForWriting.close()
            }
        }

        let timedOut = LockedBox(false)
        let processBox = LockedBox(process)

        return try await withTaskCancellationHandler {
            let result: CommandResult = try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        try process.run()
                    } catch {
                        continuation.resume(throwing: error)
                        return
                    }

                    let outData = LockedBox(Data())
                    let errData = LockedBox(Data())
                    let group = DispatchGroup()

                    group.enter()
                    DispatchQueue.global(qos: .userInitiated).async {
                        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
                        outData.withLock { $0 = data }
                        group.leave()
                    }
                    group.enter()
                    DispatchQueue.global(qos: .userInitiated).async {
                        let data = errPipe.fileHandleForReading.readDataToEndOfFile()
                        errData.withLock { $0 = data }
                        group.leave()
                    }

                    group.wait()
                    process.waitUntilExit()

                    continuation.resume(
                        returning: CommandResult(
                            command: display,
                            exitCode: process.terminationStatus,
                            stdout: String(decoding: outData.current, as: UTF8.self),
                            stderr: String(decoding: errData.current, as: UTF8.self),
                            timedOut: timedOut.current
                        ))
                }

                if let timeout {
                    Task {
                        try? await Task.sleep(for: timeout)
                        let proc = processBox.current
                        if proc.isRunning {
                            timedOut.withLock { $0 = true }
                            proc.terminate()
                            // Give it a moment to exit cleanly, then insist.
                            try? await Task.sleep(for: .seconds(5))
                            if proc.isRunning { kill(proc.processIdentifier, SIGKILL) }
                        }
                    }
                }
            }
            return result
        } onCancel: {
            let proc = processBox.current
            if proc.isRunning { proc.terminate() }
        }
    }

    /// Like `run`, but throws `CommandError` on a non-zero exit.
    @discardableResult
    public static func runChecked(
        _ executable: String,
        _ arguments: [String] = [],
        environment: [String: String]? = nil,
        currentDirectory: URL? = nil,
        standardInput: String? = nil,
        timeout: Duration? = nil
    ) async throws -> CommandResult {
        let result = try await run(
            executable, arguments,
            environment: environment,
            currentDirectory: currentDirectory,
            standardInput: standardInput,
            timeout: timeout
        )
        guard result.succeeded else { throw CommandError(result: result) }
        return result
    }

    /// Run a command, yielding output as it arrives.
    ///
    /// Used for the long-lived processes (the GitHub runner itself) where
    /// waiting for exit before seeing any output would defeat the log viewer.
    public static func stream(
        _ executable: String,
        _ arguments: [String] = [],
        environment: [String: String]? = nil,
        currentDirectory: URL? = nil
    ) -> AsyncThrowingStream<OutputChunk, Error> {
        AsyncThrowingStream { continuation in
            guard let resolved = which(executable) else {
                continuation.finish(throwing: ExecutableNotFound(name: executable))
                return
            }

            let process = Process()
            process.executableURL = URL(fileURLWithPath: resolved)
            process.arguments = arguments
            process.environment = environment ?? defaultEnvironment()
            if let currentDirectory { process.currentDirectoryURL = currentDirectory }

            let outPipe = Pipe()
            let errPipe = Pipe()
            process.standardOutput = outPipe
            process.standardError = errPipe

            outPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty else {
                    handle.readabilityHandler = nil
                    return
                }
                continuation.yield(.stdout(String(decoding: data, as: UTF8.self)))
            }
            errPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty else {
                    handle.readabilityHandler = nil
                    return
                }
                continuation.yield(.stderr(String(decoding: data, as: UTF8.self)))
            }

            process.terminationHandler = { proc in
                // Drain whatever landed between the last readability callback
                // and exit, otherwise the tail of the log is silently lost.
                let restOut = outPipe.fileHandleForReading.availableData
                if !restOut.isEmpty { continuation.yield(.stdout(String(decoding: restOut, as: UTF8.self))) }
                let restErr = errPipe.fileHandleForReading.availableData
                if !restErr.isEmpty { continuation.yield(.stderr(String(decoding: restErr, as: UTF8.self))) }
                outPipe.fileHandleForReading.readabilityHandler = nil
                errPipe.fileHandleForReading.readabilityHandler = nil
                continuation.yield(.exit(proc.terminationStatus))
                continuation.finish()
            }

            do {
                try process.run()
            } catch {
                continuation.finish(throwing: error)
                return
            }

            continuation.onTermination = { reason in
                if case .cancelled = reason, process.isRunning {
                    process.terminate()
                }
            }
        }
    }
}
