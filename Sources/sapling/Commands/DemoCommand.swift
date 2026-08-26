import ArgumentParser
import Foundation
import SaplingAPI
import SaplingCore
import SaplingDB

/// `sapling demo` — the control plane with a seeded database and no agent.
///
/// Exists so the menu bar app and the CLI can be exercised end to end before
/// there's a provisioned node to talk to. It never touches GitHub, Tart, or
/// `container`, and it uses a throwaway database so it can't disturb a real
/// installation.
struct Demo: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Run a control plane with sample data, for trying out the CLI and menu bar app."
    )

    @Option(help: "Port to listen on.")
    var port: Int = 8734

    @Flag(name: .customLong("public"), help: "Listen on all interfaces instead of loopback.")
    var isPublic = false

    func run() async throws {
        var config = SaplingConfig()
        config.node.name = "demo-node"
        config.github.repos = ["acme/widgets", "acme/gizmos"]
        config.server.bind = isPublic ? "all" : "loopback"
        config.server.port = port

        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("sapling-demo-\(UUID().uuidString).db")
        let store = try SaplingStore(path: databaseURL)
        defer { try? FileManager.default.removeItem(at: databaseURL) }

        try await seed(store: store, config: config)

        print(Style.bold("Sapling demo control plane"))
        print("  \(Style.dim("sample data only — no GitHub, no VMs, no containers"))")
        print("")
        print("  CLI:       sapling status --server http://127.0.0.1:\(port)")
        print("  Menu bar:  set the daemon address to 127.0.0.1:\(port)")
        print("")

        let server = ControlPlaneServer(config: config, store: store, agent: nil)
        try await server.run()
    }

    private func seed(store: SaplingStore, config: SaplingConfig) async throws {
        let nodeID = "demo-node"
        try await store.upsertNode(
            Node(
                id: nodeID,
                name: "mac-mini-01",
                platform: "darwin/arm64",
                lastSeenAt: Date(),
                status: .online
            ))
        try await store.setState(
            SaplingStore.StateKey.lastPollAt,
            ISO8601DateFormatter().string(from: Date().addingTimeInterval(-8))
        )

        let samples: [(String, JobPlatform, JobStatus, String, TimeInterval)] = [
            ("8801", .macos, .running, "build-and-test (macOS)", -420),
            ("8802", .linux, .running, "lint", -95),
            ("8803", .linux, .queued, "integration-tests", -20),
            ("8804", .macos, .completed, "build-and-test (macOS)", -3600),
            ("8805", .linux, .completed, "lint", -5400),
            ("8806", .linux, .failed, "integration-tests", -7200),
            ("8807", .macos, .completed, "release", -86_000),
        ]

        for (id, platform, status, name, offset) in samples {
            let queued = Date().addingTimeInterval(offset)
            let started = status == .queued ? nil : queued.addingTimeInterval(12)
            let completed = status.isTerminal ? queued.addingTimeInterval(Double.random(in: 90...600)) : nil

            try await store.saveJob(
                Job(
                    id: id,
                    nodeID: nodeID,
                    repo: platform == .macos ? "acme/widgets" : "acme/gizmos",
                    workflowRunID: "77\(id.suffix(2))",
                    platform: platform,
                    labels: ["self-hosted", platform.rawValue, "arm64"],
                    status: status,
                    name: name,
                    queuedAt: queued,
                    startedAt: started,
                    completedAt: completed,
                    exitReason: status == .failed ? "GitHub reported conclusion: failure" : nil
                ))

            guard status != .queued else { continue }
            var timeline: [(String, String?)] = [
                (RunEventName.jobClaimed, "mac-mini-01")
            ]
            if platform == .macos {
                timeline += [
                    (RunEventName.vmCloned, "cloning sapling-macos-base -> sapling-sap-macos-7f3a1c04"),
                    (RunEventName.vmBooted, "192.168.64.12"),
                    (RunEventName.sshConnected, "admin@192.168.64.12"),
                ]
            } else {
                timeline.append(
                    (
                        RunEventName.containerStarted,
                        "sapling-sap-linux-2b91ef00 (ghcr.io/actions/actions-runner:latest)"
                    ))
            }
            timeline += [
                (RunEventName.runnerRegistered, "sap-\(platform.rawValue)-7f3a1c04"),
                (RunEventName.runnerStarted, nil),
                (RunEventName.log, "√ Connected to GitHub"),
                (RunEventName.log, "Current runner version: '2.322.0'"),
                (RunEventName.log, "Running job: \(name)"),
            ]
            if status.isTerminal {
                timeline += [
                    (
                        RunEventName.log,
                        status == .failed
                            ? "##[error]Process completed with exit code 1."
                            : "Job \(name) completed with result: Succeeded"
                    ),
                    (
                        status == .failed ? RunEventName.jobFailed : RunEventName.jobCompleted,
                        status == .failed ? "GitHub reported conclusion: failure" : nil
                    ),
                    (
                        RunEventName.cleanupStarted,
                        platform == .macos ? "sapling-sap-macos-7f3a1c04" : "sapling-sap-linux-2b91ef00"
                    ),
                    (RunEventName.cleanupFinished, nil),
                ]
            }

            for (index, entry) in timeline.enumerated() {
                try await store.appendEvent(
                    RunEvent(
                        jobID: id,
                        ts: (started ?? queued).addingTimeInterval(Double(index) * 3),
                        event: entry.0,
                        detail: entry.1
                    ))
            }
        }
    }
}
