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
    ///   - poll: How often to re-read the host's bridges.
    public init(config: CacheConfig, poll: Duration = .seconds(20)) {
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
                // Waited for, not just cancelled. Vapor's shutdown is
                // asynchronous, so cancelling and moving on left the socket
                // open — and when the same bridge came back, which is the
                // normal case for a gateway address, the replacement listener
                // failed to bind with "Address already in use". That happened
                // three times in one afternoon.
                await settle(listener)
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

    /// Wait for a cancelled listener to actually let go of its port.
    ///
    /// Bounded, because a shutdown that hangs must not stall the supervisor
    /// for every other gateway. If it overruns, the next poll finds the
    /// gateway without a listener and tries again — which is the same
    /// recovery a failed bind gets.
    private func settle(_ listener: Task<Void, Never>) async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await listener.value }
            group.addTask { try? await Task.sleep(for: .seconds(10)) }
            await group.next()
            group.cancelAll()
        }
    }

    private func stopAll() {
        for listener in listeners.values { listener.cancel() }
        listeners.removeAll()
    }
}
