import Foundation
import SaplingCore
import UserNotifications

/// Posts a macOS notification when something needs a person.
///
/// The panel only helps when it is open, and the menu bar icon is too small to
/// say *which* thing went wrong. These are the events that otherwise go
/// unnoticed until somebody wonders why a build never came back.
///
/// Fed from the background poll, so it works with the panel closed. Nothing is
/// announced on the first poll: a failure from yesterday is history, not news.
@MainActor
final class JobNotifier {
    /// UserDefaults key: notify when a job fails.
    static let failuresKey = "sapling.notify.failures"
    /// UserDefaults key: notify when the node cannot be reached.
    static let unreachableKey = "sapling.notify.unreachable"

    /// Consecutive failed polls before the node counts as unreachable.
    ///
    /// One dropped poll over Tailscale is weather, not an outage.
    static let unreachableAfterPolls = 2

    private var seenTerminal: Set<String> = []
    private var hasBaseline = false
    private var failedPolls = 0
    private var announcedOutage = false
    private var authorized = false

    /// Notifications only exist for a bundled app; `swift run` has no bundle
    /// identifier and `UNUserNotificationCenter` traps without one.
    private var available: Bool { Bundle.main.bundleIdentifier != nil }

    private func enabled(_ key: String) -> Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? true
    }

    /// Ask for permission once, the first time anything is enabled.
    func requestAuthorization() async {
        guard available, !authorized else { return }
        authorized =
            (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]))
            ?? false
    }

    /// Note what one successful poll returned, announcing anything new.
    ///
    /// - Parameter jobs: The jobs the daemon reported, most recent first.
    func observe(jobs: [Job]) {
        failedPolls = 0
        if announcedOutage {
            announcedOutage = false
            post(title: "Sapling node reachable again", body: "The menu bar is talking to the daemon.")
        }

        let terminal = jobs.filter(\.status.isTerminal)
        defer { seenTerminal.formUnion(terminal.map(\.id)) }
        guard hasBaseline else {
            hasBaseline = true
            return
        }
        guard enabled(Self.failuresKey) else { return }
        for job in terminal where job.status == .failed && !seenTerminal.contains(job.id) {
            post(title: Self.title(for: job), body: Format.oneLine(job.exitReason ?? job.repo))
        }
    }

    /// Note a poll that could not reach the daemon.
    ///
    /// - Parameters:
    ///   - message: Why it failed.
    ///   - expected: The daemon was asked to restart, so silence is planned.
    func observeFailure(_ message: String, expected: Bool) {
        guard !expected else {
            failedPolls = 0
            return
        }
        failedPolls += 1
        guard failedPolls >= Self.unreachableAfterPolls, !announcedOutage,
            enabled(Self.unreachableKey)
        else { return }
        announcedOutage = true
        post(title: "Sapling node unreachable", body: Format.oneLine(message))
    }

    /// What a failure is called, by what actually happened.
    ///
    /// The three that need different responses get different titles: giving
    /// up means GitHub is still waiting on a runner, and an egress refusal
    /// means no job will run at all until the filter is fixed.
    static func title(for job: Job) -> String {
        let name = job.name ?? "job \(job.id)"
        let reason = job.exitReason?.lowercased() ?? ""
        if reason.contains("egress filter") { return "Egress filter failed — \(name) refused" }
        if reason.hasPrefix("gave up after") { return "Gave up on \(name)" }
        if let label = FailureKind.of(reason: job.exitReason).label { return "\(name): \(label)" }
        return "\(name) failed"
    }

    private func post(title: String, body: String) {
        guard available else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
