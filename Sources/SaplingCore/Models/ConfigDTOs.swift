import Foundation

/// Response body for `GET /api/v1/config`.
///
/// Never carries a credential: the API has no auth by design (§8), so the
/// effective configuration is served as an allowlisted, redacted view rather
/// than as the file itself. `github.token` and `macos.ssh_password` are
/// reported as set or unset and never as their value.
public struct ConfigResponse: Codable, Sendable {
    /// The config file the daemon loaded, and would reload from.
    public var path: String
    /// Every field of the effective configuration, redacted, in reading order.
    public var entries: [ConfigEntry]
    /// Advisories about the running configuration, as `sapling doctor` shows.
    public var warnings: [String]
    /// Edits sitting in the file that a reload would apply.
    public var pendingReload: [ConfigChange]
    /// Edits sitting in the file that need the daemon restarted.
    public var pendingRestart: [ConfigChange]
    /// Why the file on disk could not be compared, if it could not.
    ///
    /// The running configuration is still reported: a daemon running fine
    /// against a file someone has since broken is exactly the state worth
    /// being able to see.
    public var fileError: String?

    /// Creates a configuration view.
    public init(
        path: String,
        entries: [ConfigEntry],
        warnings: [String] = [],
        pendingReload: [ConfigChange] = [],
        pendingRestart: [ConfigChange] = [],
        fileError: String? = nil
    ) {
        self.path = path
        self.entries = entries
        self.warnings = warnings
        self.pendingReload = pendingReload
        self.pendingRestart = pendingRestart
        self.fileError = fileError
    }
}

/// Response body for `POST /api/v1/config/reload`.
///
/// A reload never partly applies: the file is parsed and validated in full
/// first, and a file that fails either leaves the daemon exactly as it was.
public struct ConfigReloadResponse: Codable, Sendable {
    /// Whether the running configuration changed.
    public var reloaded: Bool
    /// Fields the daemon is now using the new value for.
    public var applied: [ConfigChange]
    /// Fields that differ but need a restart to take effect.
    ///
    /// Reported rather than applied — see `ConfigReload` for why the daemon
    /// refuses to change a listener or a provider underneath itself.
    public var pendingRestart: [ConfigChange]
    /// Advisories about the configuration now in force.
    public var warnings: [String]
    /// What happened, phrased for a person.
    public var message: String
    /// Why nothing was applied, when the file could not be used.
    ///
    /// Reported in the body rather than thrown, like the update endpoints: a
    /// config with a typo in it is an answer, not a server fault.
    public var error: String?

    /// Creates a reload result.
    public init(
        reloaded: Bool,
        applied: [ConfigChange] = [],
        pendingRestart: [ConfigChange] = [],
        warnings: [String] = [],
        message: String,
        error: String? = nil
    ) {
        self.reloaded = reloaded
        self.applied = applied
        self.pendingRestart = pendingRestart
        self.warnings = warnings
        self.message = message
        self.error = error
    }
}
