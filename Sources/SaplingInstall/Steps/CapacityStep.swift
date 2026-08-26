import Foundation
import SaplingAgent
import SaplingCore

/// Checks that the node can actually run as many VMs as it is configured to.
///
/// Apple's two-macOS-VM limit is a licensing ceiling, not a statement about
/// your hardware. A prepared base image asks for 8GB, so two of them want
/// 16GB — the whole of a 16GB Mac mini, leaving nothing for macOS, the daemon
/// or the container system.
///
/// The failure that produces is thoroughly misleading: the host pages heavily,
/// a VM takes longer than its boot timeout to answer SSH, and the job fails
/// with `ssh: Operation timed out` pointing at the base image's SSH setup. It
/// cost a debugging cycle and a million page-outs to work out that the real
/// problem was arithmetic.
public struct CapacityStep: InstallStep {
    /// Name shown by `install` and `doctor`.
    public let name = "Capacity"

    /// RAM to leave for the host: macOS, the daemon, and the container system.
    static let hostReserveGB = 4

    let config: SaplingConfig

    /// Creates the step for a configuration.
    public init(config: SaplingConfig) {
        self.config = config
    }

    /// Reports whether the configured concurrency fits in the machine's RAM.
    public func check() async -> StepState {
        let totalGB = Int(ProcessInfo.processInfo.physicalMemory / 1_073_741_824)
        let slots = config.macos.effectiveMaxConcurrent
        guard slots > 0 else { return .ok("macOS jobs are disabled") }

        // `??` takes an autoclosure, which can't await; resolve it explicitly.
        var perVM = config.macos.memoryGB
        if perVM == nil {
            perVM = await Self.baseImageMemoryGB(config.macos.baseImage)
        }
        guard let perVM else {
            return .ok("\(totalGB)GB RAM, \(slots) macOS slot(s) — VM size unknown")
        }
        return Self.assess(totalGB: totalGB, slots: slots, perVMGB: perVM)
    }

    /// Compare what the VMs want against what the machine has.
    ///
    /// Separated from the measuring so the arithmetic can be tested without a
    /// machine of a particular size.
    ///
    /// - Parameters:
    ///   - totalGB: The machine's physical memory.
    ///   - slots: How many macOS VMs may run at once.
    ///   - perVMGB: Memory each VM is given.
    /// - Returns: What `doctor` should report.
    static func assess(totalGB: Int, slots: Int, perVMGB: Int) -> StepState {
        let wanted = slots * perVMGB
        let available = totalGB - hostReserveGB
        let summary = "\(totalGB)GB RAM, \(slots) x \(perVMGB)GB = \(wanted)GB for VMs"

        if wanted >= totalGB {
            return .failed(
                "\(summary) — more than the machine has. VMs will page heavily and boot so "
                    + "slowly that jobs fail on SSH timeouts. Set macos.memory_gb to "
                    + "\(max(1, available / slots)) or lower macos.max_concurrent.")
        }
        if wanted > available {
            return .fixable(
                "\(summary), leaving \(totalGB - wanted)GB for the host — tight. "
                    + "macos.memory_gb of \(max(1, available / slots)) would leave "
                    + "\(hostReserveGB)GB.")
        }
        return .ok("\(summary), \(totalGB - wanted)GB left for the host")
    }

    /// How much memory the base image asks for, when config doesn't say.
    static func baseImageMemoryGB(_ image: String) async -> Int? {
        guard let command = try? await TartProvider.tart(["get", image, "--format", "json"]),
            let result = try? await ProcessRunner.run(
                command.executable, command.arguments, timeout: .seconds(30)),
            result.succeeded,
            let data = result.stdout.data(using: .utf8),
            let fields = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let megabytes = fields["Memory"] as? Int
        else { return nil }
        return megabytes / 1024
    }

    /// Writes a VM size that fits, so the machine stops over-committing.
    public func fix() async throws -> String {
        let totalGB = Int(ProcessInfo.processInfo.physicalMemory / 1_073_741_824)
        let slots = max(1, config.macos.effectiveMaxConcurrent)
        let perVM = max(1, (totalGB - Self.hostReserveGB) / slots)

        var updated = config
        updated.macos.memoryGB = perVM
        try updated.save()
        return "set macos.memory_gb = \(perVM) so \(slots) VM(s) leave the host "
            + "\(totalGB - slots * perVM)GB (restart the daemon to apply)"
    }
}
