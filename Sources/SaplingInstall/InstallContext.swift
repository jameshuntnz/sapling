import Foundation
import SaplingAgent
import SaplingCore

/// Who the installation belongs to.
///
/// `sapling install` runs under `sudo`, so `NSHomeDirectory()` is
/// `/var/root` — not where config, VM images, or logs should live. Every
/// path decision goes through here instead.
public enum InstallContext {
    /// The human's account, even when running under sudo.
    public static var owningUser: String {
        ProcessInfo.processInfo.environment["SUDO_USER"] ?? NSUserName()
    }

    /// The human's home directory, even when running under sudo.
    public static var owningUserHome: String {
        if let sudoUser = ProcessInfo.processInfo.environment["SUDO_USER"] {
            return "/Users/\(sudoUser)"
        }
        return NSHomeDirectory()
    }

    /// Where Sapling's state belongs for the owning user.
    public static var saplingHome: String {
        ProcessInfo.processInfo.environment["SAPLING_HOME"] ?? "\(owningUserHome)/.sapling"
    }

    /// The owning user's Tart image library, which the root daemon shares.
    public static var tartHome: String {
        ProcessInfo.processInfo.environment["TART_HOME"] ?? "\(owningUserHome)/.tart"
    }

    /// Point this process at the right home before any path is resolved.
    public static func prepareEnvironment() {
        setenv("SAPLING_HOME", saplingHome, 1)
        setenv("TART_HOME", tartHome, 1)
    }

    /// Whether this process can write system locations.
    public static var isRoot: Bool { getuid() == 0 }

    /// Hand the `~/.sapling` tree back to the human, so `sapling doctor` and the
    /// CLI work without sudo.
    ///
    /// The daemon runs as root and can read it regardless.
    public static func chownToOwner() async {
        guard isRoot, ProcessInfo.processInfo.environment["SUDO_USER"] != nil else { return }
        _ = try? await ProcessRunner.run(
            "chown",
            ["-R", "\(owningUser):staff", saplingHome],
            timeout: .seconds(60)
        )
    }
}

// MARK: - 8. Egress filtering

/// Wires the pf anchor from §8 into the system ruleset.
///
/// The anchor's *contents* are rewritten by the daemon at every start (the VM
/// bridge subnet isn't known until something has run); this step only ensures
/// `/etc/pf.conf` evaluates the anchor at all.
