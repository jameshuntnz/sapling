import Foundation
import SaplingCore

/// Whether a job environment's network exists, as the host sees it.
public enum NetworkReachability: Sendable, Equatable {
    /// A host bridge owns the environment's subnet, at this gateway address.
    case live(gateway: String)
    /// The environment holds an address on a network the host has no
    /// interface for. Its packets fail at ARP, instantly.
    case orphaned(address: String)
    /// The host could not be asked, with the reason.
    case unknown(String)
}

/// The network a running job environment sits on.
///
/// Sapling used to check egress exactly once, from inside the guest, just
/// before starting the runner. That check was necessary and not sufficient:
/// the environments that failed on `mac-mini-01` *passed* it and then lost
/// their network partway through the job — one container compiled a Kotlin
/// module and stopped producing step conclusions from the next step onward.
///
/// A one-shot probe cannot see that, and the runner's own report of it is
/// "the self-hosted runner lost communication with the server" ten minutes
/// later, which names nothing. So reachability is treated as a property the
/// environment must hold for the whole job, checked from the host — where it
/// costs one `ifconfig` and needs no access to the guest at all.
public enum JobNetwork {
    /// How often a running environment's network is re-checked.
    ///
    /// The check is a single `ifconfig`, so this is cheap enough to be
    /// frequent; the cost of being slow is a job that keeps burning a slot
    /// after its network has gone.
    public static let watchInterval: Duration = .seconds(15)

    /// Consecutive failed checks before a network is declared dead.
    ///
    /// More than one because a bridge is genuinely absent for a moment while
    /// vmnet recreates it, and killing a job for that would be its own flake.
    public static let lossConfirmations = 2

    /// Whether the host still owns the gateway for this environment.
    /// - Parameters:
    ///   - address: The guest's address, with or without a `/prefix` suffix.
    ///   - bridges: The host's bridges, from `BridgeTable.current()`.
    /// - Returns: What the bridge table says about that address.
    public static func reachability(of address: String, in bridges: [HostBridge])
        -> NetworkReachability
    {
        guard let bridge = BridgeTable.owner(of: address, in: bridges) else {
            return .orphaned(address: address)
        }
        return .live(gateway: bridge.address)
    }

    /// Whether the host still owns the gateway for this environment, read now.
    public static func reachability(of address: String) async -> NetworkReachability {
        guard let bridges = try? await BridgeTable.current() else {
            return .unknown("could not read the host's interfaces")
        }
        return reachability(of: address, in: bridges)
    }

    /// Wait until this environment's network is gone, then say so.
    ///
    /// Never returns while the network holds, so it is meant to race the job
    /// itself in a task group: whichever finishes first decides the outcome.
    /// - Parameters:
    ///   - address: The guest's address, or `nil` if it could not be
    ///     determined — in which case this waits forever rather than
    ///     returning, so a watchdog that cannot see the network can never be
    ///     the thing that fails a job.
    ///   - interval: Gap between checks.
    ///   - confirmations: Consecutive misses required before declaring loss.
    /// - Returns: An explanation naming the address and the missing gateway.
    /// - Throws: `CancellationError` when the job it is watching finishes
    ///   first and the surrounding task group is cancelled.
    public static func awaitLoss(
        of address: String?,
        interval: Duration = watchInterval,
        confirmations: Int = lossConfirmations
    ) async throws -> String {
        guard let address else {
            while true { try await Task.sleep(for: interval) }
        }
        var misses = 0
        while true {
            try await Task.sleep(for: interval)
            switch await reachability(of: address) {
            case .live:
                misses = 0
            case .unknown:
                // Not evidence of anything: an `ifconfig` that didn't run says
                // nothing about the bridge. Leave the count alone.
                break
            case .orphaned:
                misses += 1
                if misses >= confirmations { return lossReason(address: address) }
            }
        }
    }

    /// Why a job is being failed, phrased so the cause is in the message.
    ///
    /// The message a job carries is the only thing anyone reads at 2am, and
    /// the one this replaces described a symptom on GitHub's side.
    static func lossReason(address: String) -> String {
        """
        this environment's network went away mid-job: it holds \(address), and no host \
        interface owns that subnet any more, so every packet it sends fails at ARP. \
        The environment's own tooling still reports it as running with an address — \
        only the host's bridge table shows the truth. Failing now rather than letting \
        the runner retry into a void and report "lost communication with the server".
        """
    }
}

/// A job failed because its environment's network disappeared while it ran.
///
/// Its own type rather than a `ProviderError`, so the Linux path can tell this
/// apart from an ordinary failure and repair the container network before the
/// next job walks into the same dead bridge.
public struct JobNetworkLost: Error, LocalizedError, Sendable {
    /// What happened, phrased for a job's exit reason.
    public let reason: String

    /// Creates the error.
    public init(reason: String) {
        self.reason = reason
    }

    /// The reason, for `LocalizedError`.
    public var errorDescription: String? { reason }
}
