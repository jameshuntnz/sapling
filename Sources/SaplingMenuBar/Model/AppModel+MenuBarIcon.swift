import SaplingCore
import SwiftUI

/// The menu bar item itself: what it shows before anything is opened.
extension AppModel {
    /// What the menu bar icon should say at a glance.
    var iconSymbol: String {
        switch connection {
        case .failed: "exclamationmark.triangle.fill"
        case .connecting: "leaf"
        case .connected:
            if let status, status.node.status != .online {
                "pause.circle.fill"
            } else if !runningJobs.isEmpty {
                "leaf.fill"
            } else {
                "leaf"
            }
        }
    }

    var iconTint: Color? {
        switch connection {
        case .failed: .orange
        case .connecting: nil
        case .connected:
            if let status, status.node.status != .online {
                .yellow
            } else if !runningJobs.isEmpty {
                .green
            } else {
                nil
            }
        }
    }

    /// Slot usage next to the icon, so the common question ("is anything
    /// running?") is answered without opening anything.
    var menuBarLabel: String? {
        guard case .connected = connection, let status else { return nil }
        let inUse = status.slots.reduce(0) { $0 + $1.inUse }
        return inUse > 0 ? "\(inUse)" : nil
    }
}
