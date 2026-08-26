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
