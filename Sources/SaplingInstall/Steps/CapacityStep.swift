import Foundation
import SaplingAgent
import SaplingCore

/// Checks that this node's default job sizes are ones it can actually run.
///
/// It used to check something bigger: how much RAM the configured concurrency
/// could demand at once. Two macOS VMs from a base image asking 8GB each want
/// the whole of a 16GB Mac mini, and the failure that produces is thoroughly
/// misleading — the host pages heavily, a VM misses its boot timeout, and the
/// job fails with `ssh: Operation timed out` pointing at the base image's SSH
/// setup. It cost a debugging cycle and a million page-outs to find that the
/// real problem was arithmetic.
///
/// The scheduler now prevents that directly: it rations memory job by job and
/// admits nothing that would exceed the budget, so the second 8GB VM is simply
/// never started. Multiplying slots by the largest environment here would only
/// condemn a healthy node, because slot counts are a backstop for disk and CPU
/// rather than a claim about memory.
///
/// What is still worth checking is narrower and still catches a real mistake: a
/// default larger than the whole job budget is a platform that can never run
/// anything, and the node would otherwise reveal that only by refusing every
/// job it is offered.
public struct CapacityStep: InstallStep {
    /// Name shown by `install` and `doctor`.
    public let name = "Capacity"

    let config: SaplingConfig

    /// Creates the step for a configuration.
    public init(config: SaplingConfig) {
        self.config = config
    }

    /// Reports whether the configured defaults fit in the machine's RAM.
    ///
    /// The scheduler rations memory job by job, so this is no longer the thing
    /// standing between the node and an over-commit — it is the check that the
    /// *defaults* are sane, which is what decides how many ordinary jobs fit.
    public func check() async -> StepState {
        let totalGB = Int(ProcessInfo.processInfo.physicalMemory / 1_073_741_824)
        return Self.assessNode(
            totalGB: totalGB,
            budgetGB: config.node.memoryBudgetGB(totalGB: totalGB),
            macPerVMGB: config.macos.effectiveMaxConcurrent > 0 ? await resolvedMacMemoryGB() : nil,
            linuxPerGB: config.linux.effectiveMaxConcurrent > 0 ? config.linux.memoryGB : nil,
            linuxEnabled: config.linux.effectiveMaxConcurrent > 0)
    }

    /// The macOS VM size, from config when it says, from the image when it doesn't.
    func resolvedMacMemoryGB() async -> Int? {
        // `??` takes an autoclosure, which can't await; resolve it explicitly.
        if let configured = config.macos.memoryGB { return configured }
        return await Self.baseImageMemoryGB(config.macos.baseImage)
    }

    /// Compare a job of each platform's default size against the job budget.
    ///
    /// Not the worst case any more. The scheduler rations memory job by job, so
    /// admission is what stands between this node and an over-commit — counting
    /// slots and multiplying by the largest environment would now condemn a
    /// perfectly good node, because slot counts are a backstop for disk and CPU
    /// rather than a claim about memory.
    ///
    /// What is worth checking is that the defaults are workable. A default
    /// larger than the whole budget is a platform that can never run anything,
    /// and the node would otherwise reveal that only by refusing every job.
    ///
    /// - Parameters:
    ///   - totalGB: The machine's physical memory.
    ///   - budgetGB: What jobs may collectively hold.
    ///   - macPerVMGB: Default macOS VM size, or nil when unknown or disabled.
    ///   - linuxPerGB: `linux.memory_gb`, or nil when unset or disabled.
    ///   - linuxEnabled: Whether Linux jobs run at all.
    /// - Returns: What `doctor` should report.
    static func assessNode(
        totalGB: Int, budgetGB: Int, macPerVMGB: Int?, linuxPerGB: Int?, linuxEnabled: Bool
    ) -> StepState {
        guard budgetGB > 0 else {
            return .failed(
                "\(totalGB)GB RAM, and the host reserve leaves nothing for jobs — every job "
                    + "would be refused. Lower node.memory_reserve_gb.")
        }

        // Reported before the arithmetic: the size an unset node is really
        // running with appears in no config file, and no real build survives it.
        if linuxEnabled, linuxPerGB == nil {
            return .fixable(
                "linux.memory_gb is unset, so every container runs in "
                    + "\(LinuxConfig.containerDefaultMemoryGB)GB — `container`'s default. A build "
                    + "is OOM-killed part way through and the tool that survives reports a "
                    + "vanished daemon, naming neither memory nor this setting.")
        }

        var fits: [String] = []
        for (name, size) in [("macOS", macPerVMGB), ("Linux", linuxPerGB)] {
            guard let size, size > 0 else { continue }
            if size > budgetGB {
                return .failed(
                    "\(name) jobs default to \(size)GB but only \(budgetGB)GB is available to "
                        + "jobs at all, so every one would be refused. Lower the default or "
                        + "node.memory_reserve_gb.")
            }
            fits.append("\(budgetGB / size) x \(size)GB \(name)")
        }

        guard !fits.isEmpty else {
            return .ok("\(totalGB)GB RAM, \(budgetGB)GB for jobs — default sizes unknown")
        }
        return .ok(
            "\(totalGB)GB RAM, \(budgetGB)GB for jobs: " + fits.joined(separator: ", "))
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

    /// Default sizes for a platform whose own is unset or cannot fit.
    ///
    /// Policy, and deliberately so. A macOS VM does not usefully run in less
    /// than this. A Linux job mostly wants far less, and that is the point of a
    /// low default: ordinary jobs pack densely, and the occasional hungry one
    /// asks for what it needs with a `mem:` label rather than every job paying
    /// for the largest.
    static let defaultMacOSGB = 6
    /// Default size for Linux jobs.
    ///
    /// See `defaultMacOSGB` for why the two differ.
    static let defaultLinuxGB = 2

    /// Repairs a default that is unset, or too large for the node to ever run.
    ///
    /// Deliberately narrow. Admission decides what runs, so this is not sizing
    /// the machine any more — it is fixing a default that would refuse every
    /// job of its platform, and leaving alone any default that works.
    public func fix() async throws -> String {
        let totalGB = Int(ProcessInfo.processInfo.physicalMemory / 1_073_741_824)
        let budgetGB = config.node.memoryBudgetGB(totalGB: totalGB)
        guard budgetGB > 0 else {
            throw InstallError(
                "\(totalGB)GB RAM, and node.memory_reserve_gb leaves nothing for jobs. No size "
                    + "will help; lower the reserve.")
        }

        var updated = config
        var changes: [String] = []

        if config.macos.effectiveMaxConcurrent > 0 {
            let current = await resolvedMacMemoryGB()
            if current == nil || (current ?? 0) > budgetGB {
                let per = min(budgetGB, Self.defaultMacOSGB)
                updated.macos.memoryGB = per
                changes.append("macos.memory_gb = \(per)")
            }
        }
        if config.linux.effectiveMaxConcurrent > 0 {
            let current = config.linux.memoryGB
            if current == nil || (current ?? 0) > budgetGB {
                let per = min(budgetGB, Self.defaultLinuxGB)
                updated.linux.memoryGB = per
                changes.append("linux.memory_gb = \(per)")
            }
        }

        guard !changes.isEmpty else { return "defaults already fit" }
        try updated.save()
        return "set \(changes.joined(separator: ", ")) — \(budgetGB)GB for jobs on a "
            + "\(totalGB)GB machine (restart the daemon to apply)"
    }
}
