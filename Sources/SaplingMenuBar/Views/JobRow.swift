import SaplingCore
import SwiftUI

struct JobRow: View {
    let job: Job
    let isSelected: Bool
    /// When its runner started waiting for an assignment, if it has waited
    /// long enough to look stuck.
    var stuckSince: Date?

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: stuckSince == nil ? Palette.symbol(for: job.status) : "hourglass.circle.fill")
                .foregroundStyle(stuckSince == nil ? Palette.color(for: job.status) : .orange)
                .font(.callout)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 1) {
                Text(job.name ?? "job \(job.id)")
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.middle)

                HStack(spacing: 5) {
                    Text(job.repo)
                        .lineLimit(1)
                        .truncationMode(.head)
                    Text("·")
                    Text(job.platform.rawValue)
                    if let duration = job.duration, job.status != .running {
                        Text("·")
                        Text(duration.durationDescription)
                            .monospacedDigit()
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 4)

            trailing
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
                .fixedSize()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? Color.accentColor.opacity(0.18) : Color.clear)
        )
        .contentShape(Rectangle())
    }

    /// How long a running job has been going; when anything else happened.
    @ViewBuilder
    private var trailing: some View {
        if let stuckSince {
            Text("waiting \(Date().timeIntervalSince(stuckSince).durationDescription)")
                .foregroundStyle(.orange)
        } else if job.status == .running, let duration = job.duration {
            Text(duration.durationDescription)
        } else {
            Text((job.completedAt ?? job.startedAt ?? job.queuedAt)?.relativeDescription ?? "")
        }
    }
}
