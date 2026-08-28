import Foundation
import SaplingCore

/// What this node will start, and how much of the machine it hands over.
///
/// Split from polling because the two answer different questions: polling asks
/// what GitHub has, this asks what the machine can hold. Slot counts bound the
/// resources memory cannot see — disk for checkouts and image layers, CPU
/// oversubscription, the container system's own limits — while memory decides
/// admission, because it is the one that kills a job outright when it runs
/// short rather than merely slowing it down.
extension NodeAgent {
    func capacity(for platform: JobPlatform) -> Int {
        switch platform {
        case .macos: config.macos.effectiveMaxConcurrent
        case .linux: config.linux.effectiveMaxConcurrent
        }
    }

    /// Jobs this node will run at once across both platforms.
    ///
    /// The per-platform counts say what each platform may run; this says what
    /// the machine may run in total. See `NodeConfig.maxConcurrent` for why
    /// both are needed — RAM is shared and the per-platform counts cannot say so.
    var nodeCapacity: Int {
        config.node.effectiveMaxConcurrent(
            macOS: config.macos.effectiveMaxConcurrent,
            linux: config.linux.effectiveMaxConcurrent)
    }

    /// The machine's memory, in GB.
    var totalMemoryGB: Int { Int(ProcessInfo.processInfo.physicalMemory / 1_073_741_824) }

    /// What jobs may collectively hold on this node, in GB.
    var memoryBudgetGB: Int { config.node.memoryBudgetGB(totalGB: totalMemoryGB) }

    /// Memory a job of these labels gets on this node, in GB.
    func memoryGB(for job: Job) -> Int? {
        job.memoryGB
            ?? JobSizing.memoryGB(labels: job.labels, platform: job.platform, config: config)
    }

    /// What a job of unknown size is charged against the budget, in GB.
    ///
    /// Per platform, because the two are nowhere near each other: charging a
    /// macOS VM the container default would book 1GB against a guest that takes
    /// eight, and the budget would admit work the machine cannot hold. Where it
    /// has to guess, it guesses high.
    func defaultMemoryGB(for platform: JobPlatform) -> Int {
        switch platform {
        case .macos:
            max(1, config.macos.memoryGB ?? MacOSConfig.baseImageDefaultMemoryGB)
        case .linux:
            max(1, config.linux.memoryGB ?? LinuxConfig.containerDefaultMemoryGB)
        }
    }

    func dispatchQueuedJobs() async throws {
        var inUse = try await store.slotsInUse()
        // Charged for jobs that predate sizing: the larger of the two defaults,
        // since which platform an unsized survivor belonged to is exactly what
        // is not known, and under-charging over-commits the machine.
        var committedGB = try await store.committedMemoryGB(
            fallbackGB: max(defaultMemoryGB(for: .macos), defaultMemoryGB(for: .linux)))
        let budgetGB = memoryBudgetGB
        let queued = try await store.jobs(status: .queued, limit: 50)
            .sorted { ($0.queuedAt ?? .distantPast) < ($1.queuedAt ?? .distantPast) }

        for job in queued {
            let used = inUse[job.platform] ?? 0
            guard used < capacity(for: job.platform) else { continue }
            // Checked against the live total rather than a running counter, so
            // a job dispatched earlier in this same loop counts against it.
            guard inUse.values.reduce(0, +) < nodeCapacity else { break }
            guard !blockedByOtherPlatform(job.platform, inUse: inUse) else { continue }

            let wanted = memoryGB(for: job) ?? defaultMemoryGB(for: job.platform)

            // Stepped over, never waited for. Head-of-line reservation assumes
            // the job at the front will eventually fit; one larger than the
            // whole budget never will, so blocking behind it stalls the node
            // permanently. Discovery refuses these, but config can shrink under
            // a job that is already queued.
            guard wanted <= budgetGB else { continue }

            guard JobSizing.fits(memoryGB: wanted, committedGB: committedGB, budgetGB: budgetGB)
            else {
                // Head-of-line reservation. Skipping to a job that does fit
                // would let a stream of small jobs starve a large one
                // indefinitely, and the large one is usually the build that
                // matters. Waiting costs throughput; starving costs the job.
                break
            }

            inUse[job.platform] = used + 1
            committedGB += wanted
            await dispatch(job, memoryGB: wanted)
        }
    }

    /// Whether the other platform is busy and this node runs one at a time.
    ///
    /// The two platforms share vmnet, and on this hardware they do not share
    /// it well: started together, the VM never gets a bridge, times out, and
    /// its teardown destroys the container's. Holding the job back costs a few
    /// minutes; dispatching it costs the other job outright. See
    /// `NodeConfig.serializePlatforms` for the measurements.
    func blockedByOtherPlatform(_ platform: JobPlatform, inUse: [JobPlatform: Int]) -> Bool {
        guard config.node.serializePlatforms else { return false }
        return inUse.contains { $0.key != platform && $0.value > 0 }
    }

}
