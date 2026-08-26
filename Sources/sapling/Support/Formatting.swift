import Foundation
import SaplingCore

/// Terminal output helpers.
///
/// Colour is only emitted to a TTY so piping into `grep` or a file stays clean.
enum Style {
    static let isTTY = isatty(STDOUT_FILENO) == 1

    static func wrap(_ text: String, _ code: String) -> String {
        isTTY ? "\u{001B}[\(code)m\(text)\u{001B}[0m" : text
    }

    static func dim(_ text: String) -> String { wrap(text, "2") }
    static func bold(_ text: String) -> String { wrap(text, "1") }
    static func green(_ text: String) -> String { wrap(text, "32") }
    static func red(_ text: String) -> String { wrap(text, "31") }
    static func yellow(_ text: String) -> String { wrap(text, "33") }
    static func blue(_ text: String) -> String { wrap(text, "34") }

    static func status(_ status: JobStatus) -> String {
        switch status {
        case .completed: green(status.rawValue)
        case .failed: red(status.rawValue)
        case .running, .provisioning: blue(status.rawValue)
        case .cleanup: yellow(status.rawValue)
        case .queued: dim(status.rawValue)
        }
    }

    static func status(_ status: NodeStatus) -> String {
        switch status {
        case .online: green(status.rawValue)
        case .offline: red(status.rawValue)
        case .draining, .cordoned: yellow(status.rawValue)
        }
    }
}

enum Format {
    /// Compact relative time — job lists are read at a glance, and absolute
    /// timestamps make it hard to see what's recent.
    static func relative(_ date: Date?) -> String {
        guard let date else { return "—" }
        let seconds = Int(Date().timeIntervalSince(date))
        switch seconds {
        case ..<0: return "in the future"
        case 0..<60: return "\(seconds)s ago"
        case 60..<3600: return "\(seconds / 60)m ago"
        case 3600..<86400: return "\(seconds / 3600)h ago"
        default: return "\(seconds / 86400)d ago"
        }
    }

    static func duration(_ interval: TimeInterval?) -> String {
        guard let interval, interval >= 0 else { return "—" }
        let total = Int(interval)
        if total < 60 { return "\(total)s" }
        if total < 3600 { return "\(total / 60)m\(total % 60)s" }
        return "\(total / 3600)h\((total % 3600) / 60)m"
    }

    static func timestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }

    /// Left-aligned columns sized to their contents.
    static func table(headers: [String], rows: [[String]]) -> String {
        guard !rows.isEmpty else { return Style.dim("(none)") }
        var widths = headers.map { visibleLength($0) }
        for row in rows {
            for (index, cell) in row.enumerated() where index < widths.count {
                widths[index] = max(widths[index], visibleLength(cell))
            }
        }
        var lines: [String] = []
        lines.append(zip(headers, widths).map { Style.dim(pad($0.0, to: $0.1)) }.joined(separator: "  "))
        for row in rows {
            lines.append(
                zip(row, widths).map { pad($0.0, to: $0.1) }.joined(separator: "  ").trimmingTrailing())
        }
        return lines.joined(separator: "\n")
    }

    /// Column widths have to ignore ANSI escapes or coloured cells misalign.
    static func visibleLength(_ text: String) -> Int {
        var count = 0
        var inEscape = false
        for character in text {
            if character == "\u{001B}" {
                inEscape = true
                continue
            }
            if inEscape {
                if character == "m" { inEscape = false }
                continue
            }
            count += 1
        }
        return count
    }

    static func pad(_ text: String, to width: Int) -> String {
        let padding = max(0, width - visibleLength(text))
        return text + String(repeating: " ", count: padding)
    }

    static func truncate(_ text: String, to width: Int) -> String {
        text.count <= width ? text : String(text.prefix(width - 1)) + "…"
    }
}

extension String {
    func trimmingTrailing() -> String {
        var result = self
        while result.hasSuffix(" ") { result.removeLast() }
        return result
    }
}
