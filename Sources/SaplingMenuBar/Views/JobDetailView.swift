import SaplingCore
import SwiftUI

/// The log viewer (§5.4).
///
/// Reads the `runs` event log rather than a live process stream, which means
/// it works identically for a job that finished an hour ago and one running
/// right now — and keeps working if the connection drops mid-job.
struct JobDetailView: View {
    let detail: JobDetailResponse
    let onBack: () -> Void

    @State private var autoScroll = true

    private var job: Job { detail.job }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
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

            if let reason = job.exitReason {
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, Metrics.horizontalPadding)
        .padding(.vertical, 10)
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
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
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
