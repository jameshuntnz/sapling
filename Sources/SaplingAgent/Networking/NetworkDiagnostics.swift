import Foundation
import SaplingCore

/// Captures the host's networking state at the moment a VM fails to get one.
///
/// This exists because the root cause is *not known*. What is known: a VM's
/// `vmenet` interface is sometimes created and never attached to a bridge,
/// while a container's attaches normally seconds later; and that this happens
/// on a node that has been up for hours and never on one just rebooted —
/// three simultaneous container-and-VM starts on a fresh node attached
/// cleanly every time.
///
/// So the variable is uptime, not concurrency, and the fault cannot be
/// reproduced on demand. The only way to diagnose it is to be holding a
/// complete picture the next time it happens, which is what this writes.
///
/// Two hypotheses it is built to settle:
///
/// - **`InternetSharing` wedged.** It is the process that logs
///   `waiting for mis_vmnet_interface_attached_callback` and, in the observed
///   failure, never got the callback. If its log shows the same, the repair is
///   `launchctl kickstart -k system/com.apple.InternetSharing` — seconds,
///   rather than the reboot that is currently the only known fix.
/// - **`bootpd` lease exhaustion.** A `/24` has 253 addresses and a day of
///   jobs burns leases; if the lease file is full, that is the answer and it
///   has nothing to do with interfaces at all.
enum NetworkDiagnostics {
    /// Where captures are kept, one file per failure.
    static var directory: URL {
        SaplingPaths.home.appendingPathComponent("diagnostics")
    }

    /// Gather everything, write it to a file, and return a short summary.
    ///
    /// Best-effort throughout: this runs on a path that has already failed,
    /// and a diagnostic that throws would replace a useful error with a
    /// useless one.
    /// - Parameters:
    ///   - vmName: The VM that did not get a network.
    ///   - events: Where the summary is recorded.
    /// - Returns: A one-line summary naming the file.
    @discardableResult
    static func captureAttachFailure(vmName: String, events: any EventSink) async -> String {
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let file = directory.appendingPathComponent("attach-failure-\(stamp).txt")

        var report = "# \(vmName) did not get a network at \(stamp)\n\n"
        for section in sections {
            report += "## \(section.title)\n"
            report += await section.gather()
            report += "\n"
        }

        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        try? report.write(to: file, atomically: true, encoding: .utf8)

        // The summary goes on the job as well as into the file: the file is
        // only useful to someone who knows to look for it.
        let bridges = (try? await BridgeTable.current()) ?? []
        let summary =
            "captured host networking to \(file.path) — "
            + (bridges.isEmpty
                ? "no bridge interfaces exist at all"
                : "bridges: \(bridges.map { "\($0.name) \($0.address)" }.joined(separator: ", "))")
        await events.log(summary)
        return summary
    }

    /// One thing worth knowing, and how to find it out.
    private struct Section: Sendable {
        let title: String
        let command: String
        let arguments: [String]

        func gather() async -> String {
            guard
                let result = try? await ProcessRunner.run(
                    command, arguments, timeout: .seconds(30))
            else {
                return "(could not run `\(command)`)\n"
            }
            let output = result.stdout.isEmpty ? result.stderr : result.stdout
            return output.isEmpty ? "(no output)\n" : output + "\n"
        }
    }

    /// Everything captured, in the order someone reading it would want it.
    private static let sections: [Section] = [
        Section(title: "Interfaces", command: "ifconfig", arguments: ["-a"]),
        // Which vmenet interfaces exist and which bridge, if any, owns each.
        // A vmenet that is a member of nothing is the failure signature.
        Section(title: "Interface list", command: "ifconfig", arguments: ["-l"]),
        // Leaked `tart run` wrappers, the best current candidate for whatever
        // accumulates — unproven, which is the point of capturing it.
        Section(title: "tart processes", command: "pgrep", arguments: ["-fl", "tart run"]),
        Section(title: "Virtualization processes", command: "pgrep", arguments: ["-fl", "Virtualization"]),
        // Settles the lease-exhaustion hypothesis outright.
        Section(title: "DHCP leases", command: "cat", arguments: ["/var/db/dhcpd_leases"]),
        // Settles the InternetSharing hypothesis: look for a
        // `mis_vmnet_interface_attached_callback` that never arrived.
        Section(
            title: "InternetSharing log",
            command: "log",
            arguments: [
                "show", "--last", "3m", "--style", "compact",
                "--predicate", "process == \"InternetSharing\" OR process == \"bootpd\"",
            ]),
    ]
}
