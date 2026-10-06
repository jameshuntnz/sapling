import Foundation
import Testing

@testable import SaplingCore

/// Editing `config.toml` by line, so its comments survive.
@Suite("Config file editor")
struct ConfigFileEditorTests {
    static let file = """
        # Tuned for a 16GB mini.
        [node]
        name = "mini"

        [macos]
        memory_gb = 5  # 6+6 swaps; measured 2026-09
        labels = [
          "self-hosted",
          "macos",
        ]

        [linux]
        max_concurrent = 2
        """

    @Test("replaces a value and keeps its comment and every other line")
    func replacesScalar() throws {
        let edited = try ConfigFileEditor.apply(["macos.memory_gb": "6"], to: Self.file)
        #expect(edited.contains("memory_gb = 6  # 6+6 swaps; measured 2026-09"))
        #expect(edited.contains("# Tuned for a 16GB mini."))
        #expect(edited.components(separatedBy: "\n").count == Self.file.components(separatedBy: "\n").count)
    }

    @Test("replaces a multi-line array as one value")
    func replacesMultilineArray() throws {
        let edited = try ConfigFileEditor.apply(
            ["macos.labels": "[self-hosted, macos, arm64]"], to: Self.file)
        #expect(edited.contains(#"labels = ["self-hosted", "macos", "arm64"]"#))
        #expect(!edited.contains("  \"macos\",\n"))
        #expect(edited.contains("[linux]\nmax_concurrent = 2"))
    }

    @Test("adds a missing key to the end of its table, not after the next header")
    func insertsIntoTable() throws {
        let edited = try ConfigFileEditor.apply(["linux.memory_gb": "4"], to: Self.file)
        #expect(edited.hasSuffix("max_concurrent = 2\nmemory_gb = 4"))
        let node = try ConfigFileEditor.apply(["node.memory_reserve_gb": "3"], to: Self.file)
        #expect(node.contains("name = \"mini\"\nmemory_reserve_gb = 3\n\n[macos]"))
    }

    @Test("creates a missing table")
    func createsTable() throws {
        let edited = try ConfigFileEditor.apply(["update.channel": "dev"], to: Self.file)
        #expect(edited.hasSuffix("\n\n[update]\nchannel = \"dev\""))
    }

    @Test("an empty value removes the key so its default applies")
    func removesKey() throws {
        let edited = try ConfigFileEditor.apply(["macos.memory_gb": ""], to: Self.file)
        #expect(!edited.contains("memory_gb"))
        #expect(edited.contains("[macos]\nlabels = ["))
    }

    @Test("infers literals from displayed values")
    func literals() {
        #expect(ConfigFileEditor.literal(for: "6") == "6")
        #expect(ConfigFileEditor.literal(for: "true") == "true")
        #expect(ConfigFileEditor.literal(for: "stable") == "\"stable\"")
        #expect(ConfigFileEditor.literal(for: "\"stable\"") == "\"stable\"")
        #expect(ConfigFileEditor.literal(for: "[]") == "[]")
        #expect(ConfigFileEditor.literal(for: "[a/b, \"c/d\"]") == #"["a/b", "c/d"]"#)
    }

    @Test("refuses a key that is not table.key")
    func refusesDeepKeys() {
        #expect(throws: ConfigFileEditor.EditError.self) {
            try ConfigFileEditor.apply(["github.app.id": "1"], to: Self.file)
        }
    }
}
