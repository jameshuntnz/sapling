import Foundation

/// One measurement of what a single job's environment is using.
///
/// Measured from the host, of the VM process that backs the environment —
/// there is no agent inside the guest and nothing is asked of it. That choice
/// decides what these numbers mean, so read `memoryFootprint` carefully
/// before treating a full-looking meter as a problem.
public struct JobResourceSample: Codable, Sendable, Hashable {
    /// When this was sampled.
    public var sampledAt: Date

    /// Cores busy, where `1.0` is one core saturated.
    ///
    /// Derived from the change in the VM process's CPU time between samples,
    /// like `NodeMetrics.cpuUsage`, so the first sample of an environment has
    /// nothing to compare against and reports zero. It can exceed the cores
    /// the guest was given: the same process also runs the VM's own I/O
    /// threads, and that work is real.
    public var cpuCores: Double

    /// Physical memory the host has committed to this environment, in bytes.
    ///
    /// This is the host's footprint for the VM, not the guest's own idea of
    /// how much it is using — nothing here can see inside the guest. A guest
    /// puts its spare memory to work as page cache and does not hand the pages
    /// back, so this climbs towards whatever the environment was given and
    /// stays there. Near-full is therefore the resting state of a healthy VM,
    /// not a warning; what it tells you is what the *node* has spent, which is
    /// the figure that matters on a 16GB machine running two of these.
    public var memoryFootprint: Int64

    /// Bytes the environment's disk image occupies on the host.
    ///
    /// The image is sparse, so this is what has actually been allocated rather
    /// than the size the guest sees. For a macOS VM it starts at the size of
    /// the base image it was cloned from.
    public var diskUsed: Int64

    /// Creates a sample.
    public init(
        sampledAt: Date = Date(),
        cpuCores: Double = 0,
        memoryFootprint: Int64 = 0,
        diskUsed: Int64 = 0
    ) {
        self.sampledAt = sampledAt
        self.cpuCores = cpuCores
        self.memoryFootprint = memoryFootprint
        self.diskUsed = diskUsed
    }

    /// The larger of two samples in every dimension, for tracking peaks.
    ///
    /// - Parameter other: The sample to fold in.
    /// - Returns: A sample holding each dimension's maximum, timestamped from
    ///   whichever sample is newer.
    public func peak(with other: JobResourceSample) -> JobResourceSample {
        JobResourceSample(
            sampledAt: max(sampledAt, other.sampledAt),
            cpuCores: Swift.max(cpuCores, other.cpuCores),
            memoryFootprint: Swift.max(memoryFootprint, other.memoryFootprint),
            diskUsed: Swift.max(diskUsed, other.diskUsed))
    }
}

/// What a job's environment was given, to measure its usage against.
///
/// Read back from `tart` or `container` rather than taken from Sapling's
/// config: both `cpu_count` and `memory_gb` may be unset, in which case the
/// tool picks — and Apple's `container` picks 1GB, which is the default that
/// has already killed builds here. A limit that came from the tool is the one
/// the environment is actually held to.
public struct JobResourceLimits: Codable, Sendable, Hashable {
    /// Cores the guest was given, or `nil` if that could not be read.
    public var cpuCount: Int?
    /// Memory the guest was given, in bytes, or `nil` if unknown.
    public var memoryTotal: Int64?
    /// Capacity of the guest's disk, in bytes, or `nil` if unknown.
    ///
    /// For a Linux container this is the virtual size of a sparse image, which
    /// is far larger than anything the node could actually supply — the
    /// container is limited by the host volume, not by this.
    public var diskTotal: Int64?

    /// Creates a set of limits.
    public init(cpuCount: Int? = nil, memoryTotal: Int64? = nil, diskTotal: Int64? = nil) {
        self.cpuCount = cpuCount
        self.memoryTotal = memoryTotal
        self.diskTotal = diskTotal
    }
}

/// Response body for `GET /api/v1/jobs/:id/resources`.
///
/// Empty rather than absent for a job with no environment: a queued job, or
/// one that finished before this build of the daemon started, is a normal
/// thing to ask about and not an error.
public struct JobResourcesResponse: Codable, Sendable {
    /// The job these belong to.
    public var jobID: String
    /// Which provider ran it.
    public var platform: JobPlatform
    /// The VM or container name, once one exists.
    public var environment: String?
    /// Whether the environment is still up and being sampled.
    public var isLive: Bool
    /// What the environment was given.
    public var limits: JobResourceLimits
    /// The highest value seen in each dimension over the whole run.
    ///
    /// Kept separately from `samples` because the history is a short window
    /// and the peak is the part you want hours later: whether the job ever
    /// came near what it was given.
    public var peak: JobResourceSample?
    /// Recent samples, oldest first.
    public var samples: [JobResourceSample]
    /// Gap between samples, in seconds.
    public var intervalSeconds: Int

    /// Creates a resource report.
    public init(
        jobID: String,
        platform: JobPlatform,
        environment: String? = nil,
        isLive: Bool = false,
        limits: JobResourceLimits = JobResourceLimits(),
        peak: JobResourceSample? = nil,
        samples: [JobResourceSample] = [],
        intervalSeconds: Int = 5
    ) {
        self.jobID = jobID
        self.platform = platform
        self.environment = environment
        self.isLive = isLive
        self.limits = limits
        self.peak = peak
        self.samples = samples
        self.intervalSeconds = intervalSeconds
    }

    /// The most recent sample, if there is one.
    public var latest: JobResourceSample? { samples.last }

    /// Whether anything was measured at all.
    public var isEmpty: Bool { samples.isEmpty }

    /// Fraction of the cores it was given that a sample was using, 0 to 1.
    ///
    /// - Parameter sample: The sample to judge.
    /// - Returns: The fraction, or `nil` when the core count isn't known.
    public func cpuUsage(_ sample: JobResourceSample) -> Double? {
        guard let cpuCount, cpuCount > 0 else { return nil }
        return min(1, sample.cpuCores / Double(cpuCount))
    }

    /// Fraction of its memory a sample had committed, 0 to 1.
    ///
    /// - Parameter sample: The sample to judge.
    /// - Returns: The fraction, or `nil` when the limit isn't known.
    public func memoryUsage(_ sample: JobResourceSample) -> Double? {
        guard let total = limits.memoryTotal, total > 0 else { return nil }
        return min(1, Double(sample.memoryFootprint) / Double(total))
    }

    /// Fraction of its disk a sample had allocated, 0 to 1.
    ///
    /// - Parameter sample: The sample to judge.
    /// - Returns: The fraction, or `nil` when the capacity isn't known.
    public func diskUsage(_ sample: JobResourceSample) -> Double? {
        guard let total = limits.diskTotal, total > 0 else { return nil }
        return min(1, Double(sample.diskUsed) / Double(total))
    }

    /// Cores the environment was given.
    private var cpuCount: Int? { limits.cpuCount }
}
