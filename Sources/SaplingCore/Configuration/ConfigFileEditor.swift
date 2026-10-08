import Foundation

/// Changes individual values in `config.toml` without rewriting the rest.
///
/// The file is hand-written, and its comments — why a node has the memory it
/// has, which repo needed what — are worth more than the convenience of an
/// editor (README, Configuration). Re-encoding the parsed config would drop
/// every one of them, so this edits the text: the line holding a key is
/// replaced, its trailing comment kept, and everything else left byte for byte.
///
/// Only `table.key` paths are supported, which covers every field the API lets
/// a client change.
public enum ConfigFileEditor {
    /// Why an edit could not be made.
    public struct EditError: Error, LocalizedError, Sendable {
        /// What went wrong, phrased for a person.
        public let message: String
        /// Describes the failure.
        public var errorDescription: String? { message }
    }

    /// Applies values to a config file's text.
    ///
    /// - Parameters:
    ///   - values: Dotted keys mapped to their new value, in the form
    ///     `ConfigEntry.value` displays them. An empty value removes the key.
    ///   - text: The file as it is.
    /// - Returns: The edited text.
    /// - Throws: `EditError` for a key that is not `table.key`.
    public static func apply(_ values: [String: String], to text: String) throws -> String {
        var lines = text.components(separatedBy: "\n")
        for key in values.keys.sorted() {
            let parts = key.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else {
                throw EditError(message: "\(key) is not a table.key path")
            }
            let raw = values[key] ?? ""
            let literal = raw.trimmingCharacters(in: .whitespaces).isEmpty ? nil : self.literal(for: raw)
            set(table: parts[0], key: parts[1], literal: literal, in: &lines)
        }
        return lines.joined(separator: "\n")
    }

    /// The TOML literal for a displayed value.
    ///
    /// The type is inferred rather than declared, then checked by loading the
    /// result: a wrong guess is rejected before anything is written.
    ///
    /// - Parameter raw: A value as `ConfigEntry.value` shows it.
    /// - Returns: The value as TOML.
    public static func literal(for raw: String) -> String {
        let value = raw.trimmingCharacters(in: .whitespaces)
        if Int(value) != nil || value == "true" || value == "false" { return value }
        if value.hasPrefix("["), value.hasSuffix("]") {
            let inner = value.dropFirst().dropLast().trimmingCharacters(in: .whitespaces)
            guard !inner.isEmpty else { return "[]" }
            let items = inner.split(separator: ",").map {
                quoted(unquote($0.trimmingCharacters(in: .whitespaces)))
            }
            return "[" + items.joined(separator: ", ") + "]"
        }
        return quoted(unquote(value))
    }

    private static func unquote(_ value: String) -> String {
        guard value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") else { return value }
        return String(value.dropFirst().dropLast())
    }

    private static func quoted(_ value: String) -> String {
        let escaped = value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    private static func set(table: String, key: String, literal: String?, in lines: inout [String]) {
        guard let header = lines.firstIndex(where: { tableName(of: $0) == table }) else {
            guard let literal else { return }
            if let last = lines.last, !last.trimmingCharacters(in: .whitespaces).isEmpty { lines.append("") }
            lines += ["[\(table)]", "\(key) = \(literal)"]
            return
        }
        let end = lines[(header + 1)...].firstIndex { tableName(of: $0) != nil } ?? lines.count

        var index = header + 1
        while index < end {
            guard keyName(of: lines[index]) == key else {
                index += 1
                continue
            }
            let last = lastLine(ofValueAt: index, in: lines, before: end)
            if let literal {
                let comment = trailingComment(of: lines[last])
                let indent = String(lines[index].prefix { $0 == " " || $0 == "\t" })
                lines.replaceSubrange(index...last, with: ["\(indent)\(key) = \(literal)\(comment)"])
            } else {
                lines.removeSubrange(index...last)
            }
            return
        }

        guard let literal else { return }
        // After the table's last non-blank line, so a new key joins its table
        // rather than floating above the next header.
        var insertAt = end
        while insertAt > header + 1, lines[insertAt - 1].trimmingCharacters(in: .whitespaces).isEmpty {
            insertAt -= 1
        }
        lines.insert("\(key) = \(literal)", at: insertAt)
    }

    /// The table a `[name]` header line opens, or `nil` for any other line.
    static func tableName(of line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("["), !trimmed.hasPrefix("[["),
            let close = trimmed.firstIndex(of: "]")
        else { return nil }
        return trimmed[trimmed.index(after: trimmed.startIndex)..<close]
            .trimmingCharacters(in: .whitespaces)
    }

    private static func keyName(of line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.hasPrefix("#"), let equals = trimmed.firstIndex(of: "=") else { return nil }
        return trimmed[..<equals].trimmingCharacters(in: .whitespaces)
    }

    /// Where a value that may span lines ends — a multi-line array runs until
    /// its brackets balance.
    private static func lastLine(ofValueAt start: Int, in lines: [String], before end: Int) -> Int {
        var depth = 0
        for index in start..<end {
            depth += bracketDepth(of: code(of: lines[index]))
            if depth <= 0 { return index }
        }
        return start
    }

    private static func bracketDepth(of code: String) -> Int {
        var depth = 0
        forEachCodeCharacter(in: code) { _, character in
            if character == "[" { depth += 1 }
            if character == "]" { depth -= 1 }
            return true
        }
        return depth
    }

    /// A line without its comment, ignoring `#` inside strings.
    private static func code(of line: String) -> String {
        var cut: Int?
        forEachCodeCharacter(in: line) { offset, character in
            guard character == "#" else { return true }
            cut = offset
            return false
        }
        return cut.map { String(line.prefix($0)) } ?? line
    }

    /// Visits the characters of `line` outside TOML strings.
    ///
    /// Stops when `body` returns false. Escapes are honoured in basic strings:
    /// a value written as `"a\" ["` must not read as an open bracket.
    private static func forEachCodeCharacter(in line: String, _ body: (Int, Character) -> Bool) {
        var quote: Character?
        var escaped = false
        for (offset, character) in line.enumerated() {
            if let open = quote {
                if escaped {
                    escaped = false
                } else if open == "\"" && character == "\\" {
                    escaped = true
                } else if character == open {
                    quote = nil
                }
                continue
            }
            if character == "\"" || character == "'" {
                quote = character
                continue
            }
            guard body(offset, character) else { return }
        }
    }

    private static func trailingComment(of line: String) -> String {
        let body = code(of: line)
        guard body.count < line.count else { return "" }
        let codeTrailingSpaces = body.reversed().prefix { $0 == " " || $0 == "\t" }.count
        return String(body.suffix(codeTrailingSpaces)) + String(line.dropFirst(body.count))
    }
}
