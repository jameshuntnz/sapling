import Foundation
import TOMLKit

/// One field whose value differs between two configurations.
///
/// Values are rendered for a person to read, not parsed back: a change is
/// something an operator confirms, and `[a, b]` says more than the TOML that
/// produced it.
public struct ConfigChange: Codable, Sendable, Hashable {
    /// Dotted TOML path, for example `github.poll_interval_seconds`.
    public var key: String
    /// What the daemon is running with.
    public var from: String
    /// What the file on disk says.
    public var to: String

    /// Creates a change.
    public init(key: String, from: String, to: String) {
        self.key = key
        self.from = from
        self.to = to
    }
}

/// One field of the effective configuration, as shown by `sapling config show`.
public struct ConfigEntry: Codable, Sendable, Hashable {
    /// Dotted TOML path, for example `macos.max_concurrent`.
    public var key: String
    /// The running value, redacted if the field holds a credential.
    public var value: String
    /// Whether a reload picks this field up without restarting the daemon.
    public var reloadable: Bool

    /// Creates an entry.
    public init(key: String, value: String, reloadable: Bool) {
        self.key = key
        self.value = value
        self.reloadable = reloadable
    }
}

/// What a running daemon can and cannot pick up from an edited config file.
///
/// The split is not cosmetic. `NodeAgent` re-reads most of its configuration
/// every time it uses it, so those fields genuinely change under a live
/// daemon; the rest were consumed once — the listener is already bound, the
/// providers already hold their platform settings, the pf anchor is already
/// written — and quietly swapping the value would leave the config file
/// describing something the machine is not doing.
///
/// So a reload applies the first set and *reports* the second rather than
/// pretending. The alternative considered was writing the file and restarting
/// the daemon, which is simpler and fails every job that happens to be running
/// at the time.
public enum ConfigReload {
    /// Fields the daemon reads afresh on every use.
    ///
    /// Each entry has to be read at the point of use, not captured at startup.
    /// `merge(running:incoming:)` is the other half of this list, and
    /// `ConfigReloadTests` holds the two together.
    public static let reloadableKeys: Set<String> = [
        "github.repos",
        "github.poll_interval_seconds",
        "github.cancel_run_when_exhausted",
        "node.max_concurrent",
        "node.memory_reserve_gb",
        "node.memory_budget_gb",
        "node.serialize_platforms",
        "macos.max_concurrent",
        "macos.labels",
        "macos.memory_gb",
        "macos.max_memory_gb",
        "macos.job_timeout_seconds",
        "linux.max_concurrent",
        "linux.labels",
        "linux.memory_gb",
        "linux.max_memory_gb",
        "linux.job_timeout_seconds",
        "linux.default_image",
        "update.repository",
        "update.channel",
        "update.check_interval_hours",
        "update.auto_apply",
    ]

    /// Fields that are never rendered, whatever they contain.
    ///
    /// The API has no auth — §8 makes tailnet membership the access control —
    /// so a credential must not be reachable through it even to a caller who
    /// is already inside. Set-ness is reported instead, which is the part
    /// worth knowing when a config is being compared against a running node.
    public static let secretKeys: Set<String> = ["github.token", "macos.ssh_password"]

    /// The order sections are shown in: identity, then how work arrives, then
    /// what runs it.
    static let sectionOrder = ["node", "server", "github", "macos", "linux", "network", "cache", "update"]

    /// Shown for a field the config file leaves out.
    static let unset = "(unset)"

    // MARK: - Reading a configuration as flat keys

    /// Flattens a configuration into dotted TOML keys.
    ///
    /// Derived from the encoded TOML rather than a hand-written field list, so
    /// a section added to `SaplingConfig` shows up here — and in every diff —
    /// without anyone remembering to add it.
    ///
    /// - Parameter config: The configuration to read.
    /// - Returns: Every field the config would write, keyed by dotted path.
    /// - Throws: If the configuration cannot be encoded to TOML.
    public static func flatten(_ config: SaplingConfig) throws -> [String: String] {
        var out: [String: String] = [:]
        flatten(try TOMLTable(config), prefix: "", into: &out)
        return out
    }

    private static func flatten(_ table: TOMLTable, prefix: String, into out: inout [String: String]) {
        for (key, value) in table {
            let path = prefix.isEmpty ? key : "\(prefix).\(key)"
            if let child = value.table {
                flatten(child, prefix: path, into: &out)
            } else {
                out[path] = describe(value)
            }
        }
    }

    private static func describe(_ value: any TOMLValueConvertible) -> String {
        if let array = value.array {
            return "[" + array.map(describe).joined(separator: ", ") + "]"
        }
        if let bool = value.bool { return String(bool) }
        if let int = value.int { return String(int) }
        if let double = value.double { return String(double) }
        if let string = value.string { return string }
        return value.debugDescription
    }

    /// Whether a field holds a credential and must never be rendered.
    ///
    /// The named set plus a suffix rule, so a credential added later is
    /// redacted by default rather than by remembering to list it.
    ///
    /// - Parameter key: A dotted TOML path.
    /// - Returns: `true` if the value must be hidden.
    public static func isSecret(_ key: String) -> Bool {
        if secretKeys.contains(key) { return true }
        let leaf = key.split(separator: ".").last.map(String.init) ?? key
        return ["token", "password", "secret"].contains { leaf.contains($0) }
    }

