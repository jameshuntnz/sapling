import SaplingCore
import SwiftUI

struct ConnectionErrorView: View {
    let message: String
    let onSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Can't reach the daemon", systemImage: "bolt.horizontal.circle")
                .font(.callout.weight(.medium))
                .foregroundStyle(.orange)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("The node is only reachable over Tailscale — check that this Mac is on the same tailnet.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Server settings…", action: onSettings)
                .buttonStyle(.link)
                .font(.caption)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
    }
}
