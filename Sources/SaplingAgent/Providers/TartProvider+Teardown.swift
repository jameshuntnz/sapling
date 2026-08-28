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
        for arguments in [["stop", "--timeout", "30", vmName], ["delete", vmName]] {
            guard let command = try? await tart(arguments) else { return }
            _ = try? await ProcessRunner.run(
                command.executable, command.arguments, timeout: .seconds(60))
        }
        await killRunProcesses(forVM: vmName)
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
        guard let found = try? await ProcessRunner.run("pgrep", ["-f", pattern], timeout: .seconds(20)),
            found.succeeded
        else {
            return  // pgrep exits non-zero when nothing matched, which is the common case.
        }
        for pid in parsePIDs(found.stdout) {
            Foundation.kill(pid, SIGTERM)
        }
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
