import Foundation
import SaplingCore

/// Samples what each running job's environment is using, against what it was
/// given.
///
/// The node-wide meters in `MetricsCollector` answer "is this machine in
/// trouble"; they cannot answer "which of the two jobs is causing it", which
/// is the question asked as soon as the first one goes amber. This tracks
/// each VM and container separately so the answer is visible per job.
///
/// An actor for the same reason as `MetricsCollector`: CPU is a rate, so the
/// previous reading for every environment has to live somewhere only one
/// caller can touch.
public actor JobStatsCollector {
    /// How often environments are sampled.
    ///
    /// The node's own metrics cadence, so a job's meters and the node's move
    /// together rather than showing two different moments.
    public static let interval: Duration = MetricsCollector.interval
    /// Samples kept per job — about ten minutes at the sampling interval.
    ///
    /// A job can run for two hours, so this is a window rather than a
    /// recording. What survives the window is the peak, which is the part
    /// worth having later.
    static let historyLimit = 120
    /// How many finished jobs' figures to keep.
    ///
    /// Enough that the job you just watched fail is still there when you click
    /// it, and bounded so a busy day cannot grow this without limit.
    static let finishedRetained = 12
    /// How long to wait for an environment that never appears.
    ///
    /// A VM that fails to clone or boot leaves a registration with no process
    /// behind it. Longer than any real boot, because a clone competing with a
    /// container build for the one SSD is slow but not broken.
    static let appearanceTimeout: TimeInterval = 900

    /// One job's environment, and what it has been doing.
    struct Tracked {
        var environment: String
        var platform: JobPlatform
        var registeredAt: Date
        var limits = JobResourceLimits()
        var limitsResolved = false
        var pid: Int32?
        /// The guest disk image, found alongside the process.
        var imagePath: String?
        var previous: (cpuNanos: UInt64, at: ContinuousClock.Instant)?
        var samples: [JobResourceSample] = []
        var peak: JobResourceSample?
        /// Whether a host process has ever been found for it.
        var appeared = false
        /// Whether it is still up.
        var isLive = true
    }

    private var tracked: [String: Tracked] = [:]
    /// Job ids in the order they were registered, for evicting the oldest.
    private var order: [String] = []

    /// Creates a collector tracking nothing.
    public init() {}

    // MARK: - Tracking

    /// Begin tracking the environment a job is running in.
    ///
    /// Re-registering a job with a different environment starts over: the
    /// macOS provider rebuilds a VM under a fresh name when one comes up
    /// without a network, and the new VM's figures are not a continuation of
    /// the dead one's.
    ///
    /// - Parameters:
    ///   - jobID: The job the environment belongs to.
    ///   - environment: The VM or container name.
    ///   - platform: Which provider created it.
    public func track(jobID: String, environment: String, platform: JobPlatform) {
        if let existing = tracked[jobID], existing.environment == environment { return }
        tracked[jobID] = Tracked(environment: environment, platform: platform, registeredAt: Date())
        order.removeAll { $0 == jobID }
        order.append(jobID)
        evictFinished()
    }

    /// Sample every environment still being tracked.
    public func sample() async {
        guard tracked.contains(where: { $0.value.isLive }) else { return }

        // Discovery walks every process on the machine, so it only runs when
        // something is actually missing — which is the first sample of a new
        // environment, and nothing else.
        if tracked.values.contains(where: { $0.isLive && $0.pid == nil }) {
            let discovered = VMProcessSampler.discover()
            for (jobID, entry) in tracked where entry.isLive && entry.pid == nil {
                guard let match = discovered.first(where: { $0.environment == entry.environment })
                else { continue }
                tracked[jobID]?.pid = match.pid
                tracked[jobID]?.imagePath = match.imagePath
                tracked[jobID]?.appeared = true
            }
        }

        let now = ContinuousClock.now
        for (jobID, entry) in tracked where entry.isLive {
            guard let pid = entry.pid else {
                // Nothing to measure yet. A VM still cloning is normal; one
                // that never turns up is not, and is written off rather than
                // sampled forever.
                if Date().timeIntervalSince(entry.registeredAt) > Self.appearanceTimeout {
                    tracked[jobID]?.isLive = false
                }
                continue
            }
            guard let usage = VMProcessSampler.usage(of: pid) else {
                // The process has gone, which is what the end of a job looks
                // like from out here: teardown happens as soon as the provider
                // returns, so this is the environment's real lifetime.
                tracked[jobID]?.isLive = false
                tracked[jobID]?.pid = nil
                continue
            }

            var cores = 0.0
            if let previous = entry.previous {
                let elapsed = seconds(in: now - previous.at)
                if elapsed > 0 {
                    cores = Double(usage.cpuNanos &- previous.cpuNanos) / 1_000_000_000 / elapsed
                }
            }
            tracked[jobID]?.previous = (usage.cpuNanos, now)

            let image = entry.imagePath.flatMap(VMProcessSampler.imageSize(at:))
            let sample = JobResourceSample(
                cpuCores: max(0, cores),
                memoryFootprint: usage.footprint,
                diskUsed: image?.used ?? 0)
            append(sample, to: jobID)

            if let capacity = image?.capacity, capacity > 0 {
                tracked[jobID]?.limits.diskTotal = capacity
            }
            if !entry.limitsResolved {
                tracked[jobID]?.limitsResolved = true
                await resolveLimits(jobID: jobID, entry: entry)
            }
        }
    }

    /// Sample on a timer until cancelled.
    public func run() async {
        while !Task.isCancelled {
            await sample()
            try? await Task.sleep(for: Self.interval)
        }
    }

    // MARK: - Reading

    /// What one job's environment has used, and what it was given.
    ///
    /// - Parameters:
    ///   - jobID: The job to report on.
    ///   - platform: The platform to report when nothing was ever tracked.
    ///   - limit: Most recent N samples, or all held when `nil`.
    /// - Returns: The job's figures, empty if it never had an environment.
    public func resources(jobID: String, platform: JobPlatform, limit: Int? = nil) -> JobResourcesResponse {
        let interval = Int(Self.interval.components.seconds)
        guard let entry = tracked[jobID] else {
            return JobResourcesResponse(jobID: jobID, platform: platform, intervalSeconds: interval)
        }
        var samples = entry.samples
        if let limit, limit < samples.count { samples = Array(samples.suffix(limit)) }
        return JobResourcesResponse(
            jobID: jobID,
            platform: entry.platform,
            environment: entry.environment,
            isLive: entry.isLive,
            limits: entry.limits,
            peak: entry.peak,
            samples: samples,
            intervalSeconds: interval)
    }

    /// Environments being sampled right now, for tests and diagnostics.
    public func liveEnvironments() -> [String] {
        tracked.values.filter(\.isLive).map(\.environment).sorted()
    }

    // MARK: - Bookkeeping

    /// Record a sample against a job, holding the window and the peak.
    private func append(_ sample: JobResourceSample, to jobID: String) {
        guard var entry = tracked[jobID] else { return }
        entry.samples.append(sample)
        if entry.samples.count > Self.historyLimit {
            entry.samples.removeFirst(entry.samples.count - Self.historyLimit)
        }
        entry.peak = entry.peak.map { $0.peak(with: sample) } ?? sample
        tracked[jobID] = entry
    }

    /// Drop the oldest finished jobs once too many have accumulated.
    private func evictFinished() {
        var finished = order.filter { tracked[$0]?.isLive == false }
        while finished.count > Self.finishedRetained {
            let oldest = finished.removeFirst()
            tracked.removeValue(forKey: oldest)
            order.removeAll { $0 == oldest }
        }
    }

    /// Read back the limits the tool actually applied.
    func setLimits(_ limits: JobResourceLimits, for jobID: String) {
        guard var entry = tracked[jobID] else { return }
        // Disk capacity comes from the image itself, which is measured rather
        // than reported, so it is never overwritten here.
        entry.limits.cpuCount = limits.cpuCount ?? entry.limits.cpuCount
        entry.limits.memoryTotal = limits.memoryTotal ?? entry.limits.memoryTotal
        tracked[jobID] = entry
    }
}

/// A duration as a fraction of seconds.
///
/// Free function rather than an extension on `Duration`: a `seconds` member
/// sitting next to the standard `Duration.seconds(_:)` factory reads as the
/// same thing and is not.
private func seconds(in duration: Duration) -> Double {
    Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
}
