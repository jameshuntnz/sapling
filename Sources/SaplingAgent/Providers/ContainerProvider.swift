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
    /// Sapling runs on Apple silicon only, so the host is always arm64.
    static let hostArch = "arm64"

    init(config: LinuxConfig) {
        self.config = config
    }

    func preflight() async throws {
        // Checked before anything else: `preflight` returns early once the
        // container system is up, so a check placed after that would be
        // skipped on every node where it already is.
        try Self.checkRosetta(config: config)

        // The container system is a background service that does not come up
        // on its own after a reboot; starting it is idempotent.
        let statusCommand = try await SessionCommand.invocation("container", ["system", "status"])
        let status = try await ProcessRunner.run(
            statusCommand.executable, statusCommand.arguments, timeout: .seconds(30))
        guard !status.succeeded else { return }

        let startCommand = try await SessionCommand.invocation("container", ["system", "start"])
        let start = try await ProcessRunner.run(
            startCommand.executable, startCommand.arguments, timeout: .seconds(120))
        guard start.succeeded else {
            throw ProviderError("`container system start` failed: \(start.stderr)")
        }
    }

    /// Refuses to start when Rosetta is asked for but absent from the host.
    ///
    /// Without this the misconfiguration surfaces inside a job, as
    /// `rosetta error: failed to open elf at /lib64/ld-linux-x86-64.so.2` —
    /// which names neither Rosetta's absence nor the setting that asked for
    /// it, and arrives only once a build has already started.
    static func checkRosetta(config: LinuxConfig) throws {
        guard config.rosetta else { return }
        guard !FileManager.default.fileExists(atPath: rosettaPath) else { return }
        throw ProviderError(
            """
            [linux] rosetta = true, but Rosetta is not installed on this host \
            (\(rosettaPath) is missing). Install it with: \
            sudo softwareupdate --install-rosetta --agree-to-license \
            — or set rosetta = false, which disables running x86-64 binaries \
            such as Android's aapt2.
            """)
    }

    /// Where Rosetta lands when installed; its presence is the check.
    static let rosettaPath = "/Library/Apple/usr/libexec/oah"

    /// How many times to build this container before giving the job up.
    ///
    /// The same count the macOS path gets, and for the same reason. A
    /// container that comes up without a network is not a job that has failed:
    /// observed in production, one failed twelve seconds in where a rebuild
    /// would very likely have worked, and it failed outright because only the
    /// VM path had a retry. That asymmetry cost a job.
    static let attachAttempts = 3

    func run(_ request: JobRunRequest, events: any EventSink) async throws -> JobOutcome {
        let image = request.image ?? config.defaultImage
        var lastFailure: (any Error)?

        for attempt in 1...Self.attachAttempts {
            // A fresh name per attempt, matching the macOS path: whatever a
            // failed environment leaves behind is exactly what is not
            // understood, so nothing is reused.
            let name =
                attempt == 1
                ? Self.containerPrefix + request.runnerName
                : "\(Self.containerPrefix)\(request.runnerName)-r\(attempt)"

            do {
                let outcome = try await start(
                    name: name, image: image, request: request, events: events)
                await Self.teardown(name: name, events: events)
                return outcome
            } catch let error as JobNetworkLost {
                lastFailure = error
                // Teardown first: the repair stops every container, and this
                // one is on its way out anyway. Without the repair the next
                // attempt starts into the same dead bridge and fails the same
                // way, which is how a single lost bridge became an evening of
                // failures.
                await Self.teardown(name: name, events: events)
                await Self.repairNetwork(after: name, events: events)
                if attempt < Self.attachAttempts {
                    await events.log(
                        "\(error.localizedDescription) — rebuilding the container "
                            + "(attempt \(attempt + 1) of \(Self.attachAttempts))")
                }
            } catch {
                await Self.teardown(name: name, events: events)
                throw error
            }
        }

        throw ProviderError(
            lastFailure?.localizedDescription ?? "the container never got a network")
    }

    private func start(
        name: String, image: String, request: JobRunRequest, events: any EventSink
    ) async throws -> JobOutcome {
        await events.log("pulling \(image)")
        // Three things this call has to get right, each of which failed
        // silently before because a pull failure is treated as non-fatal:
        //   `image`, not `images` — the latter resolves no plugin at all;
        //   through SessionCommand, since as root the apiserver is unreachable;
        //   and pinned to one architecture, or `container` fetches every
        //   platform in the manifest list (riscv64 and s390x included).
        let pullCommand = try await SessionCommand.invocation(
            "container",
            ["image", "pull", "--arch", config.arch ?? Self.hostArch, image])
        let pull = try await ProcessRunner.run(
            pullCommand.executable, pullCommand.arguments, timeout: .seconds(1800))
        if !pull.succeeded {
            // A pull failure is not fatal on its own — the image may already
            // be present locally from a previous job.
            await events.log(
                "image pull reported: \(pull.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
        }

        let args = runArguments(name: name, image: image, request: request)
        let runCommand = try await SessionCommand.invocation("container", args)

        await events.record(RunEventName.containerStarted, detail: "\(name) (\(image))")

        // The address the watchdog resolved, kept so a container that is killed
        // can still be asked why. Recreating the network SIGKILLs every
        // container on it, and the job then exits 137 — which describes the
        // signal and not the reason it was sent.
        let observed = ObservedAddress()

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
            // Races the job for its whole duration. The container that failed
            // here passed its egress check, compiled a module, and then went
            // quiet — its bridge had gone, which nothing was watching for.
            group.addTask {
                let address = await Self.address(ofContainer: name, within: Self.addressTimeout)
                await observed.set(address)
                throw JobNetworkLost(reason: try await JobNetwork.awaitLoss(of: address))
            }

            guard let first = try await group.next() else { return Int32(-1) }
            group.cancelAll()
            guard let code = first else {
                throw ProviderError("job exceeded its timeout of \(request.jobTimeout) and was terminated")
            }
            return code
        }

        // A container that died with its network already gone was killed by the
        // network going, whatever signal actually reached it. Recreating the
        // container network SIGKILLs everything on it, so the repair for one
        // job's lost bridge arrives before the watchdog has finished confirming
        // it for another — and the job then carries "container exited with
        // status 137", which names the signal and not the cause.
        if exitCode != 0, let address = await observed.value,
            case .orphaned = await JobNetwork.reachability(of: address)
        {
            throw JobNetworkLost(reason: JobNetwork.lossReason(address: address))
        }

        if EgressCheck.isEgressFailure(exitCode) {
            // Thrown as a network loss so it takes the retry path: this is the
            // same fault the watchdog catches, seen from inside the guest
            // instead of from the host. `run` does the repair.
            throw JobNetworkLost(reason: EgressCheck.failureReason)
        }

        return JobOutcome(
            exitCode: exitCode,
            message: exitCode == 0 ? nil : "container exited with status \(exitCode)"
        )
    }

    /// Arguments for `container run`, in the order the CLI expects them.
    ///
    /// `--rosetta` is what makes an Android build possible here: Google ships
    /// `aapt2` for `linux-x86_64` only, so on this arm64 node the Gradle plugin
    /// would otherwise die with `Exec format error`. With Rosetta exposed, that
    /// one binary is translated and the rest of the build — JVM, Kotlin, dex —
    /// still runs natively. See `LinuxConfig.rosetta` for what the image owes.
    func runArguments(name: String, image: String, request: JobRunRequest) -> [String] {
        var args = ["run", "--rm", "--name", name]
        if let cpu = config.cpuCount { args += ["--cpus", String(cpu)] }
        if let memory = config.memoryGB { args += ["--memory", "\(memory)g"] }
        if let arch = config.arch { args += ["--arch", arch] }
        if config.rosetta { args.append("--rosetta") }
        for (key, value) in request.environment.sorted(by: { $0.key < $1.key }) {
            args += ["--env", "\(key)=\(value)"]
        }
        args += ["--entrypoint", "/bin/bash", image, "-c", runnerScript(for: request)]
        return args
    }

    /// The actions-runner image ships `run.sh` in the runner's home.
    ///
    /// Falling back to a download keeps a plain `ubuntu:latest` usable as an
    /// image, at the cost of fetching the runner on every job.
    func runnerScript(for request: JobRunRequest) -> String {
        """
        set -euo pipefail
        \(EgressCheck.probeScript)
        \(CacheEndpoint.exportScript(cache: request.cache, platform: .linux))
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

    /// Delete the container, and don't come back until it is actually gone.
    ///
    /// Awaited, and detached, for the same two reasons as the macOS path: the
    /// caller frees the job's slot as soon as `run` returns, and a cancelled
    /// task cannot run `container stop` — `ProcessRunner` would terminate it
    /// immediately. See `TartProvider.teardown`.
    static func teardown(name: String, events: any EventSink) async {
        await Task.detached {
            await events.record(RunEventName.cleanupStarted, detail: name)
            await forceTeardown(name: name)
            await events.record(RunEventName.cleanupFinished, detail: name)
        }.value
    }

    static func forceTeardown(name: String) async {
        for arguments in [["stop", name], ["delete", "--force", name]] {
            guard let command = try? await SessionCommand.invocation("container", arguments) else { return }
            _ = try? await ProcessRunner.run(
                command.executable, command.arguments, timeout: .seconds(60))
        }
    }

    func reapOrphans() async -> [String] {
        var reaped: [String] = []
        for container in await ContainerListing.current(includeStopped: true)
        where container.id.hasPrefix(Self.containerPrefix) {
            await Self.forceTeardown(name: container.id)
            reaped.append(container.id)
        }
        return reaped
    }
}
