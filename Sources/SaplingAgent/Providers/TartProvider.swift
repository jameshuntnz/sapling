import Foundation
import SaplingCore

/// macOS jobs, one ephemeral Tart VM each.
///
/// The loop follows Tartelet's proven shape: clone a base image, boot it
/// headless, SSH in, run an ephemeral runner, then delete the clone. The VM
/// *is* the isolation boundary, so teardown is unconditional — nothing is
/// preserved between jobs by design (§7).
public struct TartProvider: JobProvider, Sendable {
    let platform: JobPlatform = .macos

    let config: MacOSConfig
    let sshKeyPath: String
    /// Prefix every *ephemeral job* VM gets.
    ///
    /// Deliberately narrower than "sapling-": the base image is conventionally
    /// called `sapling-macos-base`, and a prefix that also matched it meant
    /// orphan reaping deleted the base image on every daemon start. Reaping
    /// additionally refuses to touch the configured base image by name, so a
    /// non-default name can't reintroduce the same failure.
    static let vmPrefix = "sapling-job-"

    init(config: MacOSConfig, sshKeyPath: String = SaplingPaths.sshKeyFile.path) {
        self.config = config
        self.sshKeyPath = sshKeyPath
    }

    func preflight() async throws {
        guard ProcessRunner.which("tart") != nil else {
            throw ProviderError(
                "`tart` is not installed. Run `sapling install`, or `brew install cirruslabs/cli/tart`.")
        }
        guard FileManager.default.fileExists(atPath: sshKeyPath) else {
            throw ProviderError("no VM SSH key at \(sshKeyPath). Run `sapling install` to generate one.")
        }
        guard try await imageExists(config.baseImage) else {
            throw ProviderError(
                """
                base image `\(config.baseImage)` not found. Either pull one \
                (`tart clone ghcr.io/cirruslabs/macos-sequoia-xcode:latest \(config.baseImage)`) \
                or build it per docs/BASE-IMAGE.md.
                """)
        }
    }

    private func imageExists(_ name: String) async throws -> Bool {
        let command = try await Self.tart(["get", name])
        let result = try await ProcessRunner.run(command.executable, command.arguments)
        return result.succeeded
    }

    func boot(
        vmName: String, request: JobRunRequest, events: any EventSink
    ) async throws -> JobOutcome {
        await events.record(RunEventName.vmCloned, detail: "cloning \(config.baseImage) -> \(vmName)")
        let cloneCommand = try await Self.tart(["clone", config.baseImage, vmName])
        try await ProcessRunner.runChecked(
            cloneCommand.executable, cloneCommand.arguments, timeout: .seconds(600))

        var setArgs = ["set", vmName]
        if let cpu = config.cpuCount { setArgs += ["--cpu", String(cpu)] }
        if let memory = request.memoryGB ?? config.memoryGB {
            setArgs += ["--memory", String(memory * 1024)]
        }
        if setArgs.count > 2 {
            let setCommand = try await Self.tart(setArgs)
            try await ProcessRunner.runChecked(setCommand.executable, setCommand.arguments)
        }

        // Announced before the VM starts, not after it is reachable: the
        // sampler tolerates an environment whose process does not exist yet,
        // and a VM that takes two minutes to boot is two minutes of a job
        // where the panel would otherwise have nothing to show.
        await events.environmentStarted(name: vmName, platform: .macos)

        // `tart run` blocks for the VM's lifetime, so it stays a background
        // task and gets cancelled during teardown. Everything it says goes to
        // `process`, because nothing awaits this task — see `VMBootProcess`
        // for the five minutes that cost.
        let process = VMBootProcess()
        let bootTask = Task.detached {
            do {
                let command = try await Self.tart(["run", "--no-graphics", vmName])
                for try await chunk in ProcessRunner.stream(command.executable, command.arguments) {
                    switch chunk {
                    // stdout as well as stderr: tart reports at least some
                    // startup failures on stdout, and reading only stderr is
                    // how the reason was lost.
                    case .stdout(let text), .stderr(let text):
                        guard !text.isEmpty else { continue }
                        await events.log("tart: \(text)")
                        await process.note(text)
                    case .exit(let code):
                        await process.end("`tart run` exited with status \(code)")
                    }
                }
                await process.end("`tart run` ended without starting the VM")
            } catch {
                await process.end("`tart run` could not be started: \(error.localizedDescription)")
            }
        }
        defer { bootTask.cancel() }

        // Captured here, inside the scope, and deliberately not in `run`'s
        // catch block where it started out. `defer` cancels the boot task on
        // the way out of this function, which kills `tart run` — so a capture
        // taken after the throw recorded a state teardown had already created,
        // and reported "no tart process" for a VM whose process had been alive
        // until we killed it. A diagnostic that describes its own side effects
        // is worse than none.
        let ip: String
        do {
            ip = try await waitForIP(vmName: vmName, timeout: Self.attachTimeout, process: process)
        } catch let failure as VMAttachFailed {
            await NetworkDiagnostics.captureAttachFailure(vmName: vmName, events: events)
            throw failure
        }
        await events.record(RunEventName.vmBooted, detail: ip)

        // Asked of the host, before anything is asked of the guest: it costs
        // one `ifconfig` and it is the difference between failing now with the
        // cause and spending the whole boot timeout on an SSH that was never
        // going to connect, then blaming the base image for it.
        try await verifyBridge(ip: ip, events: events)

        try await waitForSSH(ip: ip, timeout: request.bootTimeout)
        await events.record(RunEventName.sshConnected, detail: "\(config.sshUsername)@\(ip)")

        // Before the runner, not after: a VM that cannot reach GitHub produces
        // a runner that retries for minutes and then reports "lost
        // communication with the server", and in the worst case a VM that hangs
        // hard enough to hold a slot until the job timeout. One request here
        // turns all of that into an immediate failure that names the cause.
        try await verifyEgress(ip: ip, events: events)

        try await ensureRunnerPresent(ip: ip, events: events)
        await events.record(RunEventName.runnerRegistered, detail: request.runnerName)

        return try await runJob(ip: ip, request: request, events: events)
    }

