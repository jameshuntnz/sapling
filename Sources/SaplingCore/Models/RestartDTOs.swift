import Foundation

/// Response body for `POST /api/v1/restart`.
///
/// The daemon is already root, so it can ask launchd to restart it and the
/// operator needs no `sudo` — the same reasoning as the update endpoints.
///
/// A successful restart takes the process down, so the reply is sent first and
/// the connection then drops. A dropped connection after this response is the
/// restart happening, not a failure.
public struct RestartResponse: Codable, Sendable {
    /// Whether the daemon is going down to come back.
    public var restarting: Bool
    /// Jobs that were running when the request arrived.
    ///
    /// Non-zero and `restarting` means they were taken down deliberately.
    public var runningJobs: Int
    /// What happened, phrased for a person.
    public var message: String
    /// Why nothing is restarting, when nothing is.
    public var error: String?

    /// Creates a restart result.
    public init(restarting: Bool, runningJobs: Int = 0, message: String, error: String? = nil) {
        self.restarting = restarting
        self.runningJobs = runningJobs
        self.message = message
        self.error = error
    }
}
