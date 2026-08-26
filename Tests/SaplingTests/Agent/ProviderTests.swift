import Foundation
import Testing

@testable import SaplingAgent
@testable import SaplingCore
@testable import SaplingDB

@Suite("Provider command construction")
struct ProviderTests {
    /// The JIT config is interpolated into a remote shell command, so quoting
    /// it wrong is a command-injection bug, not a formatting nit.
    @Test("shell-quotes values safely, including embedded quotes")
    func shellQuoting() {
        #expect(shellQuote("simple") == "'simple'")
        #expect(shellQuote("with space") == "'with space'")
        #expect(shellQuote("it's") == #"'it'\''s'"#)
        #expect(shellQuote("; rm -rf /") == "'; rm -rf /'")
        #expect(shellQuote("$(whoami)") == "'$(whoami)'")
    }

    /// Every VM is a fresh clone reusing the bridge's address range, so
    /// host-key checking has to be off or every job fails on a collision.
    @Test("SSH arguments suit throwaway VMs")
    func sshArguments() {
        var config = MacOSConfig()
        config.sshUsername = "admin"
        let provider = TartProvider(config: config, sshKeyPath: "/tmp/test_key")
        let arguments = provider.sshArguments(ip: "192.168.64.5")

        #expect(arguments.contains("/tmp/test_key"))
        #expect(arguments.contains("admin@192.168.64.5"))
        #expect(arguments.contains("StrictHostKeyChecking=no"))
        #expect(arguments.contains("UserKnownHostsFile=/dev/null"))
        // Key-based only: never fall back to an interactive password prompt
        // that would hang the daemon forever.
        #expect(arguments.contains("BatchMode=yes"))
    }

    @Test("Tart preflight explains how to fix a missing tart")
    func tartPreflight() async throws {
        guard ProcessRunner.which("tart") == nil else { return }
        do {
            try await TartProvider(config: MacOSConfig()).preflight()
            Issue.record("preflight should fail when tart is absent")
        } catch let error as ProviderError {
            #expect(error.message.contains("tart"))
            #expect(error.message.contains("sapling install"))
        }
    }

    @Test("container preflight points at the install docs")
    func containerPreflight() async throws {
        guard ProcessRunner.which("container") == nil else { return }
        do {
            try await ContainerProvider(config: LinuxConfig()).preflight()
            Issue.record("preflight should fail when container is absent")
        } catch let error as ProviderError {
            #expect(error.message.contains("container"))
        }
    }

    @Test("Linux runner script quotes the JIT config and handles a bare image")
    func runnerScript() {
        let provider = ContainerProvider(config: LinuxConfig())
        let script = provider.runnerScript(
            for: JobRunRequest(
                jobID: "1",
                repo: "acme/widgets",
                runnerName: "sap-linux-abc",
                jitConfig: "abc123==",
                labels: ["self-hosted", "linux"]
            ))

        #expect(script.contains("'abc123=='"))
        #expect(script.contains("exec ./run.sh --jitconfig"))
        // Bails on the first failure rather than running the job half-set-up.
        #expect(script.contains("set -euo pipefail"))
        // Falls back to downloading the runner if the image doesn't ship one.
        #expect(script.contains("actions-runner-linux-arm64"))
        #expect(script.contains("/home/runner/run.sh"))
    }

    @Test("providers report the platform they serve")
    func platforms() {
        #expect(TartProvider(config: MacOSConfig()).platform == .macos)
        #expect(ContainerProvider(config: LinuxConfig()).platform == .linux)
    }
}

/// Apple's `container` keeps per-user state and runs its apiserver in the user's GUI launchd domain, so a
/// root daemon has to enter that session to reach it.
///
/// These cover how the invocation is built.
@Suite("Session invocation")
struct SessionCommandTests {
    @Test("runs the tool directly when not root")
    func directWhenUnprivileged() async throws {
        guard getuid() != 0 else { return }
        let command = try await SessionCommand.invocation("sh", ["-c", "true"])
        #expect(command.executable.hasSuffix("sh"))
        #expect(command.arguments == ["-c", "true"])
    }

    @Test("reports a missing tool with install guidance")
    func missingTool() async {
        await #expect(throws: ProviderError.self) {
            _ = try await SessionCommand.invocation("definitely-not-a-real-binary-xyz", [])
        }
    }

    /// Both providers need the console user's session — `container` for its
    /// apiserver, Virtualization for its keychain — so tart goes through the
    /// same route, and carries TART_HOME across the sudo boundary.
    @Test("tart invocations preserve an explicit TART_HOME")
    func tartCarriesEnvironment() async throws {
        guard getuid() != 0, ProcessRunner.which("tart") != nil else { return }
        let command = try await TartProvider.tart(["list"])
        // Unprivileged, it's a direct call with no env prefix needed.
        #expect(command.arguments == ["list"])
    }

    /// The console user is the session automatic login creates, and the one
    /// that owns the apiserver.
    @Test("resolves a console user that isn't root")
    func sessionUser() async {
        guard let user = await SessionCommand.sessionUser() else { return }
        #expect(!user.name.isEmpty)
        #expect(user.name != "root")
        #expect(Int(user.uid) != nil)
    }
}

/// Regression cover for the worst bug this project has had: the daemon deleting its own base image on every
/// start, because the ephemeral-VM prefix also matched `sapling-macos-base`.
///
/// Rebuilding that image is an 80GB download, and the deletion was silent.
@Suite("Orphan VM reaping")
struct OrphanReapingTests {
    func entries(_ names: [String]) -> [[String: Any]] {
        names.map { ["Name": $0] }
    }

    @Test("never reaps the configured base image")
    func protectsBaseImage() {
        let listed = entries(["sapling-macos-base", "sapling-job-abc123", "my-own-vm"])
        let reapable = TartProvider.reapableVMNames(from: listed, protecting: "sapling-macos-base")
        #expect(reapable == ["sapling-job-abc123"])
    }

    /// The prefix alone must not match the conventional base image name — the
    /// name guard is a second line of defence, not the only one.
    @Test("ephemeral prefix does not match the base image name")
    func prefixIsNarrowEnough() {
        #expect(!"sapling-macos-base".hasPrefix(TartProvider.vmPrefix))
        #expect("sapling-job-abc123".hasPrefix(TartProvider.vmPrefix))
    }

    @Test("protects a base image under a non-default name")
    func protectsRenamedBaseImage() {
        // Someone could name their base image into the ephemeral namespace.
        let listed = entries(["sapling-job-custom-base", "sapling-job-abc123"])
        let reapable = TartProvider.reapableVMNames(from: listed, protecting: "sapling-job-custom-base")
        #expect(reapable == ["sapling-job-abc123"])
    }

    @Test("leaves VMs it didn't create alone")
    func leavesForeignVMsAlone() {
        let listed = entries(["ventura-work", "my-ci-runner", "sapling"])
        #expect(TartProvider.reapableVMNames(from: listed, protecting: "sapling-macos-base").isEmpty)
    }

    @Test("tolerates either key casing tart uses")
    func handlesKeyCasing() {
        let listed: [[String: Any]] = [["name": "sapling-job-lower"], ["Name": "sapling-job-upper"]]
        let reapable = TartProvider.reapableVMNames(from: listed, protecting: "sapling-macos-base")
        #expect(Set(reapable) == ["sapling-job-lower", "sapling-job-upper"])
    }
}
