import Foundation
import SaplingAgent
import SaplingCore

/// Checks that the node can actually run as many job environments as it is
/// configured to.
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
///
/// Linux containers are budgeted here too, for a second reason and in the same
/// place. `container` defaults to 1GB when `--memory` is absent, and
/// `ContainerProvider` omits the flag whenever `linux.memory_gb` is unset —
/// which nothing ever wrote, so every container on the node ran in 1GB. An
/// Android build gets through Kotlin compilation and resource packaging in
/// that and is then OOM-killed during dex merging, which Gradle reports as a
/// vanished daemon (see `MemoryKill`). One place, because VMs and containers
/// spend the same RAM: sizing either without counting the other is how a
/// machine ends up over-committed while both halves look reasonable.
public struct CapacityStep: InstallStep {
    /// Name shown by `install` and `doctor`.
    public let name = "Capacity"

    /// RAM to leave for the host: macOS, the daemon, and the container system.
    static let hostReserveGB = 4

    /// Least memory a container gets before this step calls it starved.
    ///
    /// A floor, not a measurement of any one build — the Android build that
    /// prompted this wants more. Below this the failures stop being about the
    /// build at all, and they arrive disguised as build failures.
    static let linuxMinimumGB = 4

    let config: SaplingConfig

    /// Creates the step for a configuration.
    public init(config: SaplingConfig) {
        self.config = config
    }

    /// Reports whether the configured concurrency fits in the machine's RAM.
    public func check() async -> StepState {
        let totalGB = Int(ProcessInfo.processInfo.physicalMemory / 1_073_741_824)
        let macSlots = config.macos.effectiveMaxConcurrent
        let perVM = await resolvedMacMemoryGB()

        let macState: StepState
        if macSlots == 0 {
            macState = .ok("macOS jobs are disabled")
        } else if let perVM {
            macState = Self.assess(totalGB: totalGB, slots: macSlots, perVMGB: perVM)
        } else {
            macState = .ok("\(totalGB)GB RAM, \(macSlots) macOS slot(s) — VM size unknown")
        }

        let linuxState = Self.assessLinux(
            totalGB: totalGB,
            macWantedGB: macSlots * (perVM ?? 0),
            slots: config.linux.effectiveMaxConcurrent,
            perContainerGB: config.linux.memoryGB)

        return Self.combine(macState, linuxState)
    }

    /// The macOS VM size, from config when it says, from the image when it doesn't.
    func resolvedMacMemoryGB() async -> Int? {
        // `??` takes an autoclosure, which can't await; resolve it explicitly.
        if let configured = config.macos.memoryGB { return configured }
        return await Self.baseImageMemoryGB(config.macos.baseImage)
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

    /// Compare what the containers want against what is left once the VMs have theirs.
    ///
    /// - Parameters:
    ///   - totalGB: The machine's physical memory.
    ///   - macWantedGB: Memory the macOS slots already claim.
    ///   - slots: How many Linux containers may run at once.
    ///   - perContainerGB: `linux.memory_gb`, or nil to take `container`'s default.
    /// - Returns: What `doctor` should report.
    static func assessLinux(
        totalGB: Int, macWantedGB: Int, slots: Int, perContainerGB: Int?
    ) -> StepState {
        guard slots > 0 else { return .ok("Linux jobs are disabled") }
        let budget = max(0, totalGB - hostReserveGB - macWantedGB)
        let fits = budget / slots

        // Unset is reported before any arithmetic, because the size the node is
        // actually running with appears in no config file — it is `container`'s
        // default, and no build of consequence survives it.
        guard let perContainerGB else {
            let advice =
                fits >= linuxMinimumGB
                ? "Set linux.memory_gb to \(fits)."
                : "Only \(budget)GB is left after the VMs and the host, so lower "
                    + "macos.max_concurrent or linux.max_concurrent first."
            return .fixable(
                "linux.memory_gb is unset, so every container runs in "
                    + "\(LinuxConfig.containerDefaultMemoryGB)GB — `container`'s default. A "
                    + "build is OOM-killed part way through and the tool that survives "
                    + "reports a vanished daemon, naming neither memory nor this setting. "
                    + advice)
        }

        let wanted = slots * perContainerGB
        let summary = "\(slots) x \(perContainerGB)GB = \(wanted)GB for containers"

        if wanted > budget {
            return .failed(
                "\(summary), but \(budget)GB is left after the VMs and the host — the machine "
                    + "is over-committed and containers will be OOM-killed mid-build. Set "
                    + "linux.memory_gb to \(max(1, fits)) or lower linux.max_concurrent.")
        }
        if perContainerGB < linuxMinimumGB {
            return .fixable(
                "\(summary) — under \(linuxMinimumGB)GB a container is killed part way "
                    + "through a real build, which arrives disguised as a build failure.")
        }
        return .ok("\(summary), within the \(budget)GB left after the VMs")
    }

    /// The more serious of the two platforms, keeping both messages.
    ///
    /// One step reports on both, so a node that is wrong in two ways says so
    /// once rather than hiding the second behind the first.
    static func combine(_ macOS: StepState, _ linux: StepState) -> StepState {
        if macOS.isOK { return linux }
        if linux.isOK { return macOS }
        let summary = "\(macOS.summary) \(linux.summary)"
        return isFailed(macOS) || isFailed(linux) ? .failed(summary) : .fixable(summary)
    }

    /// Whether a state is `.failed`.
    static func isFailed(_ state: StepState) -> Bool {
        if case .failed = state { return true }
        return false
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

    /// Writes environment sizes that fit, so the machine stops over-committing.
    ///
    /// Refuses rather than writing a size it already knows is too small: a
    /// container given whatever happens to be left is the bug this step exists
    /// to catch, and only concurrency can fix a machine with nothing spare.
    public func fix() async throws -> String {
        let totalGB = Int(ProcessInfo.processInfo.physicalMemory / 1_073_741_824)
        let available = totalGB - Self.hostReserveGB
        var updated = config
        var changes: [String] = []

        let macSlots = config.macos.effectiveMaxConcurrent
        var macWanted = macSlots * (await resolvedMacMemoryGB() ?? 0)
        if macSlots > 0, macWanted > available {
            let perVM = max(1, available / macSlots)
            updated.macos.memoryGB = perVM
            macWanted = macSlots * perVM
            changes.append("macos.memory_gb = \(perVM)")
        }

        let linuxSlots = config.linux.effectiveMaxConcurrent
        if linuxSlots > 0 {
            let budget = max(0, available - macWanted)
            let current = config.linux.memoryGB
            let starved = (current ?? 0) < Self.linuxMinimumGB
            if starved || (current ?? 0) * linuxSlots > budget {
                let per = budget / linuxSlots
                guard per >= Self.linuxMinimumGB else {
                    throw InstallError(
                        "\(totalGB)GB RAM leaves \(budget)GB for \(linuxSlots) Linux slot(s), "
                            + "after \(macWanted)GB of VMs and \(Self.hostReserveGB)GB for the "
                            + "host — under \(Self.linuxMinimumGB)GB each. Lower "
                            + "linux.max_concurrent or macos.max_concurrent; writing a smaller "
                            + "size here would only move the OOM kill into the next build.")
                }
                updated.linux.memoryGB = per
                changes.append("linux.memory_gb = \(per)")
            }
        }

        guard !changes.isEmpty else { return "sizes already fit" }
        try updated.save()
        return "set \(changes.joined(separator: ", ")) — \(totalGB)GB RAM, "
            + "\(Self.hostReserveGB)GB for the host (restart the daemon to apply)"
    }
}
