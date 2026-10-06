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
    /// The selected job's log, kept whole across polls and paging.
    let logPager = LogPager()
    /// Announces failures and outages while the panel is closed.
    let notifier = JobNotifier()
    /// What the last action actually did — a job cancelled, a node paused.
    ///
    /// Shown rather than swallowed: several of these have consequences you
    /// cannot see from the panel, and a button that reports nothing teaches you
    /// to check the terminal anyway.
    var lastActionMessage: String?
    /// What the node's release channel has to offer, as far as the app knows.
    var updateState: UpdateState = .none
    /// When the daemon last answered an update check.
    ///
    /// The check is a GitHub round trip made by the node, so it is rationed
    /// rather than made part of the three-second poll.
    var updateCheckedAt: Date?
    /// How long to keep treating a dropped connection as an expected restart.
    var restartingUntil: Date?
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
        didSet {
            if !isMenuOpen { lastActionMessage = nil }
            restart()
        }
    }

    static let serverKey = "sapling.server"
    /// How long an update check is treated as still current.
    static let updateCheckInterval: TimeInterval = 900
    private var pollTask: Task<Void, Never>?

    init() {
        serverAddress =
            UserDefaults.standard.string(forKey: Self.serverKey)
            ?? ServerEndpoint.resolve().absoluteString
    }

    var client: SaplingClient {
        SaplingClient(baseURL: ServerEndpoint.resolve(explicit: serverAddress), timeout: 8)
    }

    func start() {
        Task { await notifier.requestAuthorization() }
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
            notifier.observe(jobs: jobs)
            // Only while someone is looking: the history is for the chart, and
            // fetching it every 30s in the background is pure noise.
            if isMenuOpen {
                self.metricsHistory =
                    (try? await client.metricsHistory(limit: 60))?.samples ?? metricsHistory
            }
            self.connection = .connected
            self.lastUpdated = Date()
            // Reaching the daemon at all means any restart we were excusing is
            // over. If it was an install, confirm what is actually running now
            // rather than leaving the banner asserting it from before.
            self.restartingUntil = nil
            if case .installing = updateState {
                self.updateState = .none
                self.updateCheckedAt = nil
            }
            await checkForUpdateIfDue()

            if let selectedJobID {
                self.selectedJobDetail = try? await client.job(id: selectedJobID)
                if let detail = selectedJobDetail { await logPager.sync(with: detail, client: client) }
                self.selectedJobResources = try? await client.jobResources(
                    jobID: selectedJobID, limit: 60)
            }
        } catch let error as ClientError {
            self.connection = .failed(error.message)
            notifier.observeFailure(error.message, expected: isRestarting)
        } catch {
            self.connection = .failed(error.localizedDescription)
            notifier.observeFailure(error.localizedDescription, expected: isRestarting)
        }
    }

    func select(jobID: String?) {
        selectedJobID = jobID
        selectedJobDetail = nil
        selectedJobResources = nil
        lastActionMessage = nil
        logPager.reset(jobID: jobID)
        guard let jobID else { return }
        Task {
            selectedJobDetail = try? await client.job(id: jobID)
            if let detail = selectedJobDetail { await logPager.sync(with: detail, client: client) }
            selectedJobResources = try? await client.jobResources(jobID: jobID, limit: 60)
        }
    }

    // MARK: - Control

    /// Stop accepting new jobs, with the intention of resuming.
    func cordon() async {
        await perform { try await $0.cordon().message }
    }

    /// Accept jobs again, from either paused or draining.
    func uncordon() async {
        await perform { try await $0.uncordon().message }
    }

    /// Stop accepting new jobs and let the running ones finish.
    ///
    /// The reply names how many it is waiting on, which is the whole reason to
    /// choose this over pausing — so it is shown rather than discarded.
    func drain() async {
        await perform { try await $0.drain().message }
    }

    // MARK: - Job control

    /// Stop a job that is running or waiting here.
    func cancel(jobID: String) async {
        await perform { try await $0.cancelJob(id: jobID).message }
    }

    /// Queue a finished job to run again.
    func retry(jobID: String) async {
        await perform { try await $0.retryJob(id: jobID).message }
    }

    /// Run an action and keep whatever the daemon said about it.
    ///
    /// A failure is reported in the same place as a success. These used to be
    /// `try?`, which meant a pause that never landed looked identical to one
    /// that did.
    func perform(_ action: (SaplingClient) async throws -> String) async {
        do {
            lastActionMessage = try await action(client)
        } catch let error as ClientError {
            lastActionMessage = error.message
        } catch {
            lastActionMessage = error.localizedDescription
        }
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
}
