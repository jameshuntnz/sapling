import Darwin
import Foundation
import SaplingCore

/// Samples the node's CPU, memory and disk, and keeps a short history.
///
/// An actor because CPU usage is a rate: it comes from the change in tick
/// counts between samples, so the previous reading has to be held somewhere
/// only one caller can touch at a time.
///
/// Reads the kernel directly rather than shelling out to `top` or `vm_stat`.
/// This runs every few seconds for the lifetime of the daemon, and spawning
/// two processes each time to parse their output would cost more than the
/// measurement is worth.
public actor MetricsCollector {
    /// How often samples are taken.
    public static let interval: Duration = .seconds(5)
    /// How many to keep — about ten minutes at the sampling interval, which is
    /// long enough to see a job's shape without storing anything.
    static let historyLimit = 120

    private var history: [NodeMetrics] = []
    private var previousTicks: CPUTicks?

    /// Creates a collector with no history.
    public init() {}

    /// Total CPU ticks by state, which are only meaningful as a difference.
    struct CPUTicks {
        var user: UInt64
        var system: UInt64
        var idle: UInt64
        var nice: UInt64

        var total: UInt64 { user + system + idle + nice }
        var busy: UInt64 { user + system + nice }
    }

    /// Take a sample and add it to the history.
    ///
    /// - Returns: The sample just taken.
    @discardableResult
    public func sample() -> NodeMetrics {
        let ticks = Self.readCPUTicks()
        var usage = 0.0
        if let ticks, let previous = previousTicks {
            let totalDelta = ticks.total &- previous.total
            let busyDelta = ticks.busy &- previous.busy
            if totalDelta > 0 {
                usage = min(1, Double(busyDelta) / Double(totalDelta))
            }
        }
        previousTicks = ticks

        let memory = Self.readMemory()
        let swap = Self.readSwap()
        let disk = Self.readDisk()

        let metrics = NodeMetrics(
            cpuUsage: usage,
            loadAverage: Self.readLoadAverage(),
            cpuCount: ProcessInfo.processInfo.processorCount,
            memoryTotal: Int64(ProcessInfo.processInfo.physicalMemory),
            memoryUsed: memory.used,
            memoryCompressed: memory.compressed,
            swapUsed: swap.used,
            swapTotal: swap.total,
            diskTotal: disk.total,
            diskFree: disk.free)

        history.append(metrics)
        if history.count > Self.historyLimit {
            history.removeFirst(history.count - Self.historyLimit)
        }
        return metrics
    }

    /// The most recent sample, taking one if none exists yet.
    public func current() -> NodeMetrics {
        history.last ?? sample()
    }

    /// Samples held, oldest first.
    ///
    /// - Parameter limit: Most recent N samples, or all of them when `nil`.
    /// - Returns: Samples, oldest first.
    public func recent(limit: Int? = nil) -> [NodeMetrics] {
        guard let limit, limit < history.count else { return history }
        return Array(history.suffix(limit))
    }

    /// Sample on a timer until cancelled.
    public func run() async {
        while !Task.isCancelled {
            sample()
            try? await Task.sleep(for: Self.interval)
        }
    }

    // MARK: - Reading the kernel

    /// Cumulative CPU ticks across all cores.
    static func readCPUTicks() -> CPUTicks? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<host_cpu_load_info_data_t>.stride / MemoryLayout<integer_t>.stride)

        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }

        return CPUTicks(
            user: UInt64(info.cpu_ticks.0),
            system: UInt64(info.cpu_ticks.1),
            idle: UInt64(info.cpu_ticks.2),
            nice: UInt64(info.cpu_ticks.3))
    }

    /// Memory in use and memory compressed, in bytes.
    ///
    /// "Used" is active plus wired plus compressed. Inactive pages are left
    /// out: macOS reclaims them on demand, and counting them makes an idle
    /// machine look full.
    static func readMemory() -> (used: Int64, compressed: Int64) {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)

        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return (0, 0) }

        // `vm_kernel_page_size` is a mutable global, which Swift 6 rightly
        // refuses to read from an actor. Ask the kernel instead.
        var rawPageSize: vm_size_t = 0
        guard host_page_size(mach_host_self(), &rawPageSize) == KERN_SUCCESS else { return (0, 0) }
        let pageSize = Int64(rawPageSize)
        let active = Int64(stats.active_count) * pageSize
        let wired = Int64(stats.wire_count) * pageSize
        let compressed = Int64(stats.compressor_page_count) * pageSize
        return (used: active + wired + compressed, compressed: compressed)
    }

    /// Swap in use and configured, in bytes.
    static func readSwap() -> (used: Int64, total: Int64) {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 else { return (0, 0) }
        return (used: Int64(usage.xsu_used), total: Int64(usage.xsu_total))
    }

    /// Capacity and free space on the data volume.
    static func readDisk(path: String = "/System/Volumes/Data") -> (total: Int64, free: Int64) {
        let url = URL(fileURLWithPath: path)
        guard
            let values = try? url.resourceValues(forKeys: [
                .volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey,
            ])
        else { return (0, 0) }
        return (
            total: Int64(values.volumeTotalCapacity ?? 0),
            free: values.volumeAvailableCapacityForImportantUsage ?? 0
        )
    }

    /// One, five and fifteen minute load averages.
    static func readLoadAverage() -> [Double] {
        var averages = [Double](repeating: 0, count: 3)
        guard getloadavg(&averages, 3) == 3 else { return [] }
        return averages
    }
}
