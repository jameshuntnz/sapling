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
    /// What the selected job's own VM or container is using.
    ///
    /// Fetched separately from the job's detail because it comes from a
    /// different place — the agent sampling live processes rather than the
    /// store — and a node too busy to answer for one should still answer for
    /// the other.
    var selectedJobResources: JobResourcesResponse?
    var lastUpdated: Date?
    /// Recent hardware samples, for the trend behind each meter.
    var metricsHistory: [NodeMetrics] = []

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
            // Only while someone is looking: the history is for the chart, and
            // fetching it every 30s in the background is pure noise.
            if isMenuOpen {
                self.metricsHistory =
                    (try? await client.metricsHistory(limit: 60))?.samples ?? metricsHistory
            }
            self.connection = .connected
            self.lastUpdated = Date()

            if let selectedJobID {
                self.selectedJobDetail = try? await client.job(id: selectedJobID)
                self.selectedJobResources = try? await client.jobResources(
                    jobID: selectedJobID, limit: 60)
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
        selectedJobResources = nil
        guard let jobID else { return }
        Task {
            selectedJobDetail = try? await client.job(id: jobID)
            selectedJobResources = try? await client.jobResources(jobID: jobID, limit: 60)
        }
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

    /// Memory each running job reserved, largest first.
    ///
    /// Ordered by size rather than by start time: the bar is read to find what
    /// is holding the node, and the largest holder is the answer more often
    /// than the oldest one.
    var memoryHoldings: [(name: String, gb: Int)] {
        runningJobs
            .map { (name: $0.name ?? "job \($0.id)", gb: $0.memoryGB ?? 0) }
            .filter { $0.gb > 0 }
            .sorted { $0.gb > $1.gb }
    }

    /// Why each queued job has not started, keyed by job id.
    ///
    /// Derived here rather than asked of the daemon: everything it needs is
    /// already in the status payload, and a round trip for an explanation would
    /// be a round trip that can disagree with the numbers beside it.
    var queueReasons: [String: QueueReason] {
        guard let status else { return [:] }
        var capacity: [JobPlatform: Int] = [:]
        var inUse: [JobPlatform: Int] = [:]
        for slot in status.slots {
            capacity[slot.platform] = slot.capacity
            inUse[slot.platform] = slot.inUse
        }
        return QueueExplainer.explain(
            queued: queuedJobs,
            inUse: inUse,
            capacity: capacity,
            nodeCapacity: status.nodeCapacity,
            committedGB: status.committedMemoryGB,
            budgetGB: status.memoryBudgetGB,
            sizeOf: { $0.memoryGB ?? 0 })
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
