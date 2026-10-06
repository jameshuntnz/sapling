import SaplingCore
import SwiftUI

/// The log viewer (§5.4).
///
/// Reads the `runs` event log rather than a live process stream, which means
/// it works identically for a job that finished an hour ago and one running
/// right now — and keeps working if the connection drops mid-job.
struct JobDetailView: View {
    let detail: JobDetailResponse
    /// What this job's environment is using, when the node is reporting it.
    let resources: JobResourcesResponse?
    let onBack: () -> Void

    @Environment(AppModel.self) private var model
    @State private var confirmingCancel = false

    private var job: Job { detail.job }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if let resources, !resources.isEmpty {
                Divider()
                JobResourcesView(resources: resources)
                    .padding(.horizontal, Metrics.horizontalPadding)
                    .padding(.vertical, 9)
            }
            Divider()
            JobLogView(pager: model.logPager)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Button(action: onBack) {
                    Image(systemName: "chevron.left")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)

                Text(job.name ?? "job \(job.id)")
                    .font(.headline)
                    .lineLimit(1)

                Spacer()

                StatusPill(text: job.status.rawValue, color: Palette.color(for: job.status))
            }

            HStack(spacing: 6) {
                Label(job.repo, systemImage: "shippingbox")
                Text("·")
                Text(job.platform.rawValue)
                if let duration = job.duration {
                    Text("·")
                    Text(duration.durationDescription).monospacedDigit()
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)

            if !job.labels.isEmpty {
                HStack(spacing: 4) {
                    ForEach(job.labels, id: \.self) { label in
                        Text(label)
                            .font(.caption2)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.secondary.opacity(0.12), in: Capsule())
                    }
                }
            }

            if let since = model.stuckSince(jobID: job.id) {
                stuckNotice(since: since)
            }

            actions

            if let message = model.lastActionMessage {
                Text(Format.oneLine(message))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .help(message)
            }

            if let reason = job.exitReason {
                let kind = FailureKind.of(reason: reason)
                // Named when it is not the build's fault. A memory kill and a
                // refusal both arrive as a failed job with a reason, and both
                // send someone to the wrong place unless the difference is
                // stated: one is a setting to change, not code to fix.
                if let label = kind.label {
                    Label(label, systemImage: kind.symbol)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.orange)
                }
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(kind == .build ? .red : .secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, Metrics.horizontalPadding)
        .padding(.vertical, 10)
    }

    /// Stop or retry, and a way out to GitHub.
    private var actions: some View {
        HStack(spacing: 6) {
            jobControl
            if let url = job.gitHubURL {
                Link(destination: url) {
                    Label("Open on GitHub", systemImage: "arrow.up.right.square")
                }
                .controlSize(.small)
                .buttonStyle(.bordered)
                .help(url.absoluteString)
            }
        }
    }

    /// Said plainly, because nothing else on screen would: the job reads as
    /// running, the runner's last line is a healthy "Listening for Jobs", and
    /// the slot stays held until the job timeout.
    private func stuckNotice(since: Date) -> some View {
        Label {
            Text(
                "Runner has waited \(Date().timeIntervalSince(since).durationDescription) for GitHub "
                    + "to assign this job. If GitHub already ran it elsewhere, it never will — "
                    + "stopping it frees the slot.")
        } icon: {
            Image(systemName: "hourglass")
        }
        .font(.caption)
        .foregroundStyle(.orange)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// Cancel while the job is live, retry once it is over — never both,
    /// because they are never both meaningful.
    ///
    /// Cancelling is behind a confirmation and retrying is not: one throws away
    /// work in progress, the other only costs a slot for as long as the job
    /// takes. Guarding both equally would train the reflex that dismisses the
    /// guard.
    @ViewBuilder
    private var jobControl: some View {
        if job.status.isTerminal {
            Button {
                Task { await model.retry(jobID: job.id) }
            } label: {
                Label("Retry", systemImage: "arrow.clockwise")
            }
            .controlSize(.small)
            .help("Queue this job to run again on the next poll.")
        } else {
            Button(role: .destructive) {
                confirmingCancel = true
            } label: {
                Label("Stop job", systemImage: "stop.fill")
            }
            .controlSize(.small)
            .help("Stop this job and free its slot.")
            .confirmationDialog(
                "Stop \(job.name ?? "job \(job.id)")?",
                isPresented: $confirmingCancel
            ) {
                Button("Stop job", role: .destructive) {
                    Task { await model.cancel(jobID: job.id) }
                }
                Button("Keep running", role: .cancel) {}
            } message: {
                Text(
                    "The environment is torn down and the slot is freed. The job is not "
                        + "cancelled on GitHub — it stays queued there until its own timeout, "
                        + "and this node will not pick it up again.")
            }
        }
    }
}
