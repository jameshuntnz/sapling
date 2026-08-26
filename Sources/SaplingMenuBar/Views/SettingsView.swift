import SaplingCore
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Binding var isPresented: Bool
    @State private var draft: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Button {
                    isPresented = false
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                Text("Settings").font(.headline)
                Spacer()
            }

            VStack(alignment: .leading, spacing: 5) {
                Text("Daemon address")
                    .font(.callout.weight(.medium))
                TextField("mac-mini:8734", text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.callout, design: .monospaced))
                    .onSubmit { apply() }
                Text(
                    "Hostname or Tailscale IP of the Mac running `sapling serve`. The port defaults to 8734."
                )
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            Button("Connect") { apply() }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)

            Spacer()

            VStack(alignment: .leading, spacing: 3) {
                Text("Sapling \(SaplingVersion.current)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Monitoring only — this app never orchestrates jobs itself.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(Metrics.horizontalPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { draft = model.serverAddress }
    }

    private func apply() {
        let trimmed = draft.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        model.serverAddress = trimmed
        isPresented = false
    }
}
