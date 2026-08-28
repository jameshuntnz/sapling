import Foundation
import SaplingCore

/// Watching and repairing the network Linux jobs run on.
///
/// Apple's `container` has one failure mode that matters here and it is
/// invisible from inside the tool: its vmnet network can go away while the
/// system still reports itself running. Containers started afterwards come up,
/// are assigned addresses on the dead subnet, and cannot resolve DNS. Measured
/// on the node, the only repair that works is recreating the whole thing.
extension ContainerProvider {
    /// How long to wait for a starting container to report an address.
    ///
    /// Generous: the address appears within a second or two of the container
    /// starting, but a slow image pull can precede it.
    static let addressTimeout: Duration = .seconds(120)

    /// The address Apple `container` assigned this container, once it has one.
    ///
    /// - Parameters:
    ///   - name: The container's name.
    ///   - timeout: How long to keep asking.
    /// - Returns: The address, or `nil` if none appeared — in which case
    ///   nothing downstream watches this container's network, which is
    ///   strictly better than watching the wrong one.
    static func address(ofContainer name: String, within timeout: Duration) async -> String? {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            let record = await ContainerListing.current().first { $0.id == name }
            if let address = record?.address, !address.isEmpty { return address }
            try? await Task.sleep(for: .seconds(3))
        }
        return nil
    }

    /// Recreate the container network, if doing so won't take a live job down.
    ///
    /// Restarting is the only repair that works — `container system status`
    /// reports `running` for a system whose bridge has gone, and containers
    /// started in that state come up, get addresses, and cannot resolve DNS.
    /// It is also a blunt instrument: it stops *every* container.
    ///
    /// So the guard is on health, not on presence. Another container that is
    /// still reachable is a job running fine, and killing it to repair someone
    /// else's network is not a trade worth making; another container that is
    /// already orphaned has nothing left to lose. Presence alone was the wrong
    /// test: when a VM teardown takes the bridge, *every* container on it is
    /// orphaned at once, and refusing to repair because one of them exists
    /// leaves the node broken for the next job too.
    /// - Parameters:
    ///   - name: This job's own container, which is on its way out and does
    ///     not count either way.
    ///   - events: Where the decision is recorded.
    static func repairNetwork(after name: String?, events: any EventSink) async {
        let bridges = (try? await BridgeTable.current()) ?? []
        let live = liveBystanders(
            among: await ContainerListing.current(), bridges: bridges, sparing: name)
        guard live.isEmpty else {
            await events.log(
                """
                the container network needs recreating, but \(live.count) other container(s) \
                still have a working one and a restart would kill them; leaving it for the \
                next idle moment
                """)
            return
        }
        await events.log("recreating the container network (`container system` restart)")
        await restartContainerSystem()
    }

    /// Containers a restart would harm: running, not this job's own, and still
    /// on a network that works.
    ///
    /// Split from the call so the judgement can be tested — it decides whether
    /// a broken node repairs itself now or stays broken for the next job.
    /// A container with no address at all counts as live, because "we could
    /// not tell" is not grounds for killing it.
    static func liveBystanders(
        among containers: [ContainerRecord], bridges: [HostBridge], sparing name: String?
    ) -> [ContainerRecord] {
        containers.filter { container in
            guard container.isRunning, container.id != name else { return false }
            guard let address = container.address else { return true }
            return JobNetwork.reachability(of: address, in: bridges) != .orphaned(address: address)
        }
    }

    private static func restartContainerSystem() async {
        for arguments in [["system", "stop"], ["system", "start"]] {
            guard let command = try? await SessionCommand.invocation("container", arguments) else {
                return
            }
            _ = try? await ProcessRunner.run(
                command.executable, command.arguments, timeout: .seconds(120))
        }
    }
}
