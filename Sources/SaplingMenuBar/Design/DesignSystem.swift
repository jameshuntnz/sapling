import SaplingCore
import SwiftUI

/// Small shared vocabulary so every view agrees on colour, spacing, and how a
/// status reads.
///
/// Kept in one place because the panel is dense — inconsistency shows up
/// immediately at this size.
enum Palette {
    static func color(for status: JobStatus) -> Color {
        switch status {
        case .completed: .green
        case .failed: .red
        case .running, .provisioning: .blue
        case .cleanup: .orange
        case .queued: .secondary
        }
    }

    static func color(for status: NodeStatus) -> Color {
        switch status {
        case .online: .green
        case .offline: .red
        case .draining, .cordoned: .yellow
        }
    }

    static func symbol(for status: JobStatus) -> String {
        switch status {
        case .completed: "checkmark.circle.fill"
        case .failed: "xmark.circle.fill"
        case .running: "play.circle.fill"
        case .provisioning: "gearshape.circle.fill"
        case .cleanup: "trash.circle.fill"
        case .queued: "clock"
        }
    }
}

/// Value formatting shared across the panel.
enum Format {}

enum Metrics {
    static let panelWidth: CGFloat = 380
    static let panelHeight: CGFloat = 520
    static let rowSpacing: CGFloat = 6
    static let sectionSpacing: CGFloat = 14
    static let horizontalPadding: CGFloat = 14
}

extension Date {
    /// Compact relative time.
    ///
    /// The panel is glanced at, not read.
    var relativeDescription: String {
        let seconds = Int(Date().timeIntervalSince(self))
        switch seconds {
        case ..<0: return "soon"
        case 0..<10: return "just now"
        case 10..<60: return "\(seconds)s ago"
        case 60..<3600: return "\(seconds / 60)m ago"
        case 3600..<86400: return "\(seconds / 3600)h ago"
        default: return "\(seconds / 86400)d ago"
        }
    }
}

extension TimeInterval {
    var durationDescription: String {
        guard self >= 0 else { return "—" }
        let total = Int(self)
        if total < 60 { return "\(total)s" }
        if total < 3600 { return "\(total / 60)m \(total % 60)s" }
        return "\(total / 3600)h \((total % 3600) / 60)m"
    }
}

/// A small capsule label — used for statuses, where a coloured dot alone is
/// ambiguous and a full sentence is too much.
struct StatusPill: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.15), in: Capsule())
    }
}

struct SectionHeader: View {
    let title: String
    var trailing: String?

    var body: some View {
        HStack {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .tracking(0.6)
            Spacer()
            if let trailing {
                Text(trailing)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}
