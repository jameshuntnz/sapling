import SaplingCore
import SwiftUI

/// The node's CPU, memory and disk.
///
/// Exists because the failure that cost the most time was invisible: two VMs
/// sized to the whole of a 16GB machine, paging so heavily that a VM couldn't
/// answer SSH before its boot timeout, reported as a problem with the base
/// image. A memory meter would have said so at a glance.
struct MetricsView: View {
    let metrics: NodeMetrics
    let history: [NodeMetrics]

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Meter(
                label: "CPU",
                value: metrics.cpuUsage,
                detail: loadDetail,
                samples: history.map(\.cpuUsage),
                tint: .accentColor)

            Meter(
                label: "Memory",
                value: metrics.memoryUsage,
                detail: memoryDetail,
                samples: history.map(\.memoryUsage),
                // Memory is the one that bites, so it turns amber on pressure
                // rather than waiting for the bar to look full.
                tint: metrics.isUnderMemoryPressure ? .orange : .accentColor,
                warning: metrics.isUnderMemoryPressure ? swapDetail : nil)

            Meter(
                label: "Disk",
                value: metrics.diskUsage,
                detail: diskDetail,
                samples: history.map(\.diskUsage),
                tint: metrics.diskFree < 15 * 1_073_741_824 ? .orange : .accentColor,
                warning: metrics.diskFree < 15 * 1_073_741_824
                    ? "not enough room for a job to finish" : nil)
        }
    }

    private var loadDetail: String {
        guard let load = metrics.loadAverage.first, metrics.cpuCount > 0 else {
            return "\(Int(metrics.cpuUsage * 100))%"
        }
        // Load against core count says whether work is queueing, which a
        // percentage hides once it pins at 100.
        return String(format: "%.1f / %d cores", load, metrics.cpuCount)
    }

    private var memoryDetail: String {
        "\(Format.bytes(metrics.memoryUsed)) of \(Format.bytes(metrics.memoryTotal))"
    }

    private var swapDetail: String {
        metrics.swapUsed > 0
            ? "swapping \(Format.bytes(metrics.swapUsed)) — VMs may be over-committed"
            : "compressing \(Format.bytes(metrics.memoryCompressed))"
    }

    private var diskDetail: String {
        "\(Format.bytes(metrics.diskFree)) free"
    }
}

/// A labelled bar with the recent trend behind it.
struct Meter: View {
    let label: String
    let value: Double
    let detail: String
    var samples: [Double] = []
    var tint: Color = .accentColor
    var warning: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(label)
                    .font(.system(.caption, design: .rounded).weight(.medium))
                    .frame(width: 52, alignment: .leading)

                Text(detail)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)

                Spacer(minLength: 4)

                if samples.count > 1 {
                    Sparkline(samples: samples, tint: tint)
                        .frame(width: 56, height: 12)
                }

                Text("\(Int(value * 100))%")
                    .font(.caption2.monospacedDigit().weight(.medium))
                    .foregroundStyle(tint)
                    .frame(width: 34, alignment: .trailing)
            }

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.15))
                    Capsule()
                        .fill(tint)
                        .frame(width: max(2, geometry.size.width * min(1, max(0, value))))
                }
            }
            .frame(height: 4)

            if let warning {
                Text(warning)
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// The recent trend, drawn small.
///
/// A number says what is happening now; the shape says whether it is getting
/// worse, which is usually the question being asked.
struct Sparkline: View {
    let samples: [Double]
    var tint: Color = .accentColor

    var body: some View {
        Canvas { context, size in
            guard samples.count > 1 else { return }

            // Always drawn against 0...1 rather than the sample range: these
            // are all fractions of a fixed capacity, and autoscaling would
            // make an idle machine's noise look like a spike.
            var path = Path()
            for (index, sample) in samples.enumerated() {
                let x = size.width * Double(index) / Double(samples.count - 1)
                let y = size.height * (1 - min(1, max(0, sample)))
                if index == 0 {
                    path.move(to: CGPoint(x: x, y: y))
                } else {
                    path.addLine(to: CGPoint(x: x, y: y))
                }
            }

            var fill = path
            fill.addLine(to: CGPoint(x: size.width, y: size.height))
            fill.addLine(to: CGPoint(x: 0, y: size.height))
            fill.closeSubpath()
            context.fill(fill, with: .color(tint.opacity(0.15)))
            context.stroke(path, with: .color(tint.opacity(0.7)), lineWidth: 1)
        }
        .accessibilityLabel("Recent trend")
    }
}

extension Format {
    /// Bytes at a readable scale, without the decimal noise on large values.
    static func bytes(_ count: Int64) -> String {
        let gigabytes = Double(count) / 1_073_741_824
        if gigabytes >= 10 { return "\(Int(gigabytes.rounded()))GB" }
        if gigabytes >= 1 { return String(format: "%.1fGB", gigabytes) }
        return "\(Int((Double(count) / 1_048_576).rounded()))MB"
    }
}
