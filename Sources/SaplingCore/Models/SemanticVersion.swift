import Foundation

/// Which stream of releases a build belongs to.
///
/// Derived from the version's prerelease identifier rather than tracked
/// separately, so a version string is always self-describing: `0.5.0` is
/// stable, `0.5.0-rc.1` is a candidate, `0.5.0-dev.12` is a development build.
public enum ReleaseChannel: String, Codable, Sendable, CaseIterable, Comparable {
    /// Development builds, cut from every push to the main branch.
    case dev
    /// Release candidates, promoted from dev once a version looks ready.
    case rc
    /// Finished releases.
    case stable

    /// Whether a node on this channel should accept `other`.
    ///
    /// A node tracking `dev` also wants rc and stable builds — they are further
    /// along, not different. A node tracking `stable` wants only stable.
    public func accepts(_ other: ReleaseChannel) -> Bool {
        other >= self
    }

    /// Orders channels by how finished they are: dev, then rc, then stable.
    public static func < (lhs: ReleaseChannel, rhs: ReleaseChannel) -> Bool {
        let order: [ReleaseChannel] = [.dev, .rc, .stable]
        guard let left = order.firstIndex(of: lhs), let right = order.firstIndex(of: rhs) else {
            return false
        }
        return left < right
    }
}

/// A semantic version, with the precedence rules from semver.org §11.
///
/// Sapling compares versions to decide whether a release is worth installing,
/// and getting prerelease precedence wrong means a node either refuses a real
/// upgrade or downgrades itself onto a development build.
public struct SemanticVersion: Sendable, Hashable, Comparable, CustomStringConvertible {
    /// One dot-separated piece of a prerelease tag.
    ///
    /// Numeric and alphanumeric identifiers sort by different rules, so which
    /// kind it is has to be preserved rather than compared as text — otherwise
    /// `dev.9` sorts after `dev.10`.
    public enum PrereleaseIdentifier: Sendable, Hashable, Comparable, CustomStringConvertible {
        case numeric(Int)
        case alphanumeric(String)

        /// The identifier as it appears in a version string.
        public var description: String {
            switch self {
            case .numeric(let value): String(value)
            case .alphanumeric(let value): value
            }
        }

        /// Numeric identifiers compare numerically and rank below
        /// alphanumeric ones, per semver §11.
        public static func < (lhs: Self, rhs: Self) -> Bool {
            switch (lhs, rhs) {
            case (.numeric(let left), .numeric(let right)):
                left < right
            case (.alphanumeric(let left), .alphanumeric(let right)):
                left < right
            // Numeric identifiers always have lower precedence than
            // alphanumeric ones.
            case (.numeric, .alphanumeric):
                true
            case (.alphanumeric, .numeric):
                false
            }
        }
    }

    /// Incompatible API changes.
    public let major: Int
    /// Backwards-compatible additions.
    public let minor: Int
    /// Backwards-compatible fixes.
    public let patch: Int
    /// Empty for a stable release.
    public let prerelease: [PrereleaseIdentifier]
    /// Build metadata.
    ///
    /// Carried for display and ignored when comparing, as the spec requires.
    public let build: String?

    /// Creates a version from its parts.
    public init(
        major: Int,
        minor: Int,
        patch: Int,
        prerelease: [PrereleaseIdentifier] = [],
        build: String? = nil
    ) {
        self.major = major
        self.minor = minor
        self.patch = patch
        self.prerelease = prerelease
        self.build = build
    }

    /// Parses a version string, with or without a leading `v`.
    ///
    /// Returns `nil` rather than guessing: a version that cannot be parsed
    /// must not compare as anything, or an unreadable tag could be taken for
    /// an upgrade.
    public init?(_ string: String) {
        var text = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("v") { text.removeFirst() }
        guard !text.isEmpty else { return nil }

        var buildMetadata: String?
        if let plus = text.firstIndex(of: "+") {
            buildMetadata = String(text[text.index(after: plus)...])
            text = String(text[..<plus])
            if buildMetadata?.isEmpty == true { return nil }
        }

        var prereleaseIdentifiers: [PrereleaseIdentifier] = []
        if let hyphen = text.firstIndex(of: "-") {
            let tag = String(text[text.index(after: hyphen)...])
            text = String(text[..<hyphen])
            guard !tag.isEmpty else { return nil }
            for piece in tag.split(separator: ".", omittingEmptySubsequences: false) {
                guard !piece.isEmpty else { return nil }
                if piece.allSatisfy(\.isNumber), let value = Int(piece) {
                    prereleaseIdentifiers.append(.numeric(value))
                } else {
                    guard piece.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" }) else {
                        return nil
                    }
                    prereleaseIdentifiers.append(.alphanumeric(String(piece)))
                }
            }
        }

        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        guard let major = Int(parts[0]), let minor = Int(parts[1]), let patch = Int(parts[2]),
            major >= 0, minor >= 0, patch >= 0
        else { return nil }

        self.init(
            major: major, minor: minor, patch: patch,
            prerelease: prereleaseIdentifiers, build: buildMetadata)
    }

    /// Which release stream this version belongs to.
    public var channel: ReleaseChannel {
        guard let first = prerelease.first else { return .stable }
        switch first.description {
        case "rc": return .rc
        default: return .dev
        }
    }

    /// Whether this is a finished release.
    public var isStable: Bool { prerelease.isEmpty }

    /// The canonical version string, without a leading `v`.
    public var description: String {
        var text = "\(major).\(minor).\(patch)"
        if !prerelease.isEmpty {
            text += "-" + prerelease.map(\.description).joined(separator: ".")
        }
        if let build { text += "+\(build)" }
        return text
    }

    /// The version without build metadata, for display where space is short.
    ///
    /// Build metadata takes no part in precedence (§10), so dropping it never
    /// merges two versions that are actually different — and `0.2.0-dev.19`
    /// fits in a menu bar panel where `0.2.0-dev.19+595aac7` does not.
    public var withoutBuildMetadata: String {
        var text = "\(major).\(minor).\(patch)"
        if !prerelease.isEmpty {
            text += "-" + prerelease.map(\.description).joined(separator: ".")
        }
        return text
    }

    /// Compares by semver §11 precedence.
    ///
    /// Build metadata takes no part, as the spec requires.
    public static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        if lhs.patch != rhs.patch { return lhs.patch < rhs.patch }

        // A version with a prerelease tag precedes the release it precedes.
        switch (lhs.prerelease.isEmpty, rhs.prerelease.isEmpty) {
        case (true, true): return false
        case (true, false): return false
        case (false, true): return true
        case (false, false): break
        }

        for (left, right) in zip(lhs.prerelease, rhs.prerelease) where left != right {
            return left < right
        }
        // All shared identifiers equal: the shorter set has lower precedence.
        return lhs.prerelease.count < rhs.prerelease.count
    }

    /// Equality by precedence, so two builds of the same version compare
    /// equal however their build metadata differs.
    public static func == (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        lhs.major == rhs.major && lhs.minor == rhs.minor && lhs.patch == rhs.patch
            && lhs.prerelease == rhs.prerelease
    }

    /// Hashes the fields that take part in equality.
    public func hash(into hasher: inout Hasher) {
        hasher.combine(major)
        hasher.combine(minor)
        hasher.combine(patch)
        hasher.combine(prerelease)
    }
}
