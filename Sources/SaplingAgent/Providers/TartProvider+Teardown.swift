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
    }

    func reapOrphans() async -> [String] {
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
