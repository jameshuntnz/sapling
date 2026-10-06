import SaplingCore
import SwiftUI

/// The always-visible strip: what to do to the node, and what it is running.
///
/// Split out of `PanelView` when draining joined pausing — three node actions
/// and a version readout is more than a nested `var` should carry.
struct PanelFooter: View {
    @Environment(AppModel.self) private var model
    @Binding var showingSettings: Bool

    var body: some View {
        HStack(spacing: 10) {
            nodeControls

            Spacer(minLength: 4)

            nodeVersion

            // When it last refreshed lives in the tooltip: it is "just now"
            // whenever the panel is open, which is the only time it is read.
            Button {
                Task { await model.refresh() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help(
                model.lastUpdated.map { "Refresh now — updated \($0.relativeDescription)" } ?? "Refresh now")

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

    /// Pause, drain, resume.
    ///
    /// Bordered, unlike the icon buttons beside them: these change what the
    /// node does, and as bare words they read as labels rather than controls.
    /// The words stay because they are what distinguishes two buttons which
    /// both stop the node taking work.
    @ViewBuilder
    private var nodeControls: some View {
        if let node = model.status?.node {
            HStack(spacing: 6) {
                if node.status == .online {
                    Button {
                        Task { await model.cordon() }
                    } label: {
                        Label("Pause", systemImage: "pause.fill")
                    }
                    .help("Stop accepting new jobs. Running jobs continue.")

                    Button {
                        Task { await model.drain() }
                    } label: {
                        Label("Drain", systemImage: "hourglass")
                    }
                    .help(
                        "Stop accepting new jobs and finish the running ones — what to do before "
                            + "an update or a reboot. The panel reports how many it is waiting on.")
                } else {
                    Button {
                        Task { await model.uncordon() }
                    } label: {
                        Label("Resume", systemImage: "play.fill")
                    }
                    .help("Start accepting jobs again.")
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .labelStyle(.titleAndIcon)
        }
    }

    /// What the node is running.
    ///
    /// Deliberately not compared against this app's own version. The source
    /// placeholder only moves on a stable release, so an app built from main —
    /// which is how the README says to install it — reports that placeholder
    /// while the node runs dev builds. Flagging that as a mismatch would be
    /// orange permanently, which is noise rather than signal. Comparing against
    /// the *release channel* is a different question, and `UpdateBanner`
    /// answers it.
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
                .truncationMode(.middle)
                .layoutPriority(-1)
                .help("Node is running \(version).")
        }
    }
}
