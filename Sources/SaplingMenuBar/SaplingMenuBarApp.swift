import SaplingCore
import SwiftUI

/// The menu bar app (§5.4): a thin client over the same REST API the CLI
/// uses, running on whichever Mac you happen to be at and reaching the node
/// over Tailscale.
@main
struct SaplingMenuBarApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            PanelView()
                .environment(model)
                .onAppear {
                    model.isMenuOpen = true
                    Task { await model.refresh() }
                }
                .onDisappear { model.isMenuOpen = false }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: model.iconSymbol)
                    .foregroundStyle(model.iconTint ?? .primary)
                if let label = model.menuBarLabel {
                    Text(label).monospacedDigit()
                }
            }
            .onAppear { model.start() }
        }
        .menuBarExtraStyle(.window)
    }
}
