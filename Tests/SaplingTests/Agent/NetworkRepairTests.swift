import Foundation
import Testing

@testable import SaplingAgent

/// Recreating the container network stops *every* container, so the decision
/// to do it is the decision to kill whatever else is running.
///
/// Presence was the wrong test. When a VM teardown takes the bridge, every
/// container on it is orphaned at once — and refusing to repair because one of
/// them still exists leaves the node broken for the next job as well, which is
/// how one lost bridge became an evening of failures.
@Suite("Container network repair")
struct NetworkRepairTests {
    static let bridges = [
        HostBridge(name: "bridge100", address: "192.168.64.1", subnet: "192.168.64.0/24", prefix: 24)
    ]

    static func container(_ id: String, _ address: String?, running: Bool = true) -> ContainerRecord {
        ContainerRecord(
            id: id, state: running ? "running" : "stopped", address: address, gateway: nil)
    }

    @Test("a container still on a working bridge blocks the repair")
    func healthyBystanderBlocksRepair() {
        let live = ContainerProvider.liveBystanders(
            among: [Self.container("other", "192.168.64.5")],
            bridges: Self.bridges,
            sparing: "mine")
        #expect(live.map(\.id) == ["other"])
    }

    /// The observed case: the bridge is gone, so every container on it is
    /// already dead and there is nothing left to protect.
    @Test("orphaned containers do not block the repair")
    func orphansDoNotBlockRepair() {
        let live = ContainerProvider.liveBystanders(
            among: [
                Self.container("other", "192.168.64.5"),
                Self.container("mine", "192.168.64.8"),
            ],
            bridges: [],
            sparing: "mine")
        #expect(live.isEmpty)
    }

    @Test("this job's own container and stopped ones are not bystanders")
    func ignoresSelfAndStopped() {
        let live = ContainerProvider.liveBystanders(
            among: [
                Self.container("mine", "192.168.64.8"),
                Self.container("done", "192.168.64.9", running: false),
            ],
            bridges: Self.bridges,
            sparing: "mine")
        #expect(live.isEmpty)
    }

    /// "We could not tell" is not grounds for killing someone else's job.
    @Test("a container with no address counts as live")
    func unknownAddressIsProtected() {
        let live = ContainerProvider.liveBystanders(
            among: [Self.container("other", nil)], bridges: [], sparing: "mine")
        #expect(live.map(\.id) == ["other"])
    }

    /// Nothing running means nothing to lose, which is the common case with
    /// `max_concurrent = 1`.
    @Test("an empty node repairs unconditionally")
    func emptyNodeRepairs() {
        #expect(ContainerProvider.liveBystanders(among: [], bridges: [], sparing: nil).isEmpty)
    }
}
