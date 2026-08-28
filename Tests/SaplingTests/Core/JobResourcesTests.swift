import Foundation
import Testing

@testable import SaplingCore

/// Reading a job's usage against its limits.
@Suite("Job resources")
struct JobResourcesTests {
    /// Timestamped on a whole second: the API encodes dates as ISO 8601, which
    /// drops the fraction, and a sample taken at `Date()` would not survive its
    /// own round trip.
    static let sample = JobResourceSample(
        sampledAt: Date(timeIntervalSince1970: 1_700_000_000),
        cpuCores: 3.2, memoryFootprint: 6_412_724_224, diskUsed: 96_000_000_000)

    static let limits = JobResourceLimits(
        cpuCount: 4, memoryTotal: 6_442_450_944, diskTotal: 140_000_000_000)

    private func response(
        limits: JobResourceLimits = JobResourcesTests.limits,
        samples: [JobResourceSample] = [JobResourcesTests.sample]
    ) -> JobResourcesResponse {
        JobResourcesResponse(
            jobID: "1", platform: .macos, environment: "sapling-job-sap-macos-a1",
            isLive: true, limits: limits, samples: samples)
    }

    @Test("reads each dimension as a fraction of what the job was given")
    func fractions() throws {
        let resources = response()
        let sample = try #require(resources.latest)
        #expect(resources.cpuUsage(sample) == 0.8)
        let memory = try #require(resources.memoryUsage(sample))
        #expect(abs(memory - 0.9954) < 0.001)
        let disk = try #require(resources.diskUsage(sample))
        #expect(abs(disk - 0.6857) < 0.001)
    }

    /// A guest can burn more CPU than the cores it was given — the same host
    /// process runs the VM's I/O threads — and a bar wider than the bar is not
    /// a thing a meter can draw.
    @Test("usage over the limit is reported as full, not as more than full")
    func clampsToTheLimit() throws {
        let resources = response(
            samples: [JobResourceSample(cpuCores: 7, memoryFootprint: 8_000_000_000, diskUsed: 0)])
        let sample = try #require(resources.latest)
        #expect(resources.cpuUsage(sample) == 1)
        #expect(resources.memoryUsage(sample) == 1)
    }

    /// A limit that could not be read is not a limit of zero: dividing by it
    /// would draw a full bar for a job using almost nothing.
    @Test("an unknown limit yields no fraction at all")
    func unknownLimits() throws {
        let resources = response(limits: JobResourceLimits())
        let sample = try #require(resources.latest)
        #expect(resources.cpuUsage(sample) == nil)
        #expect(resources.memoryUsage(sample) == nil)
        #expect(resources.diskUsage(sample) == nil)
    }

    @Test("a peak holds the highest of each dimension, not the newest sample")
    func peaks() {
        let early = JobResourceSample(
            sampledAt: Date(timeIntervalSince1970: 100),
            cpuCores: 3.9, memoryFootprint: 6_000_000_000, diskUsed: 90)
        let late = JobResourceSample(
            sampledAt: Date(timeIntervalSince1970: 200),
            cpuCores: 0.1, memoryFootprint: 6_400_000_000, diskUsed: 120)
        let peak = early.peak(with: late)
        #expect(peak.cpuCores == 3.9)
        #expect(peak.memoryFootprint == 6_400_000_000)
        #expect(peak.diskUsed == 120)
        #expect(peak.sampledAt == late.sampledAt)
    }

    @Test("survives the round trip the API puts it through")
    func codable() throws {
        let encoded = try SaplingJSON.encoder.encode(response())
        let decoded = try SaplingJSON.decoder.decode(JobResourcesResponse.self, from: encoded)
        #expect(decoded.environment == "sapling-job-sap-macos-a1")
        #expect(decoded.limits == Self.limits)
        #expect(decoded.samples == [Self.sample])
        #expect(decoded.isLive)
    }
}
