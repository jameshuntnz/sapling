import Foundation
import SaplingCore

/// What the node's release channel has to offer, as far as the app knows.
///
/// A closed set rather than four loose optionals: the states are mutually
/// exclusive, and "available, but also the last apply was refused" is not a
/// thing the banner should ever have to render.
enum UpdateState {
    /// Not asked yet, or the node is already current.
    case none
    /// A newer version exists on the node's channel.
    case available(version: String, channel: ReleaseChannel, publishedAt: Date?)
    /// The daemon was asked to install it and declined, with a reason.
    case refused(String)
    /// Installing. The daemon restarts, so the connection is about to drop.
    case installing(version: String)
    /// The check itself failed — usually the node cannot reach GitHub.
    case checkFailed(String)
}

/// Surfacing the node's own update machinery.
///
/// The daemon already checks its channel on a timer and can auto-apply; none
/// of that lives here. This only asks what it found and offers to trigger what
/// it can already do, so a node stops needing an SSH session to update.
extension AppModel {
    /// Check the channel, but no more often than the ration allows.
    ///
    /// Every check is a GitHub round trip made by the node. At the panel's
    /// three-second poll that would be twelve hundred calls an hour to answer a
    /// question whose answer changes daily.
    func checkForUpdateIfDue() async {
        guard isMenuOpen else { return }
        if let updateCheckedAt,
            Date().timeIntervalSince(updateCheckedAt) < Self.updateCheckInterval
        {
            return
        }
        await checkForUpdate()
    }

    /// Ask the node what its channel has.
    func checkForUpdate() async {
        // An install in flight is not a moment to ask; the daemon answering is
        // the old one, and its answer is about to be wrong.
        if case .installing = updateState { return }
        do {
            let response = try await client.checkForUpdate()
            updateCheckedAt = Date()
            if let error = response.error {
                updateState = .checkFailed(error)
            } else if let available = response.available {
                updateState = .available(
                    version: available, channel: response.channel, publishedAt: response.publishedAt)
            } else {
                updateState = .none
            }
        } catch let error as ClientError {
            updateState = .checkFailed(error.message)
        } catch {
            updateState = .checkFailed(error.localizedDescription)
        }
    }

    /// Tell the node to install what it found.
    ///
    /// The daemon replies and *then* restarts, so the connection drops a moment
    /// later. That is success. `restartingUntil` is what stops the panel
    /// reporting it as a fault — see `isRestarting`.
    ///
    /// - Parameter force: Install even while jobs are running, which orphans
    ///   their VMs. Only ever passed after the daemon has refused once and said
    ///   so.
    func applyUpdate(force: Bool = false) async {
        do {
            let response = try await client.applyUpdate(force: force)
            if response.applying {
                updateState = .installing(version: response.version ?? "a new version")
                restartingUntil = Date().addingTimeInterval(Self.restartGrace)
            } else {
                updateState = .refused(response.message)
            }
        } catch let error as ClientError {
            updateState = .refused(error.message)
        } catch {
            updateState = .refused(error.localizedDescription)
        }
        await refresh()
    }

    /// Whether a dropped connection right now is the restart we asked for.
    ///
    /// Bounded on purpose. An update that genuinely broke the daemon must stop
    /// being excused and start looking like what it is, rather than leaving the
    /// panel permanently insisting everything is fine.
    var isRestarting: Bool {
        guard let restartingUntil else { return false }
        return restartingUntil > Date()
    }

    /// How long to keep excusing a dropped connection after asking for an
    /// install.
    ///
    /// Generous: the daemon verifies a download, unpacks it, and waits on
    /// `launchctl kickstart`.
    static var restartGrace: TimeInterval { 120 }
}
