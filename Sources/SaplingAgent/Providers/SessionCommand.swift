import Foundation
import SaplingCore

/// Runs a provider tool inside the console user's login session.
///
/// Neither virtualization tool works for a root daemon in the system launchd
/// domain, for different reasons that need the same remedy:
///
/// - Apple's `container` keeps state under the user's home and runs its
///   apiserver in that user's GUI domain. Root gets
///   `XPC connection error: Connection invalid`.
/// - Virtualization.framework cannot create a VM host key without a user
///   session's keychain context. Root gets `VZErrorDomain Code=-9`,
///   "Failed to create new HostKey", *after* the clone succeeds.
///
/// `launchctl asuser` enters that user's bootstrap context and `sudo -u` drops
/// to the user, which needs no password because the caller is already root.
/// Running as the user also keeps files the tools create owned by that user,
/// rather than leaving root-owned VM clones the daemon later can't clean up.
///
/// The consequence is that both providers depend on a login session existing,
/// which is why the node uses automatic login. That is a property of Apple's
/// tools, not a choice Sapling makes, and it is why §10 of the design doc's
/// "independent of any logged-in GUI session" cannot hold.
public enum SessionCommand {
    /// The user whose session owns the container apiserver.
    ///
    /// The console user, since that is the session automatic login creates.
    /// Resolved per call rather than cached: it costs a couple of milliseconds
    /// against a container operation measured in seconds, and a stale answer
    /// after a re-login would be far more annoying than the lookup.
    public static func sessionUser() async -> (name: String, uid: String)? {
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

    /// How to invoke `tool` with the given arguments from this process.
    ///
    /// Running as the session user already, this is just the tool. Running as
    /// root, it routes through that user's launchd domain instead.
    ///
    /// - Parameters:
    ///   - tool: Executable name, resolved on PATH.
    ///   - arguments: Arguments to pass to it.
    ///   - environment: Variables to carry across the `sudo` boundary, which
    ///     otherwise strips them.
    /// - Returns: The executable and arguments to run.
    /// - Throws: `ProviderError` if the tool is absent, or if running as root
    ///   with no console user whose session could be entered.
    public static func invocation(
        _ tool: String,
        _ arguments: [String],
        environment: [String: String] = [:]
    ) async throws -> (executable: String, arguments: [String]) {
        guard let toolPath = ProcessRunner.which(tool) else {
            throw ProviderError(
                """
                `\(tool)` is not installed. Run `sapling doctor` for the current install \
                instructions — see docs/INSTALL.md.
                """)
        }

        guard getuid() == 0 else {
            return (toolPath, arguments)
        }

        guard let user = await sessionUser() else {
            throw ProviderError(
                """
                Running as root with no console user logged in, so `\(tool)` cannot reach the \
                session it needs. Jobs need a login session on this node: enable automatic login \
                for the node's user (System Settings > Users & Groups).
                """)
        }

        // `sudo -H` sets HOME so the tool's own defaults resolve; `env` carries
        // anything else across, since sudo strips the environment.
        var prefix = ["asuser", user.uid, "sudo", "-u", user.name, "-H"]
        if !environment.isEmpty {
            prefix.append("env")
            prefix += environment.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
        }
        // Absolute path: `sudo -u` resets PATH, so a bare name won't resolve.
        return ("launchctl", prefix + [toolPath] + arguments)
    }
}
