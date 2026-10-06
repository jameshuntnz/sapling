import SaplingCore
import SwiftUI

/// News about the node's own version, when there is any.
///
/// Sits at the top of the overview rather than in the footer because it is the
/// one thing here that asks something of you. When the node is current it
/// renders nothing at all — a banner that is always present stops being read.
struct UpdateBanner: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        switch model.updateState {
        case .none:
            EmptyView()
        case .available(let version, let channel, let publishedAt):
            banner(
                symbol: "arrow.down.circle.fill",
                tint: .accentColor,
                title: "\(version) available",
                detail: detail(channel: channel, publishedAt: publishedAt)
            ) {
                Button("Update") { Task { await model.applyUpdate() } }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
        case .installing(let version):
            banner(
                symbol: "arrow.triangle.2.circlepath",
                tint: .accentColor,
                title: "Installing \(version)",
                detail: "The daemon is restarting. This reconnects on its own."
            ) {
                ProgressView().controlSize(.small)
            }
        case .refused(let message):
            // The overwhelmingly common reason is jobs running, which the
            // daemon refuses rather than orphaning their VMs. Offering to
            // override is the point of showing this at all.
            banner(
                symbol: "exclamationmark.triangle.fill",
                tint: .orange,
                title: "Not updated",
                detail: message
            ) {
                Button("Update anyway") { Task { await model.applyUpdate(force: true) } }
                    .controlSize(.small)
            }
        case .checkFailed(let message):
            // One quiet line. Not knowing whether an update exists asks
            // nothing of you, and a card the size of "update available" for it
            // outweighed everything else on the panel.
            HStack(spacing: 5) {
                Image(systemName: "exclamationmark.circle")
                Text("Couldn't check for updates")
                Spacer(minLength: 4)
                Button("Retry") { Task { await model.checkForUpdate() } }
                    .buttonStyle(.link)
                    .foregroundStyle(Color.accentColor)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .help(message)
        }
    }

    private func detail(channel: ReleaseChannel, publishedAt: Date?) -> String {
        let stream = "\(channel.rawValue) channel"
        guard let publishedAt else { return stream }
        return "\(stream) · published \(publishedAt.relativeDescription)"
    }

    private func banner(
        symbol: String,
        tint: Color,
        title: String,
        detail: String,
        @ViewBuilder action: () -> some View
    ) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.callout.weight(.medium))
                Text(Format.oneLine(detail))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .help(detail)
            }
            Spacer(minLength: 4)
            action()
        }
        .padding(10)
        .background(tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
    }
}
