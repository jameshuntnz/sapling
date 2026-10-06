import SaplingCore
import SwiftUI

struct PanelView: View {
    @Environment(AppModel.self) private var model
    @State private var showingSettings = false
    @State private var showingDisk = false

    var body: some View {
        VStack(spacing: 0) {
            if let detail = model.selectedJobDetail {
                JobDetailView(detail: detail, resources: model.selectedJobResources) {
                    model.select(jobID: nil)
                }
            } else if showingSettings {
                SettingsView(isPresented: $showingSettings)
            } else if showingDisk {
                DiskView(isPresented: $showingDisk)
            } else {
                overview
            }
            Divider()
            PanelFooter(showingSettings: $showingSettings)
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
                    // A connection that dropped because we asked the daemon
                    // to restart is not a fault, and reporting it as one sends
                    // you looking for a problem you caused on purpose. The
                    // banner says what is actually happening.
                    if case .failed(let message) = model.connection, !model.isRestarting {
                        ConnectionErrorView(message: message) { showingSettings = true }
                    }

                    UpdateBanner()

                    if let message = model.lastActionMessage {
                        Text(Format.oneLine(message))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .help(message)
                    }

                    if let status = model.status {
                        VStack(alignment: .leading, spacing: 8) {
                            SectionHeader(title: "Capacity")
                            // Memory first: it is what admission actually
                            // gates on, and a node can be idle by slot count
                            // while being unable to start anything at all.
                            BudgetView(
                                budgetGB: status.memoryBudgetGB,
                                committedGB: status.committedMemoryGB,
                                holdings: model.memoryHoldings)
                            SlotsView(slots: status.slots)
                            if let total = status.diskTotalBytes, let free = status.diskFreeBytes {
                                DiskSummaryRow(total: total, free: free) { showingDisk = true }
                            }
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
                        queuedSection(reasons: model.queueReasons)
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

    /// The queue, with each job's reason for waiting beneath it.
    ///
    /// A queued job with no explanation invites the wrong conclusion. The
    /// awkward case is a small job held behind a larger one — deliberate, so
    /// the large one is not starved, and indistinguishable from a stuck
    /// scheduler unless it says which job it is waiting on.
    private func queuedSection(reasons: [String: QueueReason]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            SectionHeader(title: "Queued", trailing: "\(model.queuedJobs.count)")
            ForEach(model.queuedJobs) { job in
                VStack(alignment: .leading, spacing: 1) {
                    JobRow(
                        job: job, isSelected: job.id == model.selectedJobID,
                        stuckSince: model.stuckSince(jobID: job.id)
                    )
                    .onTapGesture { model.select(jobID: job.id) }
                    if let reason = reasons[job.id] {
                        Text(reason.summary)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .padding(.leading, 26)
                    }
                }
            }
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
                    JobRow(
                        job: job, isSelected: job.id == model.selectedJobID,
                        stuckSince: model.stuckSince(jobID: job.id)
                    )
                    .onTapGesture { model.select(jobID: job.id) }
                }
            }
        }
    }
}
