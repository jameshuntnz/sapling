import Foundation
import SaplingCore

/// Builds invocations of Apple's `container` CLI.
///
/// `container` keeps its state under the user's home and runs its apiserver in
/// that user's GUI launchd domain, so a root daemon talking to it directly gets
/// `XPC connection error: Connection invalid`. Root can still reach it by
/// entering the user's bootstrap context, which is what `launchctl asuser`
/// does; `sudo -u` then drops to that user, and needs no password because the
/// caller is already root.
///
/// This means the Linux provider depends on a login session existing, which is
/// why the node is set up with automatic login. It is a property of Apple's
/// tool, not a choice Sapling makes.
enum ContainerCommand {
    /// The user whose session owns the container apiserver.
    ///
    /// The console user, since that is the session automatic login creates.
    /// Resolved per call rather than cached: it costs a couple of milliseconds
    /// against a container operation measured in seconds, and a stale answer
    /// after a re-login would be far more annoying than the lookup.
    static func sessionUser() async -> (name: String, uid: String)? {
        guard
            let console = try? await ProcessRunner.run("stat", ["-f", "%Su", "/dev/console"]),
            console.succeeded
        else { return nil }

        let name = console.trimmedOutput
        guard !name.isEmpty, name != "root" else { return nil }

        guard let id = try? await ProcessRunner.run("id", ["-u", name]), id.succeeded else {
            return nil
        }

        return (name: name, uid: id.trimmedOutput)
    }

    /// How to invoke `container` with the given arguments from this process.
    ///
    /// Running as the session user already, this is just `container`. Running
    /// as root, it routes through that user's launchd domain instead.
    static func invocation(_ arguments: [String]) async throws -> (executable: String, arguments: [String]) {
        guard let containerPath = ProcessRunner.which("container") else {
            throw ProviderError(
                """
                Apple's `container` tool is not installed. Run `sapling doctor` for the current \
                install instructions — see docs/INSTALL.md.
                """)
        }

        guard getuid() == 0 else {
            return (containerPath, arguments)
        }

        guard let user = await sessionUser() else {
            throw ProviderError(
                """
                Running as root with no console user logged in, so Apple's `container` apiserver \
                is unreachable. Linux jobs need a login session: enable automatic login for the \
                node's user (System Settings > Users & Groups), or disable Linux jobs with \
                `linux.enabled = false`.
                """)
        }

        // Absolute path: `sudo -u` resets PATH, so `container` alone won't resolve.
        return ("launchctl", ["asuser", user.uid, "sudo", "-u", user.name, containerPath] + arguments)
    }
}
