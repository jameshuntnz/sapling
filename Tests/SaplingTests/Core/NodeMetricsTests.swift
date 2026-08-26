import Foundation
import Testing

@testable import SaplingCore

/// These thresholds decide what the menu bar warns about.
///
/// The failure they exist to surface — two VMs sized to the whole of a 16GB machine — showed up as an SSH
/// timeout blamed on the base image, so getting them wrong means the meter stays quiet through exactly the
/// situation it is for.
@Suite("Node metrics")
struct NodeMetricsTests {
    static let gb: Int64 = 1_073_741_824

    @Test("reports usage as a fraction of capacity")
    func fractions() {
        let metrics = NodeMetrics(
            memoryTotal: 16 * Self.gb, memoryUsed: 12 * Self.gb,
            diskTotal: 200 * Self.gb, diskFree: 50 * Self.gb)
        #expect(abs(metrics.memoryUsage - 0.75) < 0.001)
        #expect(abs(metrics.diskUsage - 0.75) < 0.001)
    }

    /// A machine with no reported capacity must read as 0, not crash or show
    /// something nonsensical.
    @Test("handles a node reporting nothing")
    func emptyMetrics() {
        let metrics = NodeMetrics()
        #expect(metrics.memoryUsage == 0)
        #expect(metrics.diskUsage == 0)
        #expect(metrics.loadFactor == 0)
        #expect(!metrics.isUnderMemoryPressure)
    }

    /// Any swap in use is unambiguous: the machine wanted more than it had.
    @Test("treats swap in use as pressure")
    func swapMeansPressure() {
        let metrics = NodeMetrics(memoryTotal: 16 * Self.gb, swapUsed: 1 * Self.gb)
        #expect(metrics.isUnderMemoryPressure)
    }

    /// Compression is macOS working normally.
    ///
    /// Flagging it at any level would mean the warning is always on, and a warning that is always on is not a
    /// warning.
    @Test("ignores routine compression")
    func modestCompressionIsNormal() {
        let metrics = NodeMetrics(
            memoryTotal: 16 * Self.gb, memoryUsed: 8 * Self.gb,
            memoryCompressed: Self.gb)  // 1 of 16 — under an eighth
        #expect(!metrics.isUnderMemoryPressure)
    }

    @Test("flags compression past an eighth of memory")
    func heavyCompressionIsPressure() {
        let metrics = NodeMetrics(
            memoryTotal: 16 * Self.gb, memoryUsed: 14 * Self.gb,
            memoryCompressed: 4 * Self.gb)
        #expect(metrics.isUnderMemoryPressure)
    }

    /// Load against cores says whether work is queueing, which a CPU
    /// percentage hides once it pins at 100.
    @Test("expresses load relative to core count")
    func loadFactor() {
        let busy = NodeMetrics(loadAverage: [10, 8, 6], cpuCount: 10)
        #expect(abs(busy.loadFactor - 1.0) < 0.001)

        let queueing = NodeMetrics(loadAverage: [20, 18, 15], cpuCount: 10)
        #expect(queueing.loadFactor > 1.5)
    }

    /// Usage is clamped: a machine reporting more used than it has should show
    /// a full bar, not one overflowing its track.
    @Test("clamps usage above capacity")
    func clampsOverCapacity() {
        let metrics = NodeMetrics(memoryTotal: 8 * Self.gb, memoryUsed: 10 * Self.gb)
        #expect(metrics.memoryUsage == 1.0)
    }

    @Test("survives the wire")
    func roundTrips() throws {
        let original = NodeMetrics(
            cpuUsage: 0.42, loadAverage: [2.5, 2.1, 1.8], cpuCount: 10,
            memoryTotal: 16 * Self.gb, memoryUsed: 9 * Self.gb,
            memoryCompressed: 2 * Self.gb, swapUsed: 400 * 1_048_576,
            swapTotal: 2 * Self.gb, diskTotal: 200 * Self.gb, diskFree: 110 * Self.gb)

        let data = try SaplingJSON.encoder.encode(original)
        let decoded = try SaplingJSON.decoder.decode(NodeMetrics.self, from: data)

        // Not compared whole: ISO8601 carries no fractional seconds, so the
        // timestamp comes back rounded. Irrelevant for samples five seconds
        // apart, but it means Equatable can't be used across the wire.
        #expect(abs(decoded.sampledAt.timeIntervalSince(original.sampledAt)) < 1)
        #expect(decoded.cpuUsage == original.cpuUsage)
        #expect(decoded.loadAverage == original.loadAverage)
        #expect(decoded.memoryUsed == original.memoryUsed)
        #expect(decoded.memoryCompressed == original.memoryCompressed)
        #expect(decoded.swapUsed == original.swapUsed)
        #expect(decoded.diskFree == original.diskFree)
        #expect(decoded.isUnderMemoryPressure)
    }
}
