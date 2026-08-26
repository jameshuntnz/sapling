import Foundation
import SaplingCore

/// Linux jobs, one ephemeral Apple `container` each.
///
/// Apple's `container` runs each container in its own lightweight VM with
/// sub-second boot and near-zero idle memory — the reason §3 picks it over
/// Docker/Colima on a 16GB box. Like the macOS path, the container is the
/// isolation boundary and is discarded after every job; cross-job caching
/// goes through the host cache proxy instead (§7).
struct ContainerProvider: JobProvider, Sendable {
    let platform: JobPlatform = .linux

    let config: LinuxConfig
    static let containerPrefix = "sapling-"

    init(config: LinuxConfig) {
        self.config = config
    }

    func preflight() async throws {
        // The container system is a background service that does not come up
        // on its own after a reboot; starting it is idempotent.
        let statusCommand = try await ContainerCommand.invocation(["system", "status"])
        let status = try await ProcessRunner.run(
            statusCommand.executable, statusCommand.arguments, timeout: .seconds(30))
        guard !status.succeeded else { return }

        let startCommand = try await ContainerCommand.invocation(["system", "start"])
        let start = try await ProcessRunner.run(
            startCommand.executable, startCommand.arguments, timeout: .seconds(120))
        guard start.succeeded else {
            throw ProviderError("`container system start` failed: \(start.stderr)")
        }
    }

    func run(_ request: JobRunRequest, events: any EventSink) async throws -> JobOutcome {
        let name = Self.containerPrefix + request.runnerName
        let image = request.image ?? config.defaultImage

        defer {
            Task.detached {
                await events.record(RunEventName.cleanupStarted, detail: name)
                await Self.forceTeardown(name: name)
                await events.record(RunEventName.cleanupFinished, detail: name)
            }
        }

        await events.log("pulling \(image)")
        let pull = try await ProcessRunner.run(
            "container", ["images", "pull", image], timeout: .seconds(1800))
        if !pull.succeeded {
            // A pull failure is not fatal on its own — the image may already
            // be present locally from a previous job.
            await events.log(
                "image pull reported: \(pull.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
        }

        var args = ["run", "--rm", "--name", name]
        if let cpu = config.cpuCount { args += ["--cpus", String(cpu)] }
        if let memory = config.memoryGB { args += ["--memory", "\(memory)g"] }
        for (key, value) in request.environment.sorted(by: { $0.key < $1.key }) {
            args += ["--env", "\(key)=\(value)"]
        }
        args += ["--entrypoint", "/bin/bash", image, "-c", runnerScript(for: request)]
        let runCommand = try await ContainerCommand.invocation(args)

        await events.record(RunEventName.containerStarted, detail: "\(name) (\(image))")

        let exitCode = try await withThrowingTaskGroup(of: Int32?.self) { group in
            group.addTask {
                var status: Int32 = -1
                for try await chunk in ProcessRunner.stream(
                    runCommand.executable, runCommand.arguments
                ) {
                    switch chunk {
                    case .stdout(let text), .stderr(let text):
                        await events.log(text)
                    case .exit(let code):
                        status = code
                    }
                }
                return status
            }
            group.addTask {
                try await Task.sleep(for: request.jobTimeout)
                return nil
            }

            guard let first = try await group.next() else { return Int32(-1) }
            group.cancelAll()
            guard let code = first else {
                throw ProviderError("job exceeded its timeout of \(request.jobTimeout) and was terminated")
            }
            return code
        }

        return JobOutcome(
            exitCode: exitCode,
            message: exitCode == 0 ? nil : "container exited with status \(exitCode)"
        )
    }

    /// The actions-runner image ships `run.sh` in the runner's home.
    ///
    /// Falling back to a download keeps a plain `ubuntu:latest` usable as an
    /// image, at the cost of fetching the runner on every job.
    func runnerScript(for request: JobRunRequest) -> String {
        """
        set -euo pipefail
        if [ -x /home/runner/run.sh ]; then
          cd /home/runner
        elif [ -x ./run.sh ]; then
          :
        else
          echo "actions-runner not present in image; downloading"
          mkdir -p /tmp/actions-runner && cd /tmp/actions-runner
          VERSION=$(curl -fsSL https://api.github.com/repos/actions/runner/releases/latest \
            | sed -n 's/.*"tag_name": *"v\\([^"]*\\)".*/\\1/p' | head -1)
          curl -fsSL -o runner.tar.gz \
            "https://github.com/actions/runner/releases/download/v${VERSION}/actions-runner-linux-arm64-${VERSION}.tar.gz"
          tar xzf runner.tar.gz && rm runner.tar.gz
        fi
        exec ./run.sh --jitconfig \(shellQuote(request.jitConfig))
        """
    }

    static func forceTeardown(name: String) async {
        for arguments in [["stop", name], ["delete", "--force", name]] {
            guard let command = try? await ContainerCommand.invocation(arguments) else { return }
            _ = try? await ProcessRunner.run(
                command.executable, command.arguments, timeout: .seconds(60))
        }
    }

    func reapOrphans() async -> [String] {
        guard let command = try? await ContainerCommand.invocation(["list", "--all", "--format", "json"]),
            let result = try? await ProcessRunner.run(command.executable, command.arguments),
            result.succeeded,
            let data = result.stdout.data(using: .utf8),
            let entries = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else {
            return []
        }
        var reaped: [String] = []
        for entry in entries {
            let name =
                (entry["name"] as? String)
                ?? (entry["id"] as? String)
                ?? ((entry["configuration"] as? [String: Any])?["id"] as? String)
            guard let name, name.hasPrefix(Self.containerPrefix) else { continue }
            await Self.forceTeardown(name: name)
            reaped.append(name)
        }
        return reaped
    }
}
