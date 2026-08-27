import Foundation
import SaplingAgent
import SaplingCore

/// Checks that every running job environment is on a network that exists.
///
/// Nothing asked this before. During an outage in which no job on the node
/// could reach GitHub, `sapling doctor` reported `ok` for pf, for `container`
/// and for Tart; `container system status` said `running`; and `container
/// list` printed an address for a container that could not resolve DNS. Every
/// signal was green, and every one of them was reporting what had been
/// configured rather than what was true.
///
/// The one question that separates the two: does a host interface own the
/// gateway for the subnet this environment is on?
public struct JobNetworkStep: InstallStep {
    /// Name shown by `install` and `doctor`.
    public let name = "Job networking"

    /// Creates the step.
    public init() {}

    /// Reports whether running environments still have the network they think
    /// they have.
    public func check() async -> StepState {
        let report = await NetworkDoctor.inspect()
        guard report.orphans.isEmpty else {
            return .failed(report.repairAdvice)
        }
        return .ok(report.summary)
    }
}
