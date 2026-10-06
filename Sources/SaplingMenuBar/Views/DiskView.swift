import SaplingCore
import SwiftUI

/// Whether free space is low enough to say so.
///
/// Both a fraction and a floor: 15% of a 2TB disk is plenty, and 20GB is less
/// than one macOS clone can grow by during a build.
enum DiskThreshold {
    static func isLow(free: Int64, total: Int64) -> Bool {
        guard total > 0 else { return false }
        return Double(free) / Double(total) < 0.15 || free < 20 * 1_073_741_824
    }
}

/// The disk line under Capacity, opening the breakdown.
struct DiskSummaryRow: View {
    let total: Int64
    let free: Int64
    let onOpen: () -> Void

    private var low: Bool { DiskThreshold.isLow(free: free, total: total) }
    private var usedFraction: Double { total > 0 ? Double(total - free) / Double(total) : 0 }

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text("Disk")
                        .font(.system(.caption, design: .rounded).weight(.medium))
                        .frame(width: 52, alignment: .leading)
                        .foregroundStyle(.primary)
                    Text("\(Format.bytes(free)) free of \(Format.bytes(total))")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(low ? .orange : .secondary)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Rectangle().fill(Color.secondary.opacity(0.15))
                        Rectangle()
                            .fill(low ? Color.orange : Color.secondary.opacity(0.55))
                            .frame(width: geometry.size.width * usedFraction)
                    }
                    .clipShape(Capsule())
                }
                .frame(height: 6)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("What is using the node's disk, and what can be cleared")
    }
}

/// What is using the node's disk, with the cleanups a person can choose.
struct DiskView: View {
    @Environment(AppModel.self) private var model
    @Binding var isPresented: Bool

    @State private var report: DiskReport?
    @State private var loadError: String?
    @State private var result: DiskCleanupResponse?
    @State private var running: String?
    @State private var confirming: DiskItem?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Button {
                    isPresented = false
                } label: {
                    Image(systemName: "chevron.left").font(.caption.weight(.semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                Text("Disk").font(.headline)
                Spacer()
                if let report {
                    Text("\(Format.bytes(report.freeBytes)) free")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(
                            DiskThreshold.isLow(free: report.freeBytes, total: report.totalBytes)
                                ? .orange : .secondary)
                }
            }
            .padding(.horizontal, Metrics.horizontalPadding)
            .padding(.vertical, 10)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if let loadError {
                        Label(loadError, systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let result { resultView(result) }
                    if report == nil, loadError == nil {
                        ProgressView().controlSize(.small).frame(maxWidth: .infinity)
                    }
                    ForEach(report?.items ?? []) { item in
                        row(item)
                        Divider()
                    }
                    if report != nil {
                        Text(
                            "Sizes are as each tool reports them and overlap: macOS VMs are clones "
                                + "that share most of their blocks with the base image."
                        )
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.horizontal, Metrics.horizontalPadding)
                .padding(.vertical, 12)
            }
        }
        .task { await load() }
        .confirmationDialog(
            confirming.map { "\(title(for: $0.action)) — \($0.name)?" } ?? "",
            isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }),
            presenting: confirming
        ) { item in
            Button(title(for: item.action), role: .destructive) {
                Task { await clean(item) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { item in
            Text(item.detail)
        }
    }

    private func row(_ item: DiskItem) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(item.name).font(.callout)
                Spacer()
                Text(Format.bytes(item.bytes))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Text(item.detail)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let action = item.action {
                HStack(spacing: 8) {
                    Button(role: .destructive) {
                        confirming = item
                    } label: {
                        Text(running == item.id ? "Working…" : title(for: action))
                    }
                    .controlSize(.small)
                    .disabled(running != nil)
                    if let reclaimable = item.reclaimableBytes, reclaimable > 0 {
                        Text("frees up to \(Format.bytes(reclaimable))")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }

    private func resultView(_ result: DiskCleanupResponse) -> some View {
        Group {
            if let error = result.error {
                Label(error, systemImage: "xmark.octagon.fill").foregroundStyle(.red)
            } else {
                let freed = result.freedBytes.map { " — \(Format.bytes($0)) freed" } ?? ""
                Label(result.message + freed, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            }
        }
        .font(.caption)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func title(for action: DiskAction?) -> String {
        switch action {
        case .deleteVM: "Delete VM"
        case .pruneImages: "Remove unused images"
        case .trimLogs: "Trim old logs"
        case nil: ""
        }
    }

    private func load() async {
        do {
            report = try await model.client.disk()
            loadError = nil
        } catch {
            loadError =
                "Couldn't load the disk report: \(error.localizedDescription). "
                + "Nodes older than this app can't report it."
        }
    }

    private func clean(_ item: DiskItem) async {
        guard let action = item.action else { return }
        running = item.id
        defer { running = nil }
        do {
            result = try await model.client.cleanDisk(action, target: item.target)
        } catch {
            result = DiskCleanupResponse(message: "nothing was removed", error: error.localizedDescription)
        }
        await load()
        await model.refresh()
    }
}
