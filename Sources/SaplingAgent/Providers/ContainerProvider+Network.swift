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
    /// It is also a blunt instrument: it stops *every* container, so it waits
    /// until this job's own container is the last one. With `max_concurrent`
    /// above 1 that means a broken network is repaired when the node next goes
    /// quiet rather than immediately, which is the right trade — the
    /// alternative is killing a job that is running fine.
    static func repairNetwork(after name: String, events: any EventSink) async {
        let others = await ContainerListing.current().filter { $0.isRunning && $0.id != name }
        guard others.isEmpty else {
            await events.log(
                """
                the container network needs recreating, but \(others.count) other container(s) \
                are still running and a restart would kill them; leaving it for the next \
                idle moment
                """)
            return
        }
        await events.log("recreating the container network (`container system` restart)")
        for arguments in [["system", "stop"], ["system", "start"]] {
            guard let command = try? await SessionCommand.invocation("container", arguments) else {
                return
            }
            _ = try? await ProcessRunner.run(
                command.executable, command.arguments, timeout: .seconds(120))
        }
    }
}
