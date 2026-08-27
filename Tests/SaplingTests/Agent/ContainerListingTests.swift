import Foundation
import Testing

@testable import SaplingAgent
@testable import SaplingCore

/// Parsed against real output captured from `mac-mini-01`, because the shape
/// is not what the column headers suggest: `container list` prints a `NAME`
/// column, and the JSON has no `name` field at all — the id is the name, and
/// the address lives under `status.networks`.
@Suite("Provider inventories")
struct ContainerListingTests {
    static let containerJSON = """
        [{"configuration":{"id":"sapling-sap-linux-3a95b0cb","image":{"reference":\
        "sapling-img-android:05da0bdbfe5c"},"networks":[{"network":"default"}]},\
        "id":"sapling-sap-linux-3a95b0cb","status":{"networks":[{"hostname":"sap",\
        "ipv4Address":"192.168.64.4/24","ipv4Gateway":"192.168.64.1","mtu":1280,\
        "network":"default"}],"state":"running"}},\
        {"configuration":{"id":"buildkit"},"id":"buildkit","status":{"networks":[],\
        "state":"stopped"}}]
        """

    @Test("reads the id, state and address of each container")
    func parsesContainers() {
        let records = ContainerListing.parse(Self.containerJSON)
        #expect(records.count == 2)
        #expect(records[0].id == "sapling-sap-linux-3a95b0cb")
        #expect(records[0].isRunning)
        // The prefix is stripped: everything downstream compares against
        // bridge subnets, which want a bare address.
        #expect(records[0].address == "192.168.64.4")
        #expect(records[0].gateway == "192.168.64.1")
        #expect(!records[1].isRunning)
        #expect(records[1].address == nil)
    }

    /// The state this whole redesign exists for: `container` reports a
    /// perfectly ordinary running container with an address, while the host
    /// has no interface on that subnet.
    @Test("a running container with a dead bridge reads as orphaned")
    func orphanedContainerIsDetected() {
        guard let record = ContainerListing.parse(Self.containerJSON).first,
            let address = record.address
        else {
            Issue.record("expected a container with an address")
            return
        }
        #expect(record.isRunning)
        #expect(JobNetwork.reachability(of: address, in: []) == .orphaned(address: "192.168.64.4"))
    }

    @Test("survives output that is not what we expect")
    func toleratesGarbage() {
        #expect(ContainerListing.parse("").isEmpty)
        #expect(ContainerListing.parse("not json").isEmpty)
        #expect(ContainerListing.parse("{}").isEmpty)
        #expect(ContainerListing.parse("[{}]").isEmpty)
    }

    @Test("reads Tart's inventory, running flag included")
    func parsesTartList() {
        let json = """
            [{"Name":"sapling-macos-base","Running":false,"State":"stopped","Source":"local"},
             {"Name":"sapling-job-sap-macos-1","Running":true,"State":"running","Source":"local"}]
            """
        let vms = TartListing.parse(json)
        #expect(vms.count == 2)
        #expect(vms.filter(\.isRunning).map(\.name) == ["sapling-job-sap-macos-1"])
    }

    @Test("Tart output that is not what we expect yields nothing")
    func toleratesTartGarbage() {
        #expect(TartListing.parse("").isEmpty)
        #expect(TartListing.parse("[{\"Size\":86}]").isEmpty)
    }
}
