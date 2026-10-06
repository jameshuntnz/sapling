import SaplingCore
import SwiftUI

/// The selected job's event log, newest at the bottom.
///
/// Opens on the newest page — the end is where the outcome is — and pages
/// back on request. Runner diagnostics are hidden unless asked for: one of
/// them is the job message dumped as thousands of lines of JSON, which buried
/// the build output this view exists to show.
struct JobLogView: View {
    let pager: LogPager

    @Environment(AppModel.self) private var model
    @AppStorage("sapling.log.showDiagnostics") private var showDiagnostics = false

    private var visible: [RunEvent] {
        showDiagnostics ? pager.events : pager.events.filter { !$0.isRunnerDiagnostic }
    }

    private var hiddenCount: Int { pager.events.count - visible.count }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        if pager.hasEarlier {
                            Button {
                                Task { await pager.loadEarlier(client: model.client) }
                            } label: {
                                Label(
                                    pager.isLoadingEarlier ? "Loading…" : "Load earlier events",
                                    systemImage: "arrow.up")
                            }
                            .buttonStyle(.link)
                            .font(.caption)
                            .disabled(pager.isLoadingEarlier)
                            .padding(.bottom, 4)
                        }
                        if visible.isEmpty {
                            Text("No events yet.")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                                .padding(.top, 8)
                        }
                        ForEach(visible) { event in
                            EventLine(event: event)
                                .id(event.id)
                        }
                    }
                    .padding(.horizontal, Metrics.horizontalPadding)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                // Keyed on the newest event, not the count: paging back adds
                // events too, and must not yank the view to the bottom.
                .onChange(of: visible.last?.id) {
                    guard let last = visible.last?.id else { return }
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo(last, anchor: .bottom)
                    }
                }
                .onAppear {
                    guard let last = visible.last?.id else { return }
                    proxy.scrollTo(last, anchor: .bottom)
                }
            }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 6) {
            Text("Log")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            if !showDiagnostics, hiddenCount > 0 {
                Text("\(hiddenCount) runner lines hidden")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            Toggle("Runner diagnostics", isOn: $showDiagnostics)
                .toggleStyle(.checkbox)
                .font(.caption2)
                .help("Show the runner's own [RUNNER] and [WORKER] lines.")
        }
        .padding(.horizontal, Metrics.horizontalPadding)
        .padding(.vertical, 5)
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
