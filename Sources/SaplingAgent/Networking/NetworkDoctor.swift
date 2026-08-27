import Foundation
import SaplingCore

/// One running job environment and whether its network actually exists.
public struct EnvironmentNetwork: Sendable {
    /// Container or VM name.
    public let name: String
    /// Which provider owns it.
    public let platform: JobPlatform
    /// The address it believes it has.
    public let address: String
    /// What the host's bridge table says about that address.
    public let reachability: NetworkReachability

    /// Whether this environment holds an address on a network that is gone.
    public var isOrphaned: Bool {
        if case .orphaned = reachability { return true }
        return false
    }
}

/// Answers one question: does a host interface own this subnet's gateway?
///
/// Nothing used to ask it. Throughout an outage where no job could reach
/// GitHub, `sapling doctor` reported `ok` for pf, for `container` and for
/// Tart; `container system status` said `running`; and `container list`
/// printed an address for a container that could not resolve DNS. Every
/// available health signal was green and every one of them was reporting
/// intent rather than fact.
///
/// This compares what the tools claim against the host's interface list,
/// which is the only place the two can disagree — and when they do, the
/// interface list is right.
public enum NetworkDoctor {
    /// What the host and the two tools say, side by side.
    public struct Report: Sendable {
        /// Bridges that exist on the host right now.
        public let bridges: [HostBridge]
        /// Running environments, each judged against those bridges.
        public let environments: [EnvironmentNetwork]

        /// Environments holding an address on a network that no longer exists.
        public var orphans: [EnvironmentNetwork] { environments.filter(\.isOrphaned) }

        /// One line for `doctor`, naming the bridges rather than just counting them.
        public var summary: String {
            guard !bridges.isEmpty else {
                return environments.isEmpty
                    ? "no job environment running, so no bridge yet — one appears with the first job"
                    : "no bridge interfaces at all, with \(environments.count) environment(s) running"
            }
            let named = bridges.map { "\($0.name) \($0.address)" }.joined(separator: ", ")
            return "\(named) — \(environments.count) environment(s) on them"
        }

        /// What to tell an operator whose environments have been orphaned.
        public var repairAdvice: String {
            let names = orphans.map { "\($0.name) (\($0.address))" }.joined(separator: ", ")
            return """
                \(names) hold addresses no host interface owns, so they have no network at \
                all — their own tooling still reports them running. Repair with \
                `container system stop && container system start`, which recreates the \
                bridge; running jobs in those environments are already lost.
                """
        }
    }

    /// Read the host and both providers, and line the answers up.
    ///
    /// Never throws: this is diagnostics, and a report that says "could not
    /// tell" is useful where a thrown error is not.
    public static func inspect() async -> Report {
        let bridges = (try? await BridgeTable.current()) ?? []
        var environments: [EnvironmentNetwork] = []

        for container in await ContainerListing.current() where container.isRunning {
            guard let address = container.address else { continue }
            environments.append(
                EnvironmentNetwork(
                    name: container.id,
                    platform: .linux,
                    address: address,
                    reachability: JobNetwork.reachability(of: address, in: bridges)
                ))
        }

        for vm in await TartListing.current() where vm.isRunning {
            guard let address = await TartProvider.address(ofVM: vm.name) else { continue }
            environments.append(
                EnvironmentNetwork(
                    name: vm.name,
                    platform: .macos,
                    address: address,
                    reachability: JobNetwork.reachability(of: address, in: bridges)
                ))
        }

        return Report(bridges: bridges, environments: environments)
    }
}
