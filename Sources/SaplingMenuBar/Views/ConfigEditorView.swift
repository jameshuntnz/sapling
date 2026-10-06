import SaplingCore
import SwiftUI

/// The node's configuration: the live-reloadable settings editable, the rest
/// shown for reference.
///
/// Saving writes only the changed keys into `config.toml` — its comments
/// survive — and then reloads, so what comes back is what the node is now
/// actually running with rather than what was asked for.
struct ConfigEditorView: View {
    @Environment(AppModel.self) private var model
    @Binding var isPresented: Bool

    @State private var config: ConfigResponse?
    @State private var loadError: String?
    @State private var drafts: [String: String] = [:]
    @State private var result: ConfigReloadResponse?
    @State private var saving = false
    @State private var showingOthers = false

    private static let unset = "(unset)"

    private var editable: Set<String> { Set(config?.editableKeys ?? []) }

    private var changes: [String: String] {
        guard let config else { return [:] }
        var out: [String: String] = [:]
        for entry in config.entries where editable.contains(entry.key) {
            let original = entry.value == Self.unset ? "" : entry.value
            if let draft = drafts[entry.key], draft != original { out[entry.key] = draft }
        }
        return out
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: Metrics.sectionSpacing) {
                    if let loadError {
                        Label(loadError, systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let result { ResultView(result: result) }
                    if let config { content(config) }
                }
                .padding(.horizontal, Metrics.horizontalPadding)
                .padding(.vertical, 12)
            }
            Divider()
            footer
        }
        .task { await load() }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Button {
                isPresented = false
            } label: {
                Image(systemName: "chevron.left").font(.caption.weight(.semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            Text("Node configuration").font(.headline)
            Spacer()
        }
        .padding(.horizontal, Metrics.horizontalPadding)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private func content(_ config: ConfigResponse) -> some View {
        if config.editableKeys == nil {
            Text(
                "This node's daemon is too old to edit from here. Update it, or run `sapling config edit` on the node."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        if !config.pendingRestart.isEmpty {
            Label(
                "The file has \(config.pendingRestart.count) edit(s) waiting for a daemon restart.",
                systemImage: "arrow.triangle.2.circlepath"
            )
            .font(.caption)
            .foregroundStyle(.orange)
        }

        let groups = Dictionary(grouping: config.entries.filter { editable.contains($0.key) }) {
            String($0.key.split(separator: ".").first ?? "")
        }
        ForEach(groups.keys.sorted(), id: \.self) { table in
            VStack(alignment: .leading, spacing: 6) {
                SectionHeader(title: table)
                ForEach(groups[table] ?? [], id: \.key) { entry in
                    row(entry)
                }
            }
        }

        let others = config.entries.filter { !editable.contains($0.key) }
        if !others.isEmpty {
            DisclosureGroup("Set on the node (\(others.count))", isExpanded: $showingOthers) {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(others, id: \.key) { entry in
                        HStack(alignment: .firstTextBaseline) {
                            Text(entry.key).foregroundStyle(.secondary)
                            Spacer(minLength: 8)
                            Text(entry.value).lineLimit(1).truncationMode(.middle)
                        }
                        .font(.caption2.monospaced())
                    }
                }
                .padding(.top, 4)
            }
            .font(.caption)
            .help("Restart-only settings, credentials and trust settings change in config.toml on the node.")
        }

        Text(config.path)
            .font(.caption2.monospaced())
            .foregroundStyle(.tertiary)
            .textSelection(.enabled)
    }

    private func row(_ entry: ConfigEntry) -> some View {
        let original = entry.value == Self.unset ? "" : entry.value
        let binding = Binding(
            get: { drafts[entry.key] ?? original },
            set: { drafts[entry.key] = $0 })
        let changed = changes[entry.key] != nil
        return HStack(spacing: 8) {
            Text(entry.key.split(separator: ".").last.map(String.init) ?? entry.key)
                .font(.caption)
                .foregroundStyle(changed ? .primary : .secondary)
                .frame(width: 140, alignment: .leading)
                .lineLimit(1)
                .help(entry.key)
            TextField(original.isEmpty ? "default" : "", text: binding)
                .textFieldStyle(.roundedBorder)
                .font(.caption.monospaced())
                .overlay(alignment: .trailing) {
                    if changed {
                        Circle().fill(Color.accentColor).frame(width: 5, height: 5).padding(.trailing, 6)
                    }
                }
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Text(changes.isEmpty ? "No changes" : "\(changes.count) changed")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Revert") { drafts = [:] }
                .disabled(changes.isEmpty || saving)
            Button(saving ? "Saving…" : "Save & reload") {
                Task { await save() }
            }
            .buttonStyle(.borderedProminent)
            .disabled(changes.isEmpty || saving)
            .help("Writes the changed keys to config.toml on the node, keeping its comments, then reloads.")
        }
        .controlSize(.small)
        .padding(.horizontal, Metrics.horizontalPadding)
        .padding(.vertical, 8)
    }

    private func load() async {
        do {
            config = try await model.client.configuration()
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func save() async {
        saving = true
        defer { saving = false }
        do {
            result = try await model.client.updateConfig(changes)
            if result?.error == nil { drafts = [:] }
            await load()
        } catch {
            result = ConfigReloadResponse(
                reloaded: false, message: "nothing was written", error: error.localizedDescription)
        }
    }
}

/// What a save did: the changes applied, anything waiting for a restart, or
/// why nothing was written.
private struct ResultView: View {
    let result: ConfigReloadResponse

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let error = result.error {
                Label(error, systemImage: "xmark.octagon.fill").foregroundStyle(.red)
            } else {
                Label(result.message, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                ForEach(result.applied, id: \.key) { change in
                    Text("\(change.key): \(change.from) → \(change.to)")
                        .foregroundStyle(.secondary)
                }
                ForEach(result.pendingRestart, id: \.key) { change in
                    Text("\(change.key) needs a restart")
                        .foregroundStyle(.orange)
                }
            }
        }
        .font(.caption)
        .fixedSize(horizontal: false, vertical: true)
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
    }
}
