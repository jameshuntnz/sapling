import Foundation
import SaplingCore
import SwiftUI

/// What the UI knows about the daemon right now.
///
/// The app is a thin client (§4): it holds no orchestration logic and never
/// derives state locally — everything here came from `/api/v1/*`, so what you
/// see on a laptop over Tailscale is exactly what the node believes.
@MainActor
@Observable
final class AppModel {
    enum Connection: Equatable {
        case connecting
        case connected
        case failed(String)
    }

    var connection: Connection = .connecting
    var status: StatusResponse?
    var jobs: [Job] = []
    var selectedJobID: String?
    var selectedJobDetail: JobDetailResponse?
    var lastUpdated: Date?

    /// Where the daemon lives.
    ///
    /// Persisted so the app reconnects on launch without asking again.
    var serverAddress: String {
        didSet {
            UserDefaults.standard.set(serverAddress, forKey: Self.serverKey)
            restart()
        }
    }

    /// Menu open means someone is watching; closed means stay cheap.
    ///
    /// Polling a Mac mini over Tailscale every second all day is not worth it.
    var isMenuOpen = false {
        didSet { restart() }
    }

    static let serverKey = "sapling.server"
    private var pollTask: Task<Void, Never>?

    init() {
        serverAddress =
            UserDefaults.standard.string(forKey: Self.serverKey)
            ?? ServerEndpoint.resolve().absoluteString
    }

    private var client: SaplingClient {
        SaplingClient(baseURL: ServerEndpoint.resolve(explicit: serverAddress), timeout: 8)
    }

    func start() {
        restart()
    }

    private func restart() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refresh()
                let interval: Duration = self.isMenuOpen ? .seconds(3) : .seconds(30)
                try? await Task.sleep(for: interval)
            }
        }
    }

    func refresh() async {
        let client = self.client
        do {
            async let statusTask = client.status()
            async let jobsTask = client.jobs(limit: 30)
            let (status, jobs) = try await (statusTask, jobsTask)

            self.status = status
            self.jobs = jobs
            self.connection = .connected
            self.lastUpdated = Date()

            if let selectedJobID {
                self.selectedJobDetail = try? await client.job(id: selectedJobID)
            }
        } catch let error as ClientError {
            self.connection = .failed(error.message)
        } catch {
            self.connection = .failed(error.localizedDescription)
        }
    }

    func select(jobID: String?) {
        selectedJobID = jobID
        selectedJobDetail = nil
        guard let jobID else { return }
        Task { selectedJobDetail = try? await client.job(id: jobID) }
    }

    // MARK: - Control

    func cordon() async {
        _ = try? await client.cordon()
        await refresh()
    }

    func uncordon() async {
        _ = try? await client.uncordon()
        await refresh()
    }

    func drain() async {
        _ = try? await client.drain()
        await refresh()
    }

    // MARK: - Derived

    var runningJobs: [Job] {
        jobs.filter { $0.status.occupiesSlot }
    }

    var recentJobs: [Job] {
        jobs.filter { $0.status.isTerminal }
    }

    var queuedJobs: [Job] {
        jobs.filter { $0.status == .queued }
    }

    /// What the menu bar icon should say at a glance.
    var iconSymbol: String {
        switch connection {
        case .failed: "exclamationmark.triangle.fill"
        case .connecting: "leaf"
        case .connected:
            if let status, status.node.status != .online {
                "pause.circle.fill"
            } else if !runningJobs.isEmpty {
                "leaf.fill"
            } else {
                "leaf"
            }
        }
    }

    var iconTint: Color? {
        switch connection {
        case .failed: .orange
        case .connecting: nil
        case .connected:
            if let status, status.node.status != .online {
                .yellow
            } else if !runningJobs.isEmpty {
                .green
            } else {
                nil
            }
        }
    }

    /// Slot usage next to the icon, so the common question ("is anything
    /// running?") is answered without opening anything.
    var menuBarLabel: String? {
        guard case .connected = connection, let status else { return nil }
        let inUse = status.slots.reduce(0) { $0 + $1.inUse }
        return inUse > 0 ? "\(inUse)" : nil
    }
}
