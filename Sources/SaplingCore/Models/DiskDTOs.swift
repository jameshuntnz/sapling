import Foundation

/// A cleanup the node can do on request.
public enum DiskAction: String, Codable, Sendable, Hashable {
    /// Delete one Tart VM that is neither the base image nor a job's clone.
    case deleteVM = "delete_vm"
    /// Remove every Linux image no container is using.
    case pruneImages = "prune_images"
    /// Drop the event logs of jobs that finished a while ago.
    case trimLogs = "trim_logs"
}

/// One thing taking space on the node.
public struct DiskItem: Codable, Sendable, Hashable, Identifiable {
    /// Stable identity for the list.
    public var id: String
    /// What it is.
    public var name: String
    /// Why it is there, or what removing it costs.
    public var detail: String
    /// Space it occupies, as its tool reports it.
    ///
    /// Not additive: Tart VMs are APFS clones that share blocks, so a clone's
    /// size is mostly the base image's.
    public var bytes: Int64
    /// How much the action could free, when the tool can say.
    public var reclaimableBytes: Int64?
    /// What can be done about it, if anything.
    public var action: DiskAction?
    /// What the action applies to — the VM's name for `deleteVM`.
    public var target: String?

    /// Creates an item.
    public init(
        id: String, name: String, detail: String, bytes: Int64,
        reclaimableBytes: Int64? = nil, action: DiskAction? = nil, target: String? = nil
    ) {
        self.id = id
        self.name = name
        self.detail = detail
        self.bytes = bytes
        self.reclaimableBytes = reclaimableBytes
        self.action = action
        self.target = target
    }
}

/// Response body for `GET /api/v1/disk`.
public struct DiskReport: Codable, Sendable {
    /// Size of the node's data volume.
    public var totalBytes: Int64
    /// Space free on it.
    public var freeBytes: Int64
    /// What is using it, largest first.
    public var items: [DiskItem]

    /// Creates a report.
    public init(totalBytes: Int64, freeBytes: Int64, items: [DiskItem]) {
        self.totalBytes = totalBytes
        self.freeBytes = freeBytes
        self.items = items
    }
}

/// Request body for `POST /api/v1/disk/cleanup`.
public struct DiskCleanupRequest: Codable, Sendable {
    /// What to do.
    public var action: DiskAction
    /// What to do it to, where the action needs one.
    public var target: String?

    /// Creates a cleanup request.
    public init(action: DiskAction, target: String? = nil) {
        self.action = action
        self.target = target
    }
}

/// Response body for `POST /api/v1/disk/cleanup`.
public struct DiskCleanupResponse: Codable, Sendable {
    /// What happened, phrased for a person.
    public var message: String
    /// Free space gained, measured before and after rather than estimated.
    public var freedBytes: Int64?
    /// Why nothing was done, when it was refused or failed.
    public var error: String?

    /// Creates a cleanup result.
    public init(message: String, freedBytes: Int64? = nil, error: String? = nil) {
        self.message = message
        self.freedBytes = freedBytes
        self.error = error
    }
}

/// Space on a volume.
public enum DiskSpace {
    /// Total and free bytes on the volume holding a path.
    ///
    /// - Parameter url: Any path on the volume.
    /// - Returns: The volume's size and free space, or `nil` if it cannot be read.
    public static func volume(at url: URL) -> (total: Int64, free: Int64)? {
        guard
            let values = try? url.resourceValues(forKeys: [
                .volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey,
            ]),
            let total = values.volumeTotalCapacity,
            let free = values.volumeAvailableCapacityForImportantUsage
        else { return nil }
        return (Int64(total), free)
    }

    /// Bytes allocated to everything under a directory.
    ///
    /// - Parameter url: The directory to measure.
    /// - Returns: Its size; zero if it does not exist.
    public static func allocatedSize(of url: URL) -> Int64 {
        guard
            let enumerator = FileManager.default.enumerator(
                at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey])
        else { return 0 }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            total += Int64(
                (try? file.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?
                    .totalFileAllocatedSize ?? 0)
        }
        return total
    }
}
