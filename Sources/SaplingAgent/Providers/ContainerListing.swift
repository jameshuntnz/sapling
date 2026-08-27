import Foundation
import SaplingCore

/// One container, as `container list --format json` describes it.
///
/// Only the fields Sapling acts on. Note what the address means: it is the
/// address the container was *assigned*, which is not evidence that anything
/// answers on that network — a container whose bridge has gone reports the
/// same thing as a healthy one. Pair it with `BridgeTable` before believing it.
struct ContainerRecord: Sendable, Equatable {
    /// The container's name, which is also its id here.
    let id: String
    /// `running`, `stopped`, and so on.
    let state: String
    /// The assigned IPv4 address, prefix stripped.
    let address: String?
    /// The gateway the container will route through, if it reported one.
    let gateway: String?

    var isRunning: Bool { state == "running" }
}

/// Reads the container inventory from Apple's own tooling.
enum ContainerListing {
    /// Every container the system knows about.
    ///
    /// Returns an empty list on any failure, because every caller is either
    /// reporting health or sweeping orphans — neither should fail a job
    /// because the inventory could not be read.
    static func current(includeStopped: Bool = false) async -> [ContainerRecord] {
        var arguments = ["list", "--format", "json"]
        if includeStopped { arguments.insert("--all", at: 1) }
        guard let command = try? await SessionCommand.invocation("container", arguments),
            let result = try? await ProcessRunner.run(
                command.executable, command.arguments, timeout: .seconds(60)),
            result.succeeded
        else {
            return []
        }
        return parse(result.stdout)
    }

    /// Split from the call so it can be exercised against captured output —
    /// the shape below is real output from the node, not a guess.
    static func parse(_ json: String) -> [ContainerRecord] {
        guard let data = json.data(using: .utf8),
            let entries = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else {
            return []
        }
        return entries.compactMap { entry in
            let configuration = entry["configuration"] as? [String: Any]
            // `id` is top-level; there is no `name` field, despite the column
            // header `container list` prints.
            guard let id = (entry["id"] as? String) ?? (configuration?["id"] as? String) else {
                return nil
            }
            let status = entry["status"] as? [String: Any]
            let network = (status?["networks"] as? [[String: Any]])?.first
            let address = (network?["ipv4Address"] as? String)
                .map { String($0.split(separator: "/")[0]) }
            return ContainerRecord(
                id: id,
                state: (status?["state"] as? String) ?? "unknown",
                address: address,
                gateway: network?["ipv4Gateway"] as? String
            )
        }
    }
}

/// One Tart VM, as `tart list --format json` describes it.
struct TartVMRecord: Sendable, Equatable {
    /// The VM's name.
    let name: String
    /// Whether it is running right now.
    let isRunning: Bool
}

/// Reads Tart's own inventory of VMs.
enum TartListing {
    /// Every local VM Tart knows about.
    static func current() async -> [TartVMRecord] {
        guard let command = try? await TartProvider.tart(["list", "--format", "json"]),
            let result = try? await ProcessRunner.run(
                command.executable, command.arguments, timeout: .seconds(60)),
            result.succeeded
        else {
            return []
        }
        return parse(result.stdout)
    }

    static func parse(_ json: String) -> [TartVMRecord] {
        guard let data = json.data(using: .utf8),
            let entries = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else {
            return []
        }
        return entries.compactMap { entry in
            guard let name = entry["Name"] as? String else { return nil }
            // `Running` is the live flag; `State` is a string of the same fact.
            let running = (entry["Running"] as? Bool) ?? ((entry["State"] as? String) == "running")
            return TartVMRecord(name: name, isRunning: running)
        }
    }
}
