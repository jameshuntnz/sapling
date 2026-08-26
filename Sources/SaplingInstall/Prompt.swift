import Foundation

/// Terminal input helpers for the interactive parts of `sapling install`.
public enum Prompt {
    /// Asks for a line of input, returning the default when it's empty.
    public static func line(_ question: String, default defaultValue: String? = nil) -> String? {
        if let defaultValue {
            print("\(question) [\(defaultValue)]: ", terminator: "")
        } else {
            print("\(question): ", terminator: "")
        }
        guard let input = readLine(strippingNewline: true) else { return defaultValue }
        let trimmed = input.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? defaultValue : trimmed
    }

    /// Read without echoing.
    ///
    /// Used for the GitHub token so it never lands in scrollback or a screen recording.
    public static func secret(_ question: String) -> String? {
        print("\(question): ", terminator: "")
        var original = termios()
        let hasTerminal = tcgetattr(STDIN_FILENO, &original) == 0
        if hasTerminal {
            var quiet = original
            quiet.c_lflag &= ~UInt(ECHO)
            tcsetattr(STDIN_FILENO, TCSAFLUSH, &quiet)
        }
        defer {
            if hasTerminal {
                var restore = original
                tcsetattr(STDIN_FILENO, TCSAFLUSH, &restore)
                print("")
            }
        }
        guard let input = readLine(strippingNewline: true) else { return nil }
        let trimmed = input.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Asks a yes/no question.
    public static func confirm(_ question: String, default defaultValue: Bool = false) -> Bool {
        let hint = defaultValue ? "Y/n" : "y/N"
        print("\(question) [\(hint)]: ", terminator: "")
        guard let input = readLine(strippingNewline: true)?.trimmingCharacters(in: .whitespaces).lowercased(),
            !input.isEmpty
        else {
            return defaultValue
        }
        return input == "y" || input == "yes"
    }

    /// Asks the person to pick one of a numbered list of options.
    public static func choose(_ question: String, options: [String], default defaultIndex: Int = 0) -> String
    {
        print(question)
        for (index, option) in options.enumerated() {
            print("  \(index + 1)) \(option)")
        }
        print("Choice [\(defaultIndex + 1)]: ", terminator: "")
        guard let input = readLine(strippingNewline: true)?.trimmingCharacters(in: .whitespaces),
            let choice = Int(input), choice >= 1, choice <= options.count
        else {
            return options[defaultIndex]
        }
        return options[choice - 1]
    }
}
