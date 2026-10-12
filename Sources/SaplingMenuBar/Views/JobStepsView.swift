import SaplingCore
import SwiftUI

/// The selected job's steps, as listed on its page on GitHub.
struct JobStepsView: View {
    let job: Job
    let response: JobStepsResponse?

    private var steps: [JobStep] { response?.steps ?? [] }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 1) {
                if let summary {
                    Text(summary)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.bottom, 5)
                }
                if steps.isEmpty {
                    Text(emptyMessage)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(steps) { step in
                    StepRow(step: step, url: url(for: step))
                }
            }
            .padding(.horizontal, Metrics.horizontalPadding)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var summary: String? {
        guard !steps.isEmpty else { return nil }
        let done = steps.filter { $0.status == "completed" }.count
        if let running = steps.first(where: { $0.state == .running }) {
            return "Step \(running.number) of \(steps.count) · \(done) done"
        }
        return "\(done) of \(steps.count) steps done"
    }

    private var emptyMessage: String {
        if let reason = response?.unavailableReason { return "Steps unavailable: \(Format.oneLine(reason))" }
        if response == nil { return "Loading steps…" }
        if job.status.isTerminal { return "GitHub lists no steps for this job." }
        return "No steps yet — GitHub lists them once a runner starts the job."
    }

    /// The step's place on the job's GitHub page, when the run is known.
    private func url(for step: JobStep) -> URL? {
        guard job.assignedRunID != nil || job.workflowRunID != nil, let page = job.gitHubURL else {
            return nil
        }
        return URL(string: page.absoluteString + "#step:\(step.number):1")
    }
}

/// One step: its state, name and how long it took.
private struct StepRow: View {
    let step: JobStep
    let url: URL?

    @Environment(\.openURL) private var openURL

    var body: some View {
        HStack(spacing: 7) {
            icon.frame(width: 14)
            Text(step.name)
                .font(.callout)
                .foregroundStyle(step.state == .pending || step.state == .skipped ? .secondary : .primary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 6)
            if step.state == .running {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    durationText(step.duration(now: context.date))
                }
            } else {
                durationText(step.duration())
            }
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 4)
        .background(
            step.state == .running ? Color.blue.opacity(0.08) : .clear,
            in: RoundedRectangle(cornerRadius: 4)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            if let url { openURL(url) }
        }
        .help(url == nil ? step.name : "Open this step on GitHub")
    }

    @ViewBuilder
    private var icon: some View {
        switch step.state {
        case .running:
            ProgressView().controlSize(.mini)
        case .succeeded:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed:
            Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        case .cancelled:
            Image(systemName: "slash.circle").foregroundStyle(.secondary)
        case .skipped:
            Image(systemName: "minus.circle").foregroundStyle(.tertiary)
        case .pending:
            Image(systemName: "circle.dashed").foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder
    private func durationText(_ duration: TimeInterval?) -> some View {
        if let duration, step.state != .skipped {
            Text(duration.durationDescription)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }
}
