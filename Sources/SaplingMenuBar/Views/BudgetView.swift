import SaplingCore
import SwiftUI

/// The node's job memory, segmented by what each running job holds.
///
/// Given first billing above the slot pips because it is the limit that
/// actually decides what starts. Counts bound what memory cannot see — disk
/// for checkouts and image layers, CPU oversubscription — so a node reading
/// "Linux 1/4" can be three-quarters idle by slot and entirely full by memory.
/// Showing only the pips in that state is confidently wrong at the exact
/// moment somebody opens this panel to ask why nothing is starting.
///
/// Segments are per job rather than one aggregate bar: "8 of 12GB" says the
/// node is busy, and "Android 6GB, iOS 2GB" says which job to look at.
struct BudgetView: View {
    let budgetGB: Int
    let committedGB: Int
    /// Running jobs and the memory each reserved, largest first.
    let holdings: [(name: String, gb: Int)]

    private var freeGB: Int { max(0, budgetGB - committedGB) }
    /// Reserved memory no listed job accounts for.
    ///
    /// Drawn rather than dropped: the bar used to show only per-job segments,
    /// so a node reporting "16 of 28GB reserved" with none attributed drew an
    /// empty bar beside a figure saying the opposite.
    private var unattributedGB: Int { max(0, committedGB - holdings.reduce(0) { $0 + $1.gb }) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text("Memory")
                    .font(.system(.caption, design: .rounded).weight(.medium))
                    .frame(width: 52, alignment: .leading)
                Text("\(committedGB) of \(budgetGB)GB reserved")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(freeGB)GB free")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(freeGB == 0 ? .orange : .secondary)
            }

            GeometryReader { geometry in
                HStack(spacing: 1) {
                    ForEach(Array(holdings.enumerated()), id: \.offset) { index, holding in
                        Rectangle()
                            .fill(fill.opacity(index.isMultiple(of: 2) ? 0.9 : 0.65))
                            .frame(width: width(for: holding.gb, in: geometry.size.width))
                            .help("\(holding.name) — \(holding.gb)GB")
                    }
                    if unattributedGB > 0 {
                        Rectangle()
                            .fill(fill.opacity(0.45))
                            .frame(width: width(for: unattributedGB, in: geometry.size.width))
                            .help("\(unattributedGB)GB reserved")
                    }
                    Rectangle()
                        .fill(Color.secondary.opacity(0.15))
                }
                .clipShape(Capsule())
            }
            .frame(height: 6)

            // Named only when there is room to read them; the bar itself
            // carries the proportions and the tooltips carry the rest.
            if holdings.count <= 3, !holdings.isEmpty {
                Text(holdings.map { "\($0.name) \($0.gb)GB" }.joined(separator: " · "))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
    }

    /// Accent while there is room, orange once nothing more can start.
    private var fill: Color { freeGB == 0 ? .orange : .accentColor }

    /// A segment's width, guarding the divide-by-zero of an unconfigured node.
    private func width(for gb: Int, in total: CGFloat) -> CGFloat {
        guard budgetGB > 0 else { return 0 }
        return max(2, total * CGFloat(gb) / CGFloat(budgetGB))
    }
}
