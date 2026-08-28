import Darwin
import Foundation
import Testing

@testable import SaplingAgent
@testable import SaplingCore

/// Per-job resource sampling: what a VM is using against what it was given.
///
/// The measurements themselves are checked against this process, which is the
/// only VM-shaped thing a test machine is guaranteed to have. What the fixtures
/// cover is the part that cannot be guessed — the shape of `tart get` and
/// `container list` output, both captured from `mac-mini-01`.
@Suite("Job resource sampling")
struct JobStatsTests {
    /// Real output from `tart get sapling-job-sap-macos-aa2e8747 --format json`.
    ///
    /// Note `Size` is a string of gigabytes here and a number in `tart list`,
    /// and `Memory` is megabytes. Getting either wrong silently reports a VM
    /// with a thousandth of the memory it has.
    static let tartJSON = """
        {"Disk":140,"OS":"darwin","Size":"92.771","CPU":4,"DiskFormat":"raw",\
        "Memory":6144,"Display":"1024x768","State":"running","Running":true}
        """

    /// Real output from `container list --format json`, trimmed to the fields
    /// that carry the limits.
    static let containerJSON = """
        [{"configuration":{"id":"sapling-sap-linux-3a95b0cb","resources":\
        {"cpuOverhead":1,"cpus":2,"memoryInBytes":2147483648}},\
        "id":"sapling-sap-linux-3a95b0cb","status":{"networks":[],"state":"running"}}]
        """

    @Test("reads a VM's cores and memory from tart")
    func parsesTartLimits() throws {
        let limits = try #require(JobStatsCollector.parseTartLimits(Self.tartJSON))
        #expect(limits.cpuCount == 4)
        #expect(limits.memoryTotal == 6_442_450_944)
        // Disk is measured from the image rather than read from here, because
        // the field changes type between tart subcommands.
        #expect(limits.diskTotal == nil)
    }

    @Test("reads a container's cores and memory from container list")
    func parsesContainerLimits() throws {
        let record = try #require(ContainerListing.parse(Self.containerJSON).first)
        #expect(record.cpus == 2)
        #expect(record.memoryBytes == 2_147_483_648)
    }

    @Test("survives output that is not what we expect")
    func toleratesGarbage() {
        #expect(JobStatsCollector.parseTartLimits("") == nil)
        #expect(JobStatsCollector.parseTartLimits("not json") == nil)
        // An object with none of the fields we need is not a limit of zero.
        #expect(JobStatsCollector.parseTartLimits("{\"State\":\"running\"}") == nil)
    }

    @Test("a job with no environment reports empty rather than failing")
    func untrackedJobIsEmpty() async {
        let collector = JobStatsCollector()
        let resources = await collector.resources(jobID: "1", platform: .linux)
        #expect(resources.isEmpty)
        #expect(resources.environment == nil)
        #expect(!resources.isLive)
        #expect(resources.intervalSeconds == 5)
    }

    @Test("tracking a job names its environment before anything is measured")
    func trackingRegistersTheEnvironment() async {
        let collector = JobStatsCollector()
        await collector.track(jobID: "1", environment: "sapling-job-sap-macos-a1", platform: .macos)
        let resources = await collector.resources(jobID: "1", platform: .linux)
        #expect(resources.environment == "sapling-job-sap-macos-a1")
        // The platform comes from the registration, not the caller's guess.
        #expect(resources.platform == .macos)
        #expect(resources.isLive)
        #expect(resources.isEmpty)
    }

    /// A rebuilt VM is a different environment, not a continuation.
    ///
    /// The macOS provider rebuilds under a fresh name when a VM comes up
    /// without a network. Carrying the dead VM's figures over would report a
    /// job that used two VMs' worth of memory.
    @Test("a rebuilt VM replaces the one it was cloned to succeed")
    func rebuildReplacesTheEnvironment() async {
        let collector = JobStatsCollector()
        await collector.track(jobID: "1", environment: "sapling-job-sap-macos-a1", platform: .macos)
        await collector.track(jobID: "1", environment: "sapling-job-sap-macos-a1-r2", platform: .macos)
        let resources = await collector.resources(jobID: "1", platform: .macos)
        #expect(resources.environment == "sapling-job-sap-macos-a1-r2")
        #expect(await collector.liveEnvironments() == ["sapling-job-sap-macos-a1-r2"])
    }

    @Test("re-announcing the same environment does not reset it")
    func repeatedTrackingIsIdempotent() async {
        let collector = JobStatsCollector()
        await collector.track(jobID: "1", environment: "sapling-sap-linux-b2", platform: .linux)
        await collector.track(jobID: "1", environment: "sapling-sap-linux-b2", platform: .linux)
        #expect(await collector.liveEnvironments() == ["sapling-sap-linux-b2"])
    }
}

/// The kernel plumbing behind the per-job figures.
///
/// Exercised against this test process, because the alternative is a test that
/// only passes on a node with a job running.
@Suite("VM process sampling")
struct VMProcessSamplerTests {
    @Test("finds this process among the machine's own")
    func listsProcesses() {
        let pids = VMProcessSampler.liveProcessIDs()
        #expect(pids.contains(getpid()))
        #expect(!VMProcessSampler.executablePath(of: getpid()).isEmpty)
    }

    @Test("reads CPU time and memory for a process")
    func readsUsage() throws {
        let usage = try #require(VMProcessSampler.usage(of: getpid()))
        #expect(usage.cpuNanos > 0)
        // Physical footprint, not resident size: for a VM the two differ by
        // gigabytes, because RSS also counts the mapped disk image.
        #expect(usage.footprint > 0)
    }

    @Test("a process that has gone reports nothing rather than zero")
    func absentProcess() {
        // Nothing can be pid -1, and a sampler that reported zeroes for it
        // would draw an idle meter for a VM that has been torn down.
        #expect(VMProcessSampler.usage(of: -1) == nil)
    }

    /// A guest disk image is sparse.
    ///
    /// Its length is the capacity the guest was promised; its allocated blocks
    /// are what the node has actually spent. Reporting the length as usage
    /// would show a 140GB VM as full from birth.
    @Test("measures a sparse image by what it has allocated")
    func measuresSparseImages() throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("sapling-sparse-\(UUID().uuidString).img").path
        defer { try? FileManager.default.removeItem(atPath: path) }

        let descriptor = open(path, O_CREAT | O_RDWR, 0o600)
        try #require(descriptor >= 0)
        defer { close(descriptor) }
        // A gigabyte of nothing, with a kilobyte actually written.
        try #require(ftruncate(descriptor, 1_073_741_824) == 0)
        let payload = [UInt8](repeating: 0x5A, count: 1024)
        try #require(write(descriptor, payload, payload.count) == payload.count)
        try #require(fsync(descriptor) == 0)

        let size = try #require(VMProcessSampler.imageSize(at: path))
        #expect(size.capacity == 1_073_741_824)
        #expect(size.used > 0)
        #expect(size.used < size.capacity)
    }

    @Test("an image that isn't there reports nothing")
    func missingImage() {
        #expect(VMProcessSampler.imageSize(at: "/no/such/disk.img") == nil)
    }

    /// Whether any VM is running is not something a test machine can promise,
    /// so this only asserts that discovery is well-formed when it finds one.
    @Test("discovery names each environment after its image directory")
    func discoveryIsWellFormed() {
        for process in VMProcessSampler.discover() {
            #expect(!process.environment.isEmpty)
            #expect(
                process.imagePath.hasSuffix(process.environment + "/disk.img")
                    || process.imagePath.hasSuffix(process.environment + "/rootfs.ext4"))
        }
    }
}
