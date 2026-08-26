import Foundation
import SaplingAgent
import SaplingCore

/// Checks free space and staging data left behind by VM image pulls.
///
/// A base image is 80GB or more on a 256GB disk, so headroom is genuinely
/// scarce and the failure is quiet: jobs start failing partway through for
/// want of space, which reads as a flaky build rather than a full disk.
///
/// Tart stages an image pull in `$TART_HOME/tmp` before materialising it. An
/// interrupted pull leaves that behind, and `tart prune` does not clear it —
/// it only prunes the OCI cache. Tens of gigabytes can sit there unnoticed.
public struct DiskStep: InstallStep {
    /// Name shown by `install` and `doctor`.
    public let name = "Disk"

    /// Below this, a job is likely to fail partway through.
    static let criticalFreeBytes: Int64 = 15 * 1_073_741_824
    /// Below this, there isn't room to pull another base image.
    static let lowFreeBytes: Int64 = 40 * 1_073_741_824
    /// Staging data above this is worth reporting rather than rounding away.
    static let staleStagingBytes: Int64 = 1_073_741_824

    /// Creates the step.
    public init() {}

    /// Reports whether this step is already satisfied.
    public func check() async -> StepState {
        let free = Self.availableBytes(forPath: "/System/Volumes/Data")
        let staging = await Self.stagingBytes()
        let pullRunning = await Self.isPullRunning()
        return Self.assess(freeBytes: free, stagingBytes: staging, pullRunning: pullRunning)
    }

    /// Removes staging data from an interrupted image pull.
    public func fix() async throws -> String {
        // Deleting this mid-pull destroys the download in progress.
        guard await !Self.isPullRunning() else {
            throw InstallError(
                "an image pull is in progress; leave its staging data alone until it finishes")
        }
        let staging = Self.stagingDirectory
        let reclaimed = await Self.stagingBytes()
        try FileManager.default.removeItem(atPath: staging)
        try FileManager.default.createDirectory(
            atPath: staging, withIntermediateDirectories: true)
        return "cleared \(Self.format(reclaimed)) of leftover image staging data"
    }

    // MARK: - Assessment

    /// Turn the measurements into a verdict.
    ///
    /// Separated from the measuring so the thresholds can be tested without a
    /// disk in a particular state.
    ///
    /// - Parameters:
    ///   - freeBytes: Space available on the data volume.
    ///   - stagingBytes: Size of Tart's staging directory.
    ///   - pullRunning: Whether an image pull is currently using it.
    /// - Returns: What `doctor` should report.
    static func assess(freeBytes: Int64, stagingBytes: Int64, pullRunning: Bool) -> StepState {
        let free = format(freeBytes)

        // Staging data during a pull is expected, not a leak.
        if stagingBytes > staleStagingBytes, !pullRunning {
            return .fixable(
                "\(format(stagingBytes)) of leftover image staging data in \(stagingDirectory), "
                    + "\(free) free")
        }
        if freeBytes < criticalFreeBytes {
            return .failed("only \(free) free — jobs will fail partway through")
        }
        if freeBytes < lowFreeBytes {
            return .ok("\(free) free — enough to run jobs, not enough to pull another base image")
        }
        return .ok("\(free) free")
    }

    static var stagingDirectory: String {
        "\(InstallContext.tartHome)/tmp"
    }

    static func availableBytes(forPath path: String) -> Int64 {
        let url = URL(fileURLWithPath: path)
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage ?? 0
    }

    static func stagingBytes() async -> Int64 {
        guard FileManager.default.fileExists(atPath: stagingDirectory) else { return 0 }
        guard let result = try? await ProcessRunner.run("du", ["-sk", stagingDirectory]),
            result.succeeded,
            let kilobytes = Int64(result.trimmedOutput.split(separator: "\t").first ?? "")
        else { return 0 }
        return kilobytes * 1024
    }

    static func isPullRunning() async -> Bool {
        guard let result = try? await ProcessRunner.run("pgrep", ["-f", "tart clone"]) else {
            return false
        }
        return result.succeeded && !result.trimmedOutput.isEmpty
    }

    static func format(_ bytes: Int64) -> String {
        let gigabytes = Double(bytes) / 1_073_741_824
        return gigabytes >= 10
            ? "\(Int(gigabytes.rounded()))GB"
            : String(format: "%.1fGB", gigabytes)
    }
}
