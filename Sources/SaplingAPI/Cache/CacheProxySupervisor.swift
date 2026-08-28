import Foundation
import SaplingAgent
import SaplingCore

/// Keeps a cache proxy listening on every bridge gateway, for as long as each
/// bridge exists.
///
/// Three faults, all of them the same mistake — treating "the bridge" as one
/// thing that exists once:
///
/// - It bound `interfaces.first.address`. There are routinely two bridges, one
///   for containers and one for VMs, so one platform got a cache and the other
///   got a `GOPROXY` pointing at an address it could not route to.
/// - It waited half an hour for a bridge and then gave up permanently. A node
///   idle at boot — the normal state — never started a cache at all.
/// - It never noticed a bridge going away, which happens every time the last
///   environment on it exits.
/// - It polled too slowly to be useful. A macOS VM boots in about eight
///   seconds and asks for the cache straight away; on a twenty-second poll
///   there was never a listener in time, so every macOS job fetched directly.
///
/// So: watch the bridge table, run one listener per gateway, and start and
/// stop them as bridges come and go. Bound to the gateways rather than
/// `0.0.0.0` deliberately — the egress filter permits jobs exactly one private
/// address each, and binding wider would put this cache on the LAN and the
/// tailnet too.
public actor CacheProxySupervisor {
    private let config: CacheConfig
    private let poll: Duration
    private var listeners: [String: Task<Void, Never>] = [:]

    /// Creates a supervisor.
    /// - Parameters:
    ///   - config: Cache settings, including the port to listen on.
    ///   - poll: How often to re-read the host's bridges. Short, because a
    ///     macOS VM boots in about eight seconds and probes for the cache
    ///     immediately: at twenty seconds no listener existed yet and every
    ///     macOS job fell back to fetching directly, which made the mirror
    ///     useless for exactly the jobs that needed it. Reading the bridge
    ///     table is one `ifconfig`.
    public init(config: CacheConfig, poll: Duration = .seconds(3)) {
        self.config = config
        self.poll = poll
    }

    /// Track the host's bridges until cancelled.
    public func run() async {
        defer { stopAll() }
        var announced = false
        while !Task.isCancelled {
            let gateways = Set(((try? await BridgeTable.current()) ?? []).map(\.address))
            if gateways.isEmpty, !announced {
                Log.info("cache proxy idle — no VM bridge yet; it binds one as soon as a job starts")
                announced = true
            }
            if !gateways.isEmpty { announced = false }

            for gone in listeners.keys where !gateways.contains(gone) {
                guard let listener = listeners.removeValue(forKey: gone) else { continue }
                listener.cancel()
                // Vapor's shutdown is asynchronous, so the socket outlives the
                // cancellation briefly and a same-address rebind — the normal
                // case for a gateway — can fail with "Address already in use".
                await settle()
                Log.info("cache proxy stopped listening on \(gone) — its bridge went away")
            }
            for gateway in gateways where listeners[gateway] == nil {
                listeners[gateway] = listen(on: gateway)
            }

            try? await Task.sleep(for: poll)
        }
    }

    /// Serve on one gateway until that listener is cancelled.
    ///
    /// A listener that fails is simply dropped: the next poll sees the gateway
    /// has no listener and starts a new one, which is the same recovery a
    /// disappearing bridge gets.
    private func listen(on gateway: String) -> Task<Void, Never> {
        let config = self.config
        return Task.detached {
            do {
                try await CacheProxyServer(config: config).run(bindAddress: gateway)
            } catch is CancellationError {
                return
            } catch {
                Log.warn("cache proxy on \(gateway) stopped: \(error.localizedDescription)")
            }
        }
    }

    /// Give a cancelled listener a moment to let go of its port.
    ///
    /// Deliberately **not** an await on the listener's completion. That was
    /// tried and it hung the supervisor permanently: `Task<Void, Never>.value`
    /// is not cancellable, so `cancelAll()` cannot stop a child waiting on it
    /// and the task group blocks forever at scope exit if the server does not
    /// observe cancellation. Measured — the cache proxy stopped binding
    /// anything at 08:25:27 and never recovered, so the mirror was dead for
    /// every job after it.
    ///
    /// A fixed pause is enough for the common case, and the uncommon one is
    /// self-healing anyway: a bind that loses the race fails, the listener
    /// exits, and the next poll finds the gateway unserved and tries again.
    /// Recovering a second later beats not recovering at all.
    private func settle() async {
        try? await Task.sleep(for: .seconds(2))
    }

    private func stopAll() {
        for listener in listeners.values { listener.cancel() }
        listeners.removeAll()
    }
}
