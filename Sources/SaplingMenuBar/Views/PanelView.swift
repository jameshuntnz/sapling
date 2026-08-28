import SaplingCore
import SwiftUI

struct PanelView: View {
    @Environment(AppModel.self) private var model
    @State private var showingSettings = false

    var body: some View {
        VStack(spacing: 0) {
            if let detail = model.selectedJobDetail {
                JobDetailView(detail: detail, resources: model.selectedJobResources) {
                    model.select(jobID: nil)
                }
            } else if showingSettings {
                SettingsView(isPresented: $showingSettings)
            } else {
                overview
            }
            Divider()
            footer
        }
        .frame(width: Metrics.panelWidth, height: Metrics.panelHeight)
    }

    // MARK: - Overview

    private var overview: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: Metrics.sectionSpacing) {
                    if case .failed(let message) = model.connection {
                        ConnectionErrorView(message: message) { showingSettings = true }
                    }

                    if let status = model.status {
                        VStack(alignment: .leading, spacing: 8) {
                            SectionHeader(title: "Slots")
                            SlotsView(slots: status.slots)
                        }

                        if let metrics = status.metrics {
                            VStack(alignment: .leading, spacing: 8) {
                                SectionHeader(
                                    title: "Node",
                                    trailing: metrics.isUnderMemoryPressure ? "under pressure" : nil)
                                MetricsView(metrics: metrics, history: model.metricsHistory)
                            }
                        }

                        if let error = status.lastPollError {
                            Label(error, systemImage: "exclamationmark.triangle")
                                .font(.caption)
                                .foregroundStyle(.orange)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    jobSection(title: "Running", jobs: model.runningJobs, emptyText: "Nothing running.")

                    if !model.queuedJobs.isEmpty {
                        jobSection(title: "Queued", jobs: model.queuedJobs, emptyText: "")
                    }

                    jobSection(
                        title: "Recent",
                        jobs: Array(model.recentJobs.prefix(12)),
                        emptyText: "No completed jobs yet."
                    )
                }
                .padding(.horizontal, Metrics.horizontalPadding)
                .padding(.vertical, 12)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.status?.node.name ?? "Sapling")
                    .font(.headline)
                    .lineLimit(1)

                HStack(spacing: 5) {
                    switch model.connection {
                    case .connecting:
                        Text("Connecting…")
                    case .failed:
                        Text("Unreachable").foregroundStyle(.orange)
                    case .connected:
                        if let repos = model.status?.watchedRepos, !repos.isEmpty {
                            Text(repos.joined(separator: ", "))
                                .lineLimit(1)
                                .truncationMode(.middle)
                        } else {
                            Text("No repositories configured").foregroundStyle(.orange)
                        }
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer()

            if let node = model.status?.node {
                StatusPill(text: node.status.rawValue, color: Palette.color(for: node.status))
            }
        }
        .padding(.horizontal, Metrics.horizontalPadding)
        .padding(.vertical, 10)
    }

    /// What the node is running.
    ///
    /// Deliberately not compared against this app's own version. The source
    /// placeholder only moves on a stable release, so an app built from main —
    /// which is how the README says to install it — reports that placeholder
    /// while the node runs dev builds. Flagging that as a mismatch would be
    /// orange permanently, which is noise rather than signal.
    ///
    /// Build metadata is dropped for width; the tooltip carries it, since the
    /// commit is the part you want when asking why a node behaves oddly.
    @ViewBuilder
    private var nodeVersion: some View {
        if let version = model.status?.version {
            Text(SemanticVersion(version)?.withoutBuildMetadata ?? version)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .help("Node is running \(version).")
        }
    }

    private func jobSection(title: String, jobs: [Job], emptyText: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            SectionHeader(title: title, trailing: jobs.isEmpty ? nil : "\(jobs.count)")
            if jobs.isEmpty {
                if !emptyText.isEmpty {
                    Text(emptyText)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .padding(.leading, 8)
                }
            } else {
                ForEach(jobs) { job in
                    JobRow(job: job, isSelected: job.id == model.selectedJobID)
                        .onTapGesture { model.select(jobID: job.id) }
                }
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 10) {
            if let node = model.status?.node {
                if node.status == .online {
                    Button {
                        Task { await model.cordon() }
                    } label: {
                        Label("Pause", systemImage: "pause.fill")
                    }
                    .help("Stop accepting new jobs. Running jobs continue.")
                } else {
                    Button {
                        Task { await model.uncordon() }
                    } label: {
                        Label("Resume", systemImage: "play.fill")
                    }
                    .help("Start accepting jobs again.")
                }
            }

            Spacer()

            nodeVersion

            if let updated = model.lastUpdated {
                Text(updated.relativeDescription)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Button {
                Task { await model.refresh() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help("Refresh now")

            Button {
                model.select(jobID: nil)
                showingSettings.toggle()
            } label: {
                Image(systemName: "gearshape")
            }
            .help("Settings")

            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Image(systemName: "power")
            }
            .help("Quit Sapling")
        }
        .buttonStyle(.borderless)
        .font(.caption)
        .padding(.horizontal, Metrics.horizontalPadding)
        .padding(.vertical, 8)
    }
}