    /// How a value is shown, hiding credentials.
    static func display(key: String, value: String?) -> String {
        guard let value, !value.isEmpty else { return unset }
        return isSecret(key) ? "(set)" : value
    }

    // MARK: - Comparing and merging

    /// Everything the effective configuration currently holds, in reading order.
    ///
    /// - Parameter config: The configuration the daemon is running with.
    /// - Returns: One entry per field, credentials redacted.
    /// - Throws: If the configuration cannot be encoded to TOML.
    public static func entries(of config: SaplingConfig) throws -> [ConfigEntry] {
        try flatten(config)
            .map {
                ConfigEntry(
                    key: $0.key,
                    value: display(key: $0.key, value: $0.value),
                    reloadable: reloadableKeys.contains($0.key))
            }
            .sorted(by: precedes)
    }

    /// Which fields differ, split by whether a reload can apply them.
    ///
    /// A field present in one configuration and absent from the other counts
    /// as a change: dropping `macos.memory_gb` is an edit, not a non-event.
    ///
    /// - Parameters:
    ///   - running: What the daemon is using now.
    ///   - incoming: What the file on disk says.
    /// - Returns: Changes a reload applies, and changes that need a restart.
    /// - Throws: If either configuration cannot be encoded to TOML.
    public static func diff(running: SaplingConfig, incoming: SaplingConfig) throws -> (
        live: [ConfigChange], restartRequired: [ConfigChange]
    ) {
        let before = try flatten(running)
        let after = try flatten(incoming)
        var changes: [ConfigChange] = []
        for key in Set(before.keys).union(after.keys) {
            let old = before[key]
            let new = after[key]
            guard old != new else { continue }
            // A credential that changed still says so — "(set)" on both sides
            // would read as no change at all.
            let to =
                isSecret(key) && old != nil && new != nil ? "(set, changed)" : display(key: key, value: new)
            changes.append(ConfigChange(key: key, from: display(key: key, value: old), to: to))
        }
        changes.sort { precedes($0.key, $1.key) }
        return (
            changes.filter { reloadableKeys.contains($0.key) },
            changes.filter { !reloadableKeys.contains($0.key) }
        )
    }

    /// The configuration a daemon should hold after a reload.
    ///
    /// Only the reloadable fields cross over. Everything else keeps the value
    /// the daemon started with, so what is in memory always matches what is
    /// actually in force — an unapplied edit is reported, never half-applied.
    ///
    /// - Parameters:
    ///   - running: What the daemon is using now.
    ///   - incoming: What the file on disk says.
    /// - Returns: `running` with the reloadable fields taken from `incoming`.
    public static func merge(running: SaplingConfig, incoming: SaplingConfig) -> SaplingConfig {
        var merged = running

        merged.github.repos = incoming.github.repos
        merged.github.pollIntervalSeconds = incoming.github.pollIntervalSeconds
        merged.github.cancelRunWhenExhausted = incoming.github.cancelRunWhenExhausted

        merged.node.maxConcurrent = incoming.node.maxConcurrent
        merged.node.memoryReserveGB = incoming.node.memoryReserveGB
        merged.node.memoryBudgetOverrideGB = incoming.node.memoryBudgetOverrideGB
        merged.node.serializePlatforms = incoming.node.serializePlatforms

        merged.macos.maxConcurrent = incoming.macos.maxConcurrent
        merged.macos.labels = incoming.macos.labels
        merged.macos.memoryGB = incoming.macos.memoryGB
        merged.macos.maxMemoryGB = incoming.macos.maxMemoryGB
        merged.macos.jobTimeoutSeconds = incoming.macos.jobTimeoutSeconds

        merged.linux.maxConcurrent = incoming.linux.maxConcurrent
        merged.linux.labels = incoming.linux.labels
        merged.linux.memoryGB = incoming.linux.memoryGB
        merged.linux.maxMemoryGB = incoming.linux.maxMemoryGB
        merged.linux.jobTimeoutSeconds = incoming.linux.jobTimeoutSeconds
        merged.linux.defaultImage = incoming.linux.defaultImage

        merged.update = incoming.update

        return merged
    }

    /// Section order first, then alphabetical within a section.
    static func precedes(_ lhs: String, _ rhs: String) -> Bool {
        let leftSection = lhs.split(separator: ".").first.map(String.init) ?? lhs
        let rightSection = rhs.split(separator: ".").first.map(String.init) ?? rhs
        let leftRank = sectionOrder.firstIndex(of: leftSection) ?? sectionOrder.count
        let rightRank = sectionOrder.firstIndex(of: rightSection) ?? sectionOrder.count
        if leftRank != rightRank { return leftRank < rightRank }
        return lhs < rhs
    }

    private static func precedes(_ lhs: ConfigEntry, _ rhs: ConfigEntry) -> Bool {
        precedes(lhs.key, rhs.key)
    }
}
