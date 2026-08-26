import Foundation

/// The outcome of running a command to completion.
public struct CommandResult: Sendable {
    /// The command line, for error messages.
    public let command: String
    /// Process exit status.
    public let exitCode: Int32
    /// Everything written to standard output.
    public let stdout: String
    /// Everything written to standard error.
    public let stderr: String
    /// Whether the command was killed for exceeding its timeout.
    public let timedOut: Bool

    /// Whether the command exited cleanly and in time.
    public var succeeded: Bool { exitCode == 0 && !timedOut }

    /// stdout with surrounding whitespace stripped — what most callers want
    /// when a command's whole output is a single value (an IP, a UUID, ...).
    public var trimmedOutput: String {
        stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Thrown when a checked command fails.
public struct CommandError: Error, LocalizedError, Sendable {
    /// The failed command's full result.
    public let result: CommandResult

    /// A message naming the command and what went wrong.
    public var errorDescription: String? {
        if result.timedOut {
            return "`\(result.command)` timed out"
        }
        let detail = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let message = detail.isEmpty ? fallback : detail
        return "`\(result.command)` failed (exit \(result.exitCode))\(message.isEmpty ? "" : ": \(message)")"
    }
}

/// Thrown when a required tool isn't on `PATH`.
public struct ExecutableNotFound: Error, LocalizedError, Sendable {
    /// The executable that could not be found.
    public let name: String
    /// A message naming the command and what went wrong.
    public var errorDescription: String? { "required executable `\(name)` was not found on PATH" }
}

/// One chunk of output from a streaming command.
public enum OutputChunk: Sendable {
    case stdout(String)
    case stderr(String)
    /// Always the final element; carries the process exit status.
    case exit(Int32)
}
