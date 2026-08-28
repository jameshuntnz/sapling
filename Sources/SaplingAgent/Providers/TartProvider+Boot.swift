import Foundation
import SaplingCore

/// Getting a VM from "cloned" to "reachable", and proving each step rather
/// than assuming it.
///
/// The order matters and is the point of the split. Ask the host first — it is
/// instant and needs nothing of the guest — then ask the guest. Reversed, a VM
/// on a dead subnet spends the whole boot timeout on an SSH that was never
/// going to connect, and the failure reads as a broken base image.
extension TartProvider {
    /// Fails the job unless a host bridge owns the VM's subnet.
    ///
    /// `tart ip` answers from a DHCP lease, so an address is not evidence of a
    /// network — and on this node an environment has held a perfectly ordinary
    /// address on a subnet the host had no interface for.
    func verifyBridge(ip: String, events: any EventSink) async throws {
        switch await JobNetwork.reachability(of: ip) {
        case .live(let gateway):
            await events.log("bridge ok — gateway \(gateway)")
        case .orphaned:
            throw VMAttachFailed(
                vmName: ip,
                detail: """
                    it holds an address on a subnet no host interface owns, so nothing will \
                    reach it and it will reach nothing
                    """)
        case .unknown(let reason):
            // Not fatal: the in-guest probe still has to pass, and failing a
            // job because `ifconfig` didn't run would be its own outage.
            await events.log("could not check the host bridge (\(reason))")
        }
    }

    /// The address Tart reports for a VM, or `nil` if it has none.
    static func address(ofVM name: String) async -> String? {
        guard let command = try? await tart(["ip", name]),
            let result = try? await ProcessRunner.run(
                command.executable, command.arguments, timeout: .seconds(20)),
            result.succeeded
        else {
            return nil
        }
        let address = result.trimmedOutput
        return address.isEmpty ? nil : address
    }

    /// Fails the job unless the VM can reach GitHub.
    ///
    /// The macOS equivalent of the container probe, run over SSH so the failure
    /// is recorded as Sapling's own event rather than buried in a job log the
    /// runner may never get far enough to produce.
    func verifyEgress(ip: String, events: any EventSink) async throws {
        let result = try await ProcessRunner.run(
            "ssh",
            sshArguments(ip: ip) + ["bash -s"],
            standardInput: EgressCheck.probeScript,
            timeout: .seconds(EgressCheck.timeout + 15)
        )
        guard !EgressCheck.isEgressFailure(result.exitCode), result.succeeded else {
            throw ProviderError(EgressCheck.failureReason)
        }
        await events.log("egress ok")
    }

    func waitForIP(vmName: String, timeout: Duration, process: VMBootProcess) async throws -> String {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            // Checked first, and every pass: a VM whose process has gone is
            // never going to report an address, and waiting out five minutes
            // to say so throws away the one message that named the cause.
            if let explanation = await process.explanation(vmName: vmName) {
                throw VMAttachFailed(vmName: vmName, detail: explanation)
            }
            let command = try await Self.tart(["ip", vmName])
            let result = try await ProcessRunner.run(command.executable, command.arguments)
            let ip = result.trimmedOutput
            if result.succeeded, !ip.isEmpty {
                return ip
            }
            try await Task.sleep(for: .seconds(2))
        }
        // Why it got no address matters more than the fact. A VM DHCPs from
        // the bridge vmnet brings up for it, so "no bridge at all" is a
        // different fault from "a bridge exists and the guest didn't ask".
        let bridges = (try? await BridgeTable.current()) ?? []
        let context =
            bridges.isEmpty
            ? "no bridge interface came up for it, so there was no network to get an address from"
            : "the host has \(bridges.map(\.name).joined(separator: ", ")), so the VM itself did not ask"
        throw VMAttachFailed(
            vmName: vmName,
            detail: "no address within \(timeout) — \(context)")
    }

    func waitForSSH(ip: String, timeout: Duration) async throws {
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

}

/// A VM that never got a network, which is worth another attempt rather than
/// a failed job.
///
/// Distinct from a `ProviderError` so the retry can tell "this VM did not come
/// up" apart from "this job failed". Measured in production: the attempt after
/// one of these boots in eight seconds and runs the job to completion.
struct VMAttachFailed: Error, LocalizedError, Sendable {
    /// The VM that did not come up.
    let vmName: String
    /// What was observed, phrased for a job's log.
    let detail: String

    /// The reason, for `LocalizedError`.
    var errorDescription: String? {
        "VM \(vmName) did not get a network: \(detail)."
    }
}
