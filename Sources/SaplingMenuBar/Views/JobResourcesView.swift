import SaplingCore
import SwiftUI

/// What one job's VM or container is using, against what it was given.
///
/// The node meters answer "is this machine in trouble"; this answers the
/// question that follows, which is which of the two running jobs is causing
/// it. Sized the same as `MetricsView` and using the same `Meter`, so the two
/// read as one idea at two scales.
struct JobResourcesView: View {
    let resources: JobResourcesResponse

    /// The sample to show.
    ///
    /// While the environment is up, the latest reading. Once it has gone, the
    /// peak — a last reading taken as the VM shut down describes the shutdown,
    /// not the job, and the highest point is what anyone asks about afterwards.
    private var sample: JobResourceSample? {
        resources.isLive ? resources.latest : resources.peak
    }

    var body: some View {
        if let sample {
            VStack(alignment: .leading, spacing: 9) {
                cpu(sample)
                memory(sample)
                disk(sample)
                footnote
            }
        }
    }

    // MARK: - Meters

    @ViewBuilder
    private func cpu(_ sample: JobResourceSample) -> some View {
        let history = resources.samples.compactMap(resources.cpuUsage)
        Reading(
            label: "CPU",
            value: resources.cpuUsage(sample),
            detail: resources.limits.cpuCount.map {
                String(format: "%.1f of %d cores", sample.cpuCores, $0)
            } ?? String(format: "%.1f cores", sample.cpuCores),
            samples: history)
    }

    @ViewBuilder
    private func memory(_ sample: JobResourceSample) -> some View {
        let history = resources.samples.compactMap(resources.memoryUsage)
        Reading(
            label: "Memory",
            value: resources.memoryUsage(sample),
            detail: resources.limits.memoryTotal.map {
                "\(Format.bytes(sample.memoryFootprint)) of \(Format.bytes($0))"
            } ?? Format.bytes(sample.memoryFootprint),
            samples: history,
            // Over its allocation is worth saying; near it is not. A guest
            // spends its spare memory on page cache and keeps it, so a full
            // bar is what a healthy VM looks like — see `memoryFootprint`.
            tint: isOverMemory(sample) ? .orange : .accentColor,
            warning: isOverMemory(sample)
                ? "the host is holding more than this VM was given" : nil)
    }

    @ViewBuilder
    private func disk(_ sample: JobResourceSample) -> some View {
        Reading(
            label: "Disk",
            // A container's image is a sparse file with a virtual size in the
            // hundreds of gigabytes, so the fraction is meaningless and only
            // the figure is shown. A VM's is a real ceiling.
            value: resources.platform == .macos ? resources.diskUsage(sample) : nil,
            detail: diskDetail(sample),
            samples: resources.platform == .macos
                ? resources.samples.compactMap(resources.diskUsage) : [])
    }

    private func diskDetail(_ sample: JobResourceSample) -> String {
        guard resources.platform == .macos, let total = resources.limits.diskTotal else {
            return "\(Format.bytes(sample.diskUsed)) written"
        }
        return "\(Format.bytes(sample.diskUsed)) of \(Format.bytes(total))"
    }

    /// Whether the host is holding meaningfully more than the guest was given.
    ///
    /// Not a bare comparison against the limit. The VM process carries its own
    /// overhead on top of the guest's RAM, and measured on the node that puts
    /// a healthy 6144MB VM at 6167MB — 23MB over, which a strict check would
    /// paint amber on every macOS job forever. A tenth is far above that
    /// overhead and still catches an environment the host is genuinely
    /// spending more on than the size it was configured with.
    private func isOverMemory(_ sample: JobResourceSample) -> Bool {
        guard let total = resources.limits.memoryTotal, total > 0 else { return false }
        return Double(sample.memoryFootprint) > Double(total) * Self.memoryOverheadAllowance
    }

    /// How far past its allocation a VM may sit before it is worth saying.
    private static let memoryOverheadAllowance = 1.1

    // MARK: - Provenance

    /// What is being shown, and where it came from.
    ///
    /// Worth the line: a finished job's meters are peaks rather than a live
    /// reading, and a bar at 98% means something quite different if you think
    /// it is current.
    private var footnote: some View {
        HStack(spacing: 4) {
            if !resources.isLive {
                Text("peak")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.tertiary)
                Text("·").foregroundStyle(.quaternary)
            }
            if let environment = resources.environment {
                Text(environment)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help("Measured from the host process running \(environment).")
            }
            Spacer(minLength: 0)
        }
    }
}

/// One measurement, as a meter when there is a limit and a figure when not.
///
/// A bar drawn against an unknown limit is a guess with a confident shape, so
/// the two cases are drawn differently rather than one faked as the other.
struct Reading: View {
    let label: String
    let value: Double?
    let detail: String
    var samples: [Double] = []
    var tint: Color = .accentColor
    var warning: String?

    var body: some View {
        if let value {
            Meter(label: label, value: value, detail: detail, samples: samples, tint: tint, warning: warning)
        } else {
            HStack(spacing: 6) {
                Text(label)
                    .font(.system(.caption, design: .rounded).weight(.medium))
                    .frame(width: 52, alignment: .leading)
                Text(detail)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
        }
    }
}
