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
    @State private var autoScroll = true
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
            log
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

    /// Cancel while the job is live, retry once it is over — never both,
    /// because they are never both meaningful.
    ///
    /// Cancelling is behind a confirmation and retrying is not: one throws away
    /// work in progress, the other only costs a slot for as long as the job
    /// takes. Guarding both equally would train the reflex that dismisses the
    /// guard.
    @ViewBuilder
    private var actions: some View {
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

    private var log: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if detail.events.isEmpty {
                        Text("No events yet.")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .padding(.top, 8)
                    }
                    ForEach(detail.events) { event in
                        EventLine(event: event)
                            .id(event.id)
                    }
                }
                .padding(.horizontal, Metrics.horizontalPadding)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: detail.events.count) {
                guard autoScroll, let last = detail.events.last?.id else { return }
                withAnimation(.easeOut(duration: 0.15)) {
                    proxy.scrollTo(last, anchor: .bottom)
                }
            }
            .onAppear {
                guard let last = detail.events.last?.id else { return }
                proxy.scrollTo(last, anchor: .bottom)
            }
        }
    }
}

/// One log line.
///
/// Lifecycle events are labelled and tinted; plain log output is left alone so
/// build output looks like build output.
struct EventLine: View {
    let event: RunEvent

    private var isLifecycle: Bool { event.event != RunEventName.log }

    var body: some View {
        HStack(alignment: .top, spacing: 7) {
            Text(event.ts, format: .dateTime.hour().minute().second())
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.quaternary)
                .fixedSize()

            if isLifecycle {
                VStack(alignment: .leading, spacing: 1) {
                    Text(event.event.replacingOccurrences(of: "_", with: " "))
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(tint)
                    if let detail = event.detail {
                        Text(detail)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
            } else {
                Text(event.detail ?? "")
                    .font(.system(size: 11, design: .monospaced))
                    // The runner's own annotations, so the line that failed
                    // the build is findable without reading the whole log.
                    .foregroundStyle(annotationTint ?? .primary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    /// Red for `##[error]`, orange for `##[warning]`, nothing otherwise.
    private var annotationTint: Color? {
        guard let detail = event.detail else { return nil }
        if detail.contains("##[error]") { return .red }
        if detail.contains("##[warning]") { return .orange }
        return nil
    }

    private var tint: Color {
        switch event.event {
        case RunEventName.jobFailed: .red
        case RunEventName.jobCompleted: .green
        case RunEventName.cleanupStarted, RunEventName.cleanupFinished: .orange
        default: .blue
        }
    }
}
