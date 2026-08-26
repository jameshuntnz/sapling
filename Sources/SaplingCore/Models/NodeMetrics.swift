import Foundation

/// A snapshot of what the node's hardware is doing.
///
/// Sized around the failures this project has actually had. A build node runs
/// out of three things — memory, disk, and patience — and on a 16GB machine
/// running two VMs the first is invisible until it surfaces somewhere
/// misleading: a VM too slow to answer SSH before its boot timeout, reported
/// as a problem with the base image.
///
/// Raw figures rather than a single "health" score, because what counts as
/// healthy depends on what the node is doing. Judging that is the reader's
/// job, and a meter is better at it than an arbitrary threshold.
public struct NodeMetrics: Codable, Sendable, Hashable {
    /// When these were sampled.
    public var sampledAt: Date

    /// Fraction of CPU in use across all cores, 0 to 1.
    ///
    /// Measured from the change in CPU ticks since the previous sample, so the
    /// first sample after a restart has nothing to compare against and reports
    /// zero.
    public var cpuUsage: Double
    /// One, five and fifteen minute load averages.
    ///
    /// More telling than instantaneous CPU on a build node: a load well above
    /// the core count means work is queueing, which a percentage hides.
    public var loadAverage: [Double]
    /// Physical cores available.
    public var cpuCount: Int

    /// Physical memory, in bytes.
    public var memoryTotal: Int64
    /// Memory in use: active, wired and compressed.
    ///
    /// Excludes inactive pages, which macOS can reclaim on demand and which
    /// would otherwise make an idle machine look full.
    public var memoryUsed: Int64
    /// Memory macOS has compressed to avoid swapping.
    ///
    /// Rising compression is the first sign of pressure, well before swap.
    public var memoryCompressed: Int64
    /// Swap in use, in bytes.
    ///
    /// Anything sustained here means over-commitment.
    public var swapUsed: Int64
    /// Swap configured, in bytes.
    public var swapTotal: Int64

    /// Capacity of the data volume, in bytes.
    public var diskTotal: Int64
    /// Space available on the data volume, in bytes.
    public var diskFree: Int64

    /// Creates a metrics snapshot.
    public init(
        sampledAt: Date = Date(),
        cpuUsage: Double = 0,
        loadAverage: [Double] = [],
        cpuCount: Int = 0,
        memoryTotal: Int64 = 0,
        memoryUsed: Int64 = 0,
        memoryCompressed: Int64 = 0,
        swapUsed: Int64 = 0,
        swapTotal: Int64 = 0,
        diskTotal: Int64 = 0,
        diskFree: Int64 = 0
    ) {
        self.sampledAt = sampledAt
        self.cpuUsage = cpuUsage
        self.loadAverage = loadAverage
        self.cpuCount = cpuCount
        self.memoryTotal = memoryTotal
        self.memoryUsed = memoryUsed
        self.memoryCompressed = memoryCompressed
        self.swapUsed = swapUsed
        self.swapTotal = swapTotal
        self.diskTotal = diskTotal
        self.diskFree = diskFree
    }

    /// Fraction of memory in use, 0 to 1.
    public var memoryUsage: Double {
        memoryTotal > 0 ? min(1, Double(memoryUsed) / Double(memoryTotal)) : 0
    }

    /// Fraction of the data volume in use, 0 to 1.
    public var diskUsage: Double {
        diskTotal > 0 ? min(1, Double(diskTotal - diskFree) / Double(diskTotal)) : 0
    }

    /// Load relative to core count, where 1 means fully committed.
    public var loadFactor: Double {
        guard cpuCount > 0, let oneMinute = loadAverage.first else { return 0 }
        return oneMinute / Double(cpuCount)
    }

    /// Whether the machine is paging or compressing enough to be worth saying.
    ///
    /// Swap in use is the unambiguous signal. Compression alone is normal on
    /// macOS, so it only counts once it passes an eighth of physical memory —
    /// below that it is the OS doing its job, not a warning.
    public var isUnderMemoryPressure: Bool {
        if swapUsed > 0 { return true }
        guard memoryTotal > 0 else { return false }
        return memoryCompressed > memoryTotal / 8
    }
}

/// Metrics over time, for a chart.
public struct MetricsHistoryResponse: Codable, Sendable {
    /// Samples, oldest first.
    public var samples: [NodeMetrics]
    /// Gap between samples, in seconds.
    public var intervalSeconds: Int

    /// Creates a history response.
    public init(samples: [NodeMetrics], intervalSeconds: Int) {
        self.samples = samples
        self.intervalSeconds = intervalSeconds
    }
}
