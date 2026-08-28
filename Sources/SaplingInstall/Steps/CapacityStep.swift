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
/// Containers are budgeted in the same place and against the same RAM, because
/// `node.max_concurrent` lets either platform fill any slot. That makes the
/// worst case *every slot holding the largest environment*, which is the only
/// figure worth checking: sizing each platform to fit on its own is how a
/// machine ends up over-committed the moment both are busy, with every half
/// looking reasonable and the total not fitting.
public struct CapacityStep: InstallStep {
    /// Name shown by `install` and `doctor`.
    public let name = "Capacity"

    /// RAM to leave for the host: macOS, the daemon, and the container system.
    static let hostReserveGB = 4

    /// Least memory an environment gets before this step calls it starved.
    ///
    /// Measured, on this hardware, against a real Android build: at 4GB the
    /// guest's OOM killer takes the Gradle daemon during dex merging —
    /// `oom_kill 1`, `Out of memory: Killed process (java)`, anon-rss 2.69GB —
    /// and Gradle reports only that its daemon vanished. The same build at 6GB
    /// completes with `oom_kill 0`. 4GB is not a cautious floor, it is the
    /// value that fails, so the floor sits above it.
    static let minimumGB = 6

    let config: SaplingConfig

    /// Creates the step for a configuration.
    public init(config: SaplingConfig) {
        self.config = config
    }

    /// Jobs this node runs at once, across both platforms.
    var nodeSlots: Int {
        config.node.effectiveMaxConcurrent(
            macOS: config.macos.effectiveMaxConcurrent,
            linux: config.linux.effectiveMaxConcurrent)
    }

    /// Reports whether the configured concurrency fits in the machine's RAM.
    public func check() async -> StepState {
        let totalGB = Int(ProcessInfo.processInfo.physicalMemory / 1_073_741_824)
        return Self.assessNode(
            totalGB: totalGB,
            slots: nodeSlots,
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

    /// Compare the node's worst-case slot demand against what it has.
    ///
    /// Worst case, not typical: with a shared slot pool any slot may hold
    /// either environment, so the machine must survive every slot holding the
    /// larger of the two. A node that only fits its *average* mix fails
    /// whenever the wrong two jobs arrive together.
    ///
    /// - Parameters:
    ///   - totalGB: The machine's physical memory.
    ///   - slots: Jobs the node runs at once, across both platforms.
    ///   - macPerVMGB: Memory each macOS VM is given, or nil when unknown/disabled.
    ///   - linuxPerGB: `linux.memory_gb`, or nil when unset/disabled.
    ///   - linuxEnabled: Whether Linux jobs run at all.
    /// - Returns: What `doctor` should report.
    static func assessNode(
        totalGB: Int, slots: Int, macPerVMGB: Int?, linuxPerGB: Int?, linuxEnabled: Bool
    ) -> StepState {
        guard slots > 0 else { return .ok("no job slots — this node accepts nothing") }
        let available = totalGB - hostReserveGB
        let fits = available / slots

        // Reported before any arithmetic: the size an unset node is really
        // running with appears in no config file, and no real build survives it.
        if linuxEnabled, linuxPerGB == nil {
            return .fixable(
                "linux.memory_gb is unset, so every container runs in "
                    + "\(LinuxConfig.containerDefaultMemoryGB)GB — `container`'s default. A build "
                    + "is OOM-killed part way through and the tool that survives reports a "
                    + "vanished daemon, naming neither memory nor this setting. "
                    + "Set linux.memory_gb to \(max(1, fits)).")
        }

        let largest = max(macPerVMGB ?? 0, linuxPerGB ?? 0)
        guard largest > 0 else {
            return .ok("\(totalGB)GB RAM, \(slots) slot(s) — environment size unknown")
        }

        let wanted = slots * largest
        let summary =
            "\(totalGB)GB RAM, \(slots) slot(s) x \(largest)GB = \(wanted)GB worst case"

        if wanted >= totalGB {
            return .failed(
                "\(summary) — more than the machine has. Environments will page heavily, VMs "
                    + "will miss their boot timeout and containers will be OOM-killed mid-build. "
                    + "Size them to \(max(1, fits))GB or lower node.max_concurrent.")
        }
        if wanted > available {
            return .fixable(
                "\(summary), leaving \(totalGB - wanted)GB for the host — tight. "
                    + "\(max(1, fits))GB each would leave \(hostReserveGB)GB.")
        }
        if largest < minimumGB {
            return .fixable(
                "\(summary) — under \(minimumGB)GB an environment is killed part way through a "
                    + "real build, which arrives disguised as a build failure. This machine has "
                    + "room for \(fits)GB each.")
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

    /// Gives every slot an equal share of the machine, so any mix of jobs fits.
    ///
    /// Written in both directions. Sizing that only ever shrinks leaves a node
    /// stuck at whatever it was given when headroom was tightest: this node sat
    /// at 4GB containers — the value measured to fail — because that was the
    /// share left when the VM was still claiming its base image's 8GB, and
    /// nothing revisited it after the VM shrank.
    ///
    /// Refuses rather than writing a size already known to be too small; only
    /// concurrency can fix a machine with nothing spare.
    public func fix() async throws -> String {
        let totalGB = Int(ProcessInfo.processInfo.physicalMemory / 1_073_741_824)
        let available = totalGB - Self.hostReserveGB
        let slots = nodeSlots
        guard slots > 0 else { return "no job slots to size" }

        let per = available / slots
        guard per >= Self.minimumGB else {
            throw InstallError(
                "\(totalGB)GB RAM leaves \(available)GB for \(slots) slot(s) after "
                    + "\(Self.hostReserveGB)GB for the host — \(per)GB each, under the "
                    + "\(Self.minimumGB)GB an environment needs to finish a real build. Lower "
                    + "node.max_concurrent; writing a smaller size would only move the OOM kill "
                    + "into the next build.")
        }

        var updated = config
        var changes: [String] = []
        if config.macos.effectiveMaxConcurrent > 0, config.macos.memoryGB != per {
            updated.macos.memoryGB = per
            changes.append("macos.memory_gb = \(per)")
        }
        if config.linux.effectiveMaxConcurrent > 0, config.linux.memoryGB != per {
            updated.linux.memoryGB = per
            changes.append("linux.memory_gb = \(per)")
        }

        guard !changes.isEmpty else { return "sizes already fit" }
        try updated.save()
        return "set \(changes.joined(separator: ", ")) — \(slots) slot(s) of \(per)GB in "
            + "\(totalGB)GB, \(Self.hostReserveGB)GB for the host (restart the daemon to apply)"
    }
}