    // MARK: - Runner

    private func ensureRunnerPresent(ip: String, events: any EventSink) async throws {
        let check = try await ProcessRunner.run(
            "ssh",
            sshArguments(ip: ip) + ["test -x ~/actions-runner/run.sh && echo present || echo missing"],
            timeout: .seconds(30)
        )
        if check.trimmedOutput == "present" { return }

        // Downloading ~200MB per job is slow enough to be worth calling out;
        // the fix is to bake the runner into the base image.
        await events.log(
            "actions-runner not found in base image — downloading it into the VM (bake it in to avoid this: docs/BASE-IMAGE.md)"
        )
        let script = """
            set -euo pipefail
            mkdir -p ~/actions-runner && cd ~/actions-runner
            VERSION=$(curl -fsSL https://api.github.com/repos/actions/runner/releases/latest | sed -n 's/.*"tag_name": *"v\\([^"]*\\)".*/\\1/p' | head -1)
            curl -fsSL -o runner.tar.gz "https://github.com/actions/runner/releases/download/v${VERSION}/actions-runner-osx-arm64-${VERSION}.tar.gz"
            tar xzf runner.tar.gz && rm runner.tar.gz
            """
        let install = try await ProcessRunner.run(
            "ssh",
            sshArguments(ip: ip) + ["bash -s"],
            standardInput: script,
            timeout: .seconds(900)
        )
        guard install.succeeded else {
            throw ProviderError("could not install the actions runner in the VM: \(install.stderr)")
        }
    }

    private func runJob(ip: String, request: JobRunRequest, events: any EventSink) async throws -> JobOutcome
    {
        var exports = request.environment
            .map { "export \($0.key)=\(shellQuote($0.value))" }
            .joined(separator: "\n")
        if !exports.isEmpty { exports += "\n" }

        let command = """
            set -o pipefail
            cd ~/actions-runner
            \(CacheEndpoint.exportScript(cache: request.cache, platform: .macos))
            \(exports)./run.sh --jitconfig \(shellQuote(request.jitConfig))
            """

        await events.record(RunEventName.runnerStarted, detail: request.runnerName)

        let exitCode = try await withThrowingTaskGroup(of: Int32?.self) { group in
            group.addTask {
                var status: Int32 = -1
                for try await chunk in ProcessRunner.stream("ssh", sshArguments(ip: ip) + [command]) {
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
            // Races the job for its whole duration. The environments that
            // failed here passed their egress check and lost the network
            // later, which a check that only runs at the start cannot see.
            group.addTask {
                throw JobNetworkLost(reason: try await JobNetwork.awaitLoss(of: ip))
            }

            guard let first = try await group.next() else {
                return Int32(-1)
            }
            group.cancelAll()
            guard let code = first else {
                throw ProviderError("job exceeded its timeout of \(request.jobTimeout) and was terminated")
            }
            return code
        }

        return JobOutcome(
            exitCode: exitCode,
            message: exitCode == 0 ? nil : "runner exited with status \(exitCode)"
        )
    }
}

/// Single-quote a value for safe interpolation into a remote shell command.
func shellQuote(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

extension TartProvider {
    /// Run `tart` inside the console user's session.
    ///
    /// Every invocation goes through here, not just `run`: a clone made by
    /// root is root-owned, and the user's later `tart run` then fails with
    /// `utimes(2): Operation not permitted` before Virtualization is even
    /// reached.
    public static func tart(_ arguments: [String]) async throws -> (executable: String, arguments: [String]) {
        var environment: [String: String] = [:]
        // Carry an explicitly configured image library across the sudo
        // boundary; otherwise `-H` lets tart find ~/.tart on its own.
        if let tartHome = ProcessInfo.processInfo.environment["TART_HOME"] {
            environment["TART_HOME"] = tartHome
        }
        return try await SessionCommand.invocation("tart", arguments, environment: environment)
    }
}
