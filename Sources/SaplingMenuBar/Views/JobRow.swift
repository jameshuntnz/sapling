import SaplingCore
import SwiftUI

struct JobRow: View {
    let job: Job
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: Palette.symbol(for: job.status))
                .foregroundStyle(Palette.color(for: job.status))
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
                    if let duration = job.duration {
                        Text("·")
                        Text(duration.durationDescription)
                            .monospacedDigit()
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 4)

            Text((job.completedAt ?? job.startedAt ?? job.queuedAt)?.relativeDescription ?? "")
                .font(.caption2)
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
}
