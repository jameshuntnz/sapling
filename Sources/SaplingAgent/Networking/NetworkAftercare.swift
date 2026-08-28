import Foundation
import SaplingCore

/// Checks that an environment going away did not take another one's network
/// with it.
///
/// Measured on `mac-mini-01`, sampling every two seconds:
///
/// ```
/// 11:42:05  bridges=[bridge100:192.168.64.1]   a container, working
/// 11:44:20  bridges=[]                          <- all of them, at once
/// 11:46:54  bridges=[bridge100:192.168.65.1]   the next VM, fresh bridge100
/// ```
///
/// 11:44:18 and 11:44:19 are `cleanup_started` and `cleanup_finished` for a
/// macOS VM. Tearing it down destroyed the bridge a *container* was using, and
/// that container's job died mid-step — which is the failure that started all
/// of this, and which reads on GitHub as "the self-hosted runner lost
/// communication with the server".
///
/// A normal teardown does not do this: with a healthy VM and a healthy
/// container running side by side, `tart stop` and `tart delete` were measured
/// taking only the VM's own `bridge101` and leaving the container on
/// `bridge100` reaching the internet throughout. The damage came from tearing
/// down a VM that was already in a broken state — which is what `VMBootProcess`
/// now catches in seconds rather than in five minutes.
///
/// The precise vmnet mechanism is still unidentified, so this is a check
/// rather than a prevention: after every VM teardown, ask whether anything
/// else lost its network, and repair it before the next job walks into it.
enum NetworkAftercare {
    /// Run after a macOS VM has been torn down.
    ///
    /// Cheap — one `ifconfig` and one `container list` — and it runs off the
    /// job's critical path, after the outcome is already decided.
    /// - Parameter events: Where any damage found is recorded.
    static func afterVMTeardown(events: any EventSink) async {
        let report = await NetworkDoctor.inspect()
        let stranded = report.orphans.filter { $0.platform == .linux }
        guard !stranded.isEmpty else { return }

        let names = stranded.map { "\($0.name) (\($0.address))" }.joined(separator: ", ")
        await events.log(
            """
            tearing this VM down took the network out from under \(names) — they hold \
            addresses no host interface owns any more. Repairing so the next Linux job \
            does not start into the same dead bridge.
            """)
        await ContainerProvider.repairNetwork(after: nil, events: events)
    }
}
