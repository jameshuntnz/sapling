import SaplingCore
import SwiftUI

/// Slot usage as filled and empty pips.
///
/// The macOS row is annotated with Apple's 2-VM limit on purpose: "1/2" looks
/// like a configuration choice you could raise, and it isn't.
struct SlotsView: View {
    let slots: [SlotUsage]

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.rowSpacing) {
            ForEach(slots, id: \.platform) { slot in
                HStack(spacing: 8) {
                    Text(slot.platform == .macos ? "macOS" : "Linux")
                        .font(.system(.callout, design: .rounded))
                        .frame(width: 52, alignment: .leading)

                    HStack(spacing: 3) {
                        ForEach(0..<max(slot.capacity, 1), id: \.self) { index in
                            Circle()
                                .fill(index < slot.inUse ? Color.accentColor : Color.secondary.opacity(0.25))
                                .frame(width: 8, height: 8)
                        }
                    }

                    Text("\(slot.inUse)/\(slot.capacity)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)

                    if slot.platform == .macos {
                        Text("Apple limit")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .help(
                                "Apple's virtualization licensing allows at most two concurrent macOS VMs per host."
                            )
                    }
                    Spacer()
                }
            }
        }
    }
}
