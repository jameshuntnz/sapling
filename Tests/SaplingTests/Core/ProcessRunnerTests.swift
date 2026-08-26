import Foundation
import Testing

@testable import SaplingCore

@Suite("ProcessRunner")
struct ProcessRunnerTests {
    @Test("captures stdout and a zero exit")
    func capturesOutput() async throws {
        let result = try await ProcessRunner.run("/bin/echo", ["hello", "world"])
        #expect(result.succeeded)
        #expect(result.exitCode == 0)
        #expect(result.trimmedOutput == "hello world")
        #expect(!result.timedOut)
    }

    @Test("captures stderr and a non-zero exit separately")
    func capturesStderr() async throws {
        let result = try await ProcessRunner.run("/bin/sh", ["-c", "echo out; echo err >&2; exit 3"])
        #expect(!result.succeeded)
        #expect(result.exitCode == 3)
        #expect(result.trimmedOutput == "out")
        #expect(result.stderr.contains("err"))
    }

    @Test("runChecked throws a readable error on failure")
    func runCheckedThrows() async throws {
        await #expect(throws: CommandError.self) {
            try await ProcessRunner.runChecked("/bin/sh", ["-c", "echo nope >&2; exit 1"])
        }
        do {
            _ = try await ProcessRunner.runChecked("/bin/sh", ["-c", "echo nope >&2; exit 1"])
        } catch let error as CommandError {
            let message = error.errorDescription ?? ""
            #expect(message.contains("exit 1"))
            #expect(message.contains("nope"))
        }
    }

    /// Regression guard for the deadlock this class exists to avoid: reading
    /// stdout to EOF before touching stderr wedges as soon as a build fills the
    /// stderr pipe buffer (64KB).
    ///
    /// Both streams must drain concurrently.
    @Test("survives a command that floods both stdout and stderr")
    func concurrentDrainNoDeadlock() async throws {
        let script = """
            for i in $(seq 1 4000); do
              echo "stdout line $i padded ------------------------------------------------"
              echo "stderr line $i padded ------------------------------------------------" >&2
            done
            """
        let result = try await ProcessRunner.run("/bin/sh", ["-c", script], timeout: .seconds(60))
        #expect(result.succeeded)
        #expect(result.stdout.count > 200_000)
        #expect(result.stderr.count > 200_000)
        #expect(result.stdout.contains("stdout line 4000"))
        #expect(result.stderr.contains("stderr line 4000"))
    }

    @Test("kills a command that overruns its timeout")
    func timeout() async throws {
        let result = try await ProcessRunner.run("/bin/sleep", ["30"], timeout: .seconds(1))
        #expect(result.timedOut)
        #expect(!result.succeeded)
    }

    @Test("feeds standard input")
    func standardInput() async throws {
        let result = try await ProcessRunner.run("/usr/bin/wc", ["-l"], standardInput: "a\nb\nc\n")
        #expect(result.succeeded)
        #expect(result.trimmedOutput == "3")
    }

    @Test("reports a missing executable as such, not as a failed run")
    func missingExecutable() async throws {
        await #expect(throws: ExecutableNotFound.self) {
            try await ProcessRunner.run("definitely-not-a-real-binary-xyz")
        }
    }

    @Test("resolves executables on PATH")
    func which() {
        #expect(ProcessRunner.which("sh") == "/bin/sh")
        #expect(ProcessRunner.which("/bin/sh") == "/bin/sh")
        #expect(ProcessRunner.which("/bin/definitely-missing") == nil)
        #expect(ProcessRunner.which("definitely-not-a-real-binary-xyz") == nil)
    }

    /// launchd hands daemons a minimal PATH with no Homebrew in it, which is
    /// how `tart` resolves interactively and mysteriously doesn't under the
    /// LaunchDaemon.
    @Test("prepends Homebrew to PATH and de-duplicates")
    func environmentPath() {
        let env = ProcessRunner.defaultEnvironment()
        let path = env["PATH"] ?? ""
        #expect(path.hasPrefix("/opt/homebrew/bin"))
        #expect(path.contains("/usr/bin"))

        let entries = path.split(separator: ":").map(String.init)
        #expect(entries.count == Set(entries).count, "PATH should not contain duplicates")

        let overridden = ProcessRunner.defaultEnvironment(overrides: ["SAPLING_TEST": "1"])
        #expect(overridden["SAPLING_TEST"] == "1")
    }

    @Test("streams output as it arrives and ends with an exit chunk")
    func streaming() async throws {
        var stdout: [String] = []
        var stderr: [String] = []
        var exitCode: Int32?

        for try await chunk in ProcessRunner.stream("/bin/sh", ["-c", "echo one; echo two >&2; exit 7"]) {
            switch chunk {
            case .stdout(let text): stdout.append(text)
            case .stderr(let text): stderr.append(text)
            case .exit(let code): exitCode = code
            }
        }

        #expect(stdout.joined().contains("one"))
        #expect(stderr.joined().contains("two"))
        #expect(exitCode == 7)
    }

    /// The tail of a job's log lands between the last readability callback
    /// and process exit; losing it would silently truncate every log.
    @Test("streaming does not drop output written just before exit")
    func streamingCapturesTail() async throws {
        var collected = ""
        for try await chunk in ProcessRunner.stream("/bin/sh", ["-c", "printf 'final-line-marker'"]) {
            if case .stdout(let text) = chunk { collected += text }
        }
        #expect(collected.contains("final-line-marker"))
    }

    @Test("streaming reports a missing executable")
    func streamingMissingExecutable() async throws {
        await #expect(throws: ExecutableNotFound.self) {
            for try await _ in ProcessRunner.stream("definitely-not-a-real-binary-xyz") {}
        }
    }

    @Test("terminates the child when the surrounding task is cancelled")
    func cancellation() async throws {
        let task = Task {
            try await ProcessRunner.run("/bin/sleep", ["30"])
        }
        try await Task.sleep(for: .milliseconds(300))
        task.cancel()
        let result = try await task.value
        // Terminated by signal rather than a clean exit.
        #expect(!result.succeeded)
    }
}
