import Foundation
import SaplingCore

/// Getting rid of a VM, and of any VM a previous daemon left behind.
extension TartProvider {

    /// Delete the VM, and don't come back until it is actually gone.
    ///
    /// Awaited rather than fired and forgotten: the caller releases the job's
    /// concurrency slot the moment `run` returns, so returning early lets the
    /// next job clone a third VM while this one still exists — past the two
    /// Apple allows.
    ///
    /// Detached because teardown must survive cancellation. When GitHub
    /// withdraws a job the job's task is cancelled, and `ProcessRunner`
    /// terminates its child as soon as it sees that — `tart stop` would be
    /// killed before it stopped anything. A detached task inherits no
    /// cancellation, so the VM still goes away.
    static func teardown(vmName: String, events: any EventSink) async {
        await Task.detached {
            await events.record(RunEventName.cleanupStarted, detail: vmName)
            await forceTeardown(vmName: vmName)
            await events.record(RunEventName.cleanupFinished, detail: vmName)
        }.value
    }

    /// Stop-then-delete, ignoring failures at each step: a VM that never
    /// booted can't be stopped, and one that was never cloned can't be
    /// deleted, but neither should stop us reclaiming the slot.
    static func forceTeardown(vmName: String) async {
        // Stop first, so the VM shuts down cleanly and `tart run` exits under
        // its own power.
        await tartCommand(["stop", "--timeout", "30", vmName])

        // Then make sure it actually has. Cancelling the boot task does not:
        // `ProcessRunner` terminates its immediate child, which is
        // `launchctl`, and the `sudo` and `tart` processes beneath it survive
        // — that is why leaked wrappers are found with PID 1 as their parent.
        //
        // This ordering is the point. Deleting a VM while the process running
        // it is still alive, still holding its `vmenet` interface, is asking
        // vmnet to lose track of an interface that is in use — and losing
        // track of interfaces is exactly the fault under investigation. The
        // kill used to happen *after* the delete.
        await killRunProcesses(forVM: vmName)

        await tartCommand(["delete", vmName])
    }

    /// Run one `tart` subcommand, ignoring failure.
    ///
    /// A VM that never booted cannot be stopped and one that was never cloned
    /// cannot be deleted, and neither should stop us reclaiming the slot — but
    /// neither should it skip the steps after it, which an early `return`
    /// used to do.
    private static func tartCommand(_ arguments: [String]) async {
        guard let command = try? await tart(arguments) else { return }
        _ = try? await ProcessRunner.run(
            command.executable, command.arguments, timeout: .seconds(60))
    }

    /// Kill whatever is still running this VM, which deleting it does not.
    ///
    /// `tart run` is launched as `launchctl asuser … sudo -u admin … tart run`.
    /// Cancelling the task terminates `ProcessRunner`'s immediate child —
    /// `launchctl` — and the `sudo` and `tart` processes beneath it survive,
    /// reparented to PID 1. Found on the node: six of them, the oldest a day
    /// and nine hours, one added by every macOS job, each apparently holding a
    /// `vmenet` interface that is never released. A node accumulating those
    /// stops being able to attach a VM to a bridge at all, which is the fault
    /// underneath most of this.
    ///
    /// They are root-owned, so only the daemon can clear them — `admin` gets
    /// "operation not permitted".
    static func killRunProcesses(forVM vmName: String) async {
        // Refuse an empty or suspiciously short name rather than build a
        // pattern that matches every VM on the machine, including live ones.
        guard vmName.hasPrefix(vmPrefix) else { return }
        await kill(matching: "tart run --no-graphics \(vmName)")
    }

    /// Kill every leaked `tart run` for a job VM, whatever its name.
    ///
    /// Startup only: the daemon has just come up, so nothing it owns is
    /// legitimately running, and anything matching belongs to a previous life.
    static func reapRunProcesses() async {
        await kill(matching: "tart run --no-graphics \(vmPrefix)")
    }

    /// Send SIGTERM to every process whose command line contains `pattern`.
    ///
    /// `pgrep -f` matches the whole command line, which is what finds both the
    /// `sudo` wrapper and the `tart` process under it. It excludes itself, and
    /// the daemon's own command line cannot contain the pattern.
    private static func kill(matching pattern: String) async {
        let first = await pids(matching: pattern)
        guard !first.isEmpty else { return }
        for pid in first { Foundation.kill(pid, SIGTERM) }

        // SIGTERM alone does not clear these. `sudo` forwards it to the command
        // it is running rather than acting on it, and the command is exactly
        // what has already gone — so the wrapper sits there. Measured on the
        // node: a leaked wrapper survived the daemon's SIGTERM and was still
        // running afterwards. There is nothing left to shut down gracefully,
        // the VM having already been stopped and deleted, so whatever is still
        // there after a moment gets SIGKILL.
        try? await Task.sleep(for: .seconds(2))
        let survivors = await pids(matching: pattern)
        for pid in survivors { Foundation.kill(pid, SIGKILL) }

        Log.info(
            "reaped \(first.count) leaked `tart run` process(es)"
                + (survivors.isEmpty ? "" : ", \(survivors.count) of which needed SIGKILL"))
    }

    /// Process ids whose command line contains `pattern`.
    ///
    /// `pgrep` exits non-zero when nothing matched, which is the common case
    /// and not an error.
    private static func pids(matching pattern: String) async -> [pid_t] {
        guard let found = try? await ProcessRunner.run("pgrep", ["-f", pattern], timeout: .seconds(20)),
            found.succeeded
        else {
            return []
        }
        return parsePIDs(found.stdout)
    }

    /// Split from the call so the parsing is exercised: a mis-parse here sends
    /// a signal to a process id nobody meant.
    static func parsePIDs(_ output: String) -> [pid_t] {
        output
            .split(whereSeparator: \.isNewline)
            .compactMap { pid_t($0.trimmingCharacters(in: .whitespaces)) }
            .filter { $0 > 1 }
    }

    func reapOrphans() async -> [String] {
        // Processes first: a leaked `tart run` outlives the VM it was running,
        // so reaping only the VMs left the process — and its vmnet interface —
        // behind on every daemon restart.
        await Self.reapRunProcesses()

        guard let command = try? await Self.tart(["list", "--format", "json"]),
            let result = try? await ProcessRunner.run(command.executable, command.arguments),
            result.succeeded,
            let data = result.stdout.data(using: .utf8),
            let entries = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else {
            return []
        }
        var reaped: [String] = []
        for name in Self.reapableVMNames(from: entries, protecting: config.baseImage) {
            await Self.forceTeardown(vmName: name)
            reaped.append(name)
        }
        return reaped
    }

    /// Which listed VMs are leaked job clones safe to delete.
    ///
    /// Split out from the `tart` call so the filtering can be tested: getting
    /// this wrong destroyed an 80GB base image that takes an hour to rebuild.
    static func reapableVMNames(from entries: [[String: Any]], protecting baseImage: String) -> [String] {
        entries.compactMap { entry in
            guard let name = entry["Name"] as? String ?? entry["name"] as? String else { return nil }
            guard name.hasPrefix(vmPrefix) else { return nil }
            // Belt and braces: never delete the image every job is cloned from,
            // whatever it happens to be called.
            guard name != baseImage else { return nil }
            return name
        }
    }
}
