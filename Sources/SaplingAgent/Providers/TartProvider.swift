import Foundation
import SaplingCore

/// macOS jobs, one ephemeral Tart VM each.
///
/// The loop follows Tartelet's proven shape: clone a base image, boot it
/// headless, SSH in, run an ephemeral runner, then delete the clone. The VM
/// *is* the isolation boundary, so teardown is unconditional — nothing is
/// preserved between jobs by design (§7).
struct TartProvider: JobProvider, Sendable {
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
        let result = try await ProcessRunner.run("tart", ["get", name])
        return result.succeeded
    }

    func run(_ request: JobRunRequest, events: any EventSink) async throws -> JobOutcome {
        let vmName = Self.vmPrefix + request.runnerName

        // Teardown has to happen no matter how we leave this function — a
        // leaked VM holds one of only two macOS slots until someone notices.
        defer {
            Task.detached {
                await events.record(RunEventName.cleanupStarted, detail: vmName)
                await Self.forceTeardown(vmName: vmName)
                await events.record(RunEventName.cleanupFinished, detail: vmName)
            }
        }

        await events.record(RunEventName.vmCloned, detail: "cloning \(config.baseImage) -> \(vmName)")
        try await ProcessRunner.runChecked(
            "tart", ["clone", config.baseImage, vmName], timeout: .seconds(600))

        var setArgs = ["set", vmName]
        if let cpu = config.cpuCount { setArgs += ["--cpu", String(cpu)] }
        if let memory = config.memoryGB { setArgs += ["--memory", String(memory * 1024)] }
        if setArgs.count > 2 {
            try await ProcessRunner.runChecked("tart", setArgs)
        }

        // `tart run` blocks for the VM's lifetime, so it stays a background
        // task and gets cancelled during teardown.
        let bootTask = Task.detached {
            for try await chunk in ProcessRunner.stream("tart", ["run", "--no-graphics", vmName]) {
                if case .stderr(let text) = chunk, !text.isEmpty {
                    await events.log("tart: \(text)")
                }
            }
        }
        defer { bootTask.cancel() }

        let ip = try await waitForIP(vmName: vmName, timeout: request.bootTimeout)
        await events.record(RunEventName.vmBooted, detail: ip)

        try await waitForSSH(ip: ip, timeout: request.bootTimeout)
        await events.record(RunEventName.sshConnected, detail: "\(config.sshUsername)@\(ip)")

        try await ensureRunnerPresent(ip: ip, events: events)
        await events.record(RunEventName.runnerRegistered, detail: request.runnerName)

        return try await runJob(ip: ip, request: request, events: events)
    }

    // MARK: - Boot

    private func waitForIP(vmName: String, timeout: Duration) async throws -> String {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            let result = try await ProcessRunner.run("tart", ["ip", vmName])
            let ip = result.trimmedOutput
            if result.succeeded, !ip.isEmpty {
                return ip
            }
            try await Task.sleep(for: .seconds(2))
        }
        throw ProviderError("VM \(vmName) never reported an IP address within \(timeout)")
    }

    private func waitForSSH(ip: String, timeout: Duration) async throws {
        let deadline = ContinuousClock.now + timeout
        var lastError = "connection never succeeded"
        while ContinuousClock.now < deadline {
            let result = try await ProcessRunner.run(
                "ssh", sshArguments(ip: ip) + ["true"], timeout: .seconds(15))
            if result.succeeded { return }
            lastError = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            try await Task.sleep(for: .seconds(3))
        }
        throw ProviderError(
            """
            could not SSH into the VM at \(ip) as \(config.sshUsername): \(lastError).
            Check that the base image has \(sshKeyPath).pub in ~/.ssh/authorized_keys \
            and Remote Login enabled (see docs/BASE-IMAGE.md).
            """)
    }

    func sshArguments(ip: String) -> [String] {
        [
            "-i", sshKeyPath,
            "-o", "StrictHostKeyChecking=no",
            // Every VM is a fresh clone reusing the subnet's IP range, so
            // known_hosts would collide on every single job.
            "-o", "UserKnownHostsFile=/dev/null",
            "-o", "LogLevel=ERROR",
            "-o", "ConnectTimeout=10",
            "-o", "BatchMode=yes",
            "\(config.sshUsername)@\(ip)",
        ]
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

    // MARK: - Teardown

    /// Stop-then-delete, ignoring failures at each step: a VM that never
    /// booted can't be stopped, and one that was never cloned can't be
    /// deleted, but neither should stop us reclaiming the slot.
    static func forceTeardown(vmName: String) async {
        _ = try? await ProcessRunner.run("tart", ["stop", "--timeout", "30", vmName], timeout: .seconds(60))
        _ = try? await ProcessRunner.run("tart", ["delete", vmName], timeout: .seconds(60))
    }

    func reapOrphans() async -> [String] {
        guard let result = try? await ProcessRunner.run("tart", ["list", "--format", "json"]),
            result.succeeded,
            let data = result.stdout.data(using: .utf8),
            let entries = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else {
            return []
        }
        var reaped: [String] = []
        for name in Self.reapableVMNames(from: entries, protecting: config.baseImage) {
            await Self.forceTeardown(vmName: name)
            reaped.append(name)
        }
        return reaped
    }

    /// Which listed VMs are leaked job clones safe to delete.
    ///
    /// Split out from the `tart` call so the filtering can be tested: getting
    /// this wrong destroyed an 80GB base image that takes an hour to rebuild.
    static func reapableVMNames(from entries: [[String: Any]], protecting baseImage: String) -> [String] {
        entries.compactMap { entry in
            guard let name = entry["Name"] as? String ?? entry["name"] as? String else { return nil }
            guard name.hasPrefix(vmPrefix) else { return nil }
            // Belt and braces: never delete the image every job is cloned from,
            // whatever it happens to be called.
            guard name != baseImage else { return nil }
            return name
        }
    }
}

/// Single-quote a value for safe interpolation into a remote shell command.
func shellQuote(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
}
