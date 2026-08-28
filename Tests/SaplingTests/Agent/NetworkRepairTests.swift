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
            id: id, state: running ? "running" : "stopped", address: address, gateway: nil,
            cpus: nil, memoryBytes: nil)
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

/// A container killed while its network was already gone was killed *by* the
/// network going, whatever signal actually reached it.
///
/// Recreating the container network SIGKILLs everything on it, so the repair
/// for one job's lost bridge lands before the watchdog has finished confirming
/// it for another. The job then carried "container exited with status 137",
/// which names the signal and not the cause.
@Suite("Killed container diagnosis")
struct KilledContainerTests {
    @Test("an address with no bridge behind it explains the kill")
    func orphanedAddressExplainsKill() {
        let reachability = JobNetwork.reachability(of: "192.168.64.10", in: [])
        #expect(reachability == .orphaned(address: "192.168.64.10"))
        let reason = JobNetwork.lossReason(address: "192.168.64.10")
        #expect(reason.contains("192.168.64.10"))
        #expect(!reason.contains("137"))
    }

    /// A container that failed on its own, with its network intact, keeps its
    /// own exit status — this must not relabel ordinary build failures.
    @Test("a working network leaves the exit status alone")
    func healthyNetworkIsNotRelabelled() {
        let bridges = [
            HostBridge(
                name: "bridge100", address: "192.168.64.1", subnet: "192.168.64.0/24", prefix: 24)
        ]
        #expect(
            JobNetwork.reachability(of: "192.168.64.10", in: bridges)
                == .live(gateway: "192.168.64.1"))
    }
}

/// Recreating the container network was watched taking a running macOS VM's
/// bridge down with it, turning one failed job into two.
///
/// The guard used to consider containers only, on the assumption that
/// recreating the *container* network could not affect a VM. It can.
@Suite("Repair spares running VMs")
struct RepairSparesVMsTests {
    static let bridges = [
        HostBridge(name: "bridge100", address: "192.168.65.1", subnet: "192.168.65.0/24", prefix: 24)
    ]

    /// A VM on a working bridge is a job running fine.
    @Test("a reachable VM address counts as live")
    func reachableVMIsLive() {
        #expect(
            JobNetwork.reachability(of: "192.168.65.80", in: Self.bridges)
                == .live(gateway: "192.168.65.1"))
    }

    /// One already stranded has nothing left to lose, so it must not block a
    /// repair the rest of the node needs.
    @Test("an orphaned VM address does not count as live")
    func orphanedVMIsNotLive() {
        #expect(
            JobNetwork.reachability(of: "192.168.65.80", in: [])
                == .orphaned(address: "192.168.65.80"))
    }

    /// Both platforms are consulted before anything is restarted.
    @Test("the repair asks about VMs as well as containers")
    func repairConsultsBothPlatforms() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(
                "Sources/SaplingAgent/Providers/ContainerProvider+Network.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        guard let vms = source.range(of: "liveVirtualMachines(bridges:"),
            let restart = source.range(of: "await restartContainerSystem()")
        else {
            Issue.record("the repair no longer checks VMs or no longer restarts")
            return
        }
        #expect(vms.lowerBound < restart.lowerBound, "VMs must be checked before the restart")
    }
}

/// Both platforms rebuild an environment that comes up without a network.
///
/// The asymmetry was real and it cost a job: a container failed twelve seconds
/// in and failed the job outright, while a VM in the same state got three
/// attempts.
@Suite("Retry symmetry")
struct RetrySymmetryTests {
    @Test("containers get the same number of attempts as VMs")
    func attemptsMatch() {
        #expect(ContainerProvider.attachAttempts == TartProvider.attachAttempts)
        #expect(ContainerProvider.attachAttempts > 1)
    }
}
