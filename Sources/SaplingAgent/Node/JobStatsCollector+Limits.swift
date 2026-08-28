import Foundation
import SaplingCore

/// Reading back what an environment was actually given.
///
/// Asked of the tool rather than taken from `config.toml`, because both
/// `cpu_count` and `memory_gb` are optional and the tool decides when they are
/// unset. That default is not a detail: Apple's `container` gives an unsized
/// container 1GB, which is under half what a real build needs and is how a job
/// dies late with nothing in its log. Reporting the configured value would
/// show a limit no one is being held to.
extension JobStatsCollector {
    /// Ask the provider's tooling what this environment was given.
    ///
    /// Costs one command per environment, once, on the first sample that finds
    /// its process — not once per sample.
    func resolveLimits(jobID: String, entry: Tracked) async {
        let limits: JobResourceLimits?
        switch entry.platform {
        case .macos:
            limits = await Self.tartLimits(vmName: entry.environment)
        case .linux:
            limits = await Self.containerLimits(name: entry.environment)
        }
        guard let limits else { return }
        setLimits(limits, for: jobID)
    }

    /// What `tart` says a VM was configured with.
    static func tartLimits(vmName: String) async -> JobResourceLimits? {
        guard let command = try? await TartProvider.tart(["get", vmName, "--format", "json"]),
            let result = try? await ProcessRunner.run(
                command.executable, command.arguments, timeout: .seconds(30)),
            result.succeeded
        else {
            return nil
        }
        return parseTartLimits(result.stdout)
    }

    /// Split from the call so it can be exercised against captured output.
    ///
    /// The shape below is real output from the node. Note `Memory` is in
    /// megabytes while `Size` — which this deliberately ignores — is a string
    /// of gigabytes in `tart get` and a number in `tart list`. Disk figures
    /// come from the image on disk instead, which is one fewer thing to get
    /// wrong and is measured rather than reported.
    static func parseTartLimits(_ json: String) -> JobResourceLimits? {
        guard let data = json.data(using: .utf8),
            let entry = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }
        let cpu = entry["CPU"] as? Int
        let memoryMB = entry["Memory"] as? Int
        guard cpu != nil || memoryMB != nil else { return nil }
        return JobResourceLimits(
            cpuCount: cpu,
            memoryTotal: memoryMB.map { Int64($0) * 1_048_576 })
    }

    /// What `container` says a container was configured with.
    static func containerLimits(name: String) async -> JobResourceLimits? {
        guard
            let record = await ContainerListing.current(includeStopped: true)
                .first(where: { $0.id == name })
        else {
            return nil
        }
        guard record.cpus != nil || record.memoryBytes != nil else { return nil }
        return JobResourceLimits(cpuCount: record.cpus, memoryTotal: record.memoryBytes)
    }
}
