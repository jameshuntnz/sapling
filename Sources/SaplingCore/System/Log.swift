import Foundation

/// Deliberately minimal: the daemon's stdout/stderr are captured by launchd
/// into `~/.sapling/logs/`, and per-job detail lives in the `runs` table
/// where the API can serve it.
public enum Log {
    /// Whether `debug` output is emitted.
    nonisolated(unsafe) public static var isVerbose = false

    /// Records normal progress, on standard output.
    public static func info(_ message: String) { emit("INFO", message, to: .standardOutput) }
    /// Records something surprising but survivable, on standard error.
    public static func warn(_ message: String) { emit("WARN", message, to: .standardError) }
    /// Records a failure, on standard error.
    public static func error(_ message: String) { emit("ERROR", message, to: .standardError) }
    /// Records detail that is only useful when diagnosing a problem.
    public static func debug(_ message: String) {
        guard isVerbose else { return }
        emit("DEBUG", message, to: .standardOutput)
    }

    private static func emit(_ level: String, _ message: String, to handle: FileHandle) {
        let line = "\(Date().formatted(.iso8601)) [\(level)] \(message)\n"
        handle.write(Data(line.utf8))
    }
}
