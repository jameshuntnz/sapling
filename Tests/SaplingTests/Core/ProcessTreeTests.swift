import Foundation
import Testing

@testable import SaplingCore

/// Cancelling a command has to take everything it started with it.
///
/// Provider commands run as `launchctl asuser <uid> sudo -u <user> … <tool>`,
/// so the direct child is `launchctl` and the tool doing the work is its
/// grandchild. Signalling only the child left `sudo` and the tool alive,
/// reparented to PID 1 — and a `tart run` that outlives its own cancellation
/// is what corrupted vmnet, because teardown then deleted a VM whose process
/// still held an interface.
@Suite("Process trees")
struct ProcessTreeTests {
    /// A grandchild must not survive its grandparent being cancelled.
    ///
    /// The outer shell stands in for `launchctl`/`sudo` and the inner one for
    /// the tool doing the work — exactly the shape that leaked. The marker is
    /// in the *grandchild's* own arguments on purpose: matching the parent
    /// instead would pass whether or not anything was fixed.
    @Test("cancelling a command kills its grandchildren")
    func grandchildrenDieWithTheirParent() async throws {
        let marker = "sapling-tree-test-\(UUID().uuidString)"
        let task = Task {
            try await ProcessRunner.run(
                "sh",
                ["-c", "/bin/sh -c 'sleep 60 # \(marker)' & wait"],
                timeout: .seconds(30))
        }
        // Give the shell time to start its child.
        try await Task.sleep(for: .milliseconds(600))
        task.cancel()
        _ = try? await task.value
        try await Task.sleep(for: .milliseconds(600))

        let survivors = try await ProcessRunner.run("pgrep", ["-f", marker], timeout: .seconds(10))
        #expect(
            !survivors.succeeded || survivors.trimmedOutput.isEmpty,
            "a grandchild outlived the cancelled command: \(survivors.stdout)")
    }

    /// A command that overruns its timeout gets the same treatment, since that
    /// is the other path a leaked process escapes through.
    @Test("a timeout kills grandchildren too")
    func timeoutKillsGrandchildren() async throws {
        let marker = "sapling-timeout-test-\(UUID().uuidString)"
        _ = try? await ProcessRunner.run(
            "sh",
            ["-c", "/bin/sh -c 'sleep 60 # \(marker)' & wait"],
            timeout: .milliseconds(400))
        try await Task.sleep(for: .seconds(1))

        let survivors = try await ProcessRunner.run("pgrep", ["-f", marker], timeout: .seconds(10))
        #expect(
            !survivors.succeeded || survivors.trimmedOutput.isEmpty,
            "a grandchild outlived the timed-out command: \(survivors.stdout)")
    }

    /// The isolation must not change what ordinary commands do.
    @Test("normal commands are unaffected")
    func normalCommandsStillWork() async throws {
        let result = try await ProcessRunner.run("echo", ["hello"], timeout: .seconds(10))
        #expect(result.succeeded)
        #expect(result.trimmedOutput == "hello")
    }
}
