import Foundation

/// Every on-disk location Sapling uses, in one place.
///
/// The daemon runs as a LaunchDaemon (root, no login session), so "home
/// directory" is not a safe notion at runtime — `SAPLING_HOME` is set
/// explicitly in the plist and takes precedence over everything else.
public enum SaplingPaths {
    /// Root of Sapling's state directory.
    public static var home: URL {
        if let override = ProcessInfo.processInfo.environment["SAPLING_HOME"], !override.isEmpty {
            return URL(fileURLWithPath: expandTilde(override))
        }
        return URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".sapling")
    }

    /// The TOML configuration file.
    public static var configFile: URL { home.appendingPathComponent("config.toml") }
    /// The SQLite database backing the control plane.
    public static var databaseFile: URL { home.appendingPathComponent("sapling.db") }
    /// Where launchd writes the daemon's output.
    public static var logsDirectory: URL { home.appendingPathComponent("logs") }
    /// Scratch state that survives a restart.
    public static var stateDirectory: URL { home.appendingPathComponent("state") }
    /// Backing store for the pull-through package caches.
    public static var runnerCacheDirectory: URL { home.appendingPathComponent("runner-cache") }
    /// Private key the agent uses to reach macOS VMs.
    public static var sshKeyFile: URL { home.appendingPathComponent("vm_ed25519") }
    /// Where the daemon records the address it actually bound.
    ///
    /// Clients on the node read this rather than guessing: with
    /// `bind = "tailscale"` the listener is on the tailnet address, so
    /// assuming loopback means the CLI cannot reach its own daemon.
    public static var endpointFile: URL { home.appendingPathComponent("endpoint") }

    /// launchd job label for the daemon.
    public static let launchDaemonLabel = "dev.sapling.daemon"
    /// Where the LaunchDaemon plist is installed.
    public static var launchDaemonPlist: URL {
        URL(fileURLWithPath: "/Library/LaunchDaemons/\(launchDaemonLabel).plist")
    }
    /// Where `sapling install` puts the executable.
    public static let installedBinary = "/usr/local/bin/sapling"

    /// Client-side config (CLI and menu bar app talking to a remote daemon).
    public static var clientConfigFile: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".sapling")
            .appendingPathComponent("client.toml")
    }

    /// Expands a leading `~` to the current home directory.
    ///
    /// A tilde anywhere else is left alone, since it is a valid path
    /// character.
    public static func expandTilde(_ path: String) -> String {
        guard path == "~" || path.hasPrefix("~/") else { return path }
        return NSHomeDirectory() + path.dropFirst(1)
    }

    /// Create the directory tree, with `0700` on the root since it holds
    /// GitHub credentials (§8).
    @discardableResult
    public static func ensureHomeDirectory() throws -> URL {
        let fm = FileManager.default
        let root = home
        if !fm.fileExists(atPath: root.path) {
            try fm.createDirectory(
                at: root, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
        } else {
            try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        }
        for sub in [logsDirectory, stateDirectory, runnerCacheDirectory] {
            if !fm.fileExists(atPath: sub.path) {
                try fm.createDirectory(at: sub, withIntermediateDirectories: true)
            }
        }
        return root
    }
}
