import Foundation
import SaplingCore

/// What is using the node's disk, and the cleanups a person can ask for.
///
/// The automatic housekeeping already reaps leaked clones and superseded built
/// images. What it deliberately leaves is anything it cannot
/// judge: a VM someone kept on purpose, images that might be wanted again, and
/// logs someone might still read. Those are questions for a person, so they
/// are shown here with what each costs, and done only when asked.
extension NodeAgent {
    /// How old a finished job must be before `trimLogs` drops its log.
    static let logRetentionDays = 14
    /// The container Apple's `container builder` runs as.
    static let builderContainerID = "buildkit"

    /// The breakdown of the node's disk.
    ///
    /// - Returns: Volume size and free space, and the largest users of it.
    public func diskReport() async -> DiskReport {
        let volume = DiskSpace.volume(at: SaplingPaths.home) ?? (0, 0)
        var items: [DiskItem] = []
        if config.macos.enabled { items += await vmItems() }
        if config.linux.enabled { items += await containerItems() }

        let database = [SaplingPaths.databaseFile.path, SaplingPaths.databaseFile.path + "-wal"]
            .compactMap { try? FileManager.default.attributesOfItem(atPath: $0)[.size] as? Int64 }
            .reduce(0, +)
        items.append(
            DiskItem(
                id: "logs", name: "Job event logs",
                detail: "Every runner line of every job. Trimming keeps the jobs, and drops the logs of "
                    + "those finished over \(Self.logRetentionDays) days ago.",
                bytes: database, action: .trimLogs))
        items.append(
            DiskItem(
                id: "cache", name: "Dependency cache",
                detail: "Maven and npm downloads the cache proxy serves to jobs.",
                bytes: DiskSpace.allocatedSize(of: SaplingPaths.runnerCacheDirectory)))

        return DiskReport(
            totalBytes: volume.total, freeBytes: volume.free,
            items: items.sorted { $0.bytes > $1.bytes })
    }

    /// Do one cleanup, and measure what it actually freed.
    ///
    /// - Parameter request: The action, and its target where it needs one.
    /// - Returns: What happened and how much space came back.
    public func cleanDisk(_ request: DiskCleanupRequest) async -> DiskCleanupResponse {
        let before = DiskSpace.volume(at: SaplingPaths.home)?.free
        let message: String
        do {
            switch request.action {
            case .deleteVM: message = try await deleteUnmanagedVM(named: request.target)
            case .pruneImages: message = try await pruneUnusedImages()
            case .resetBuilder: message = try await resetBuilder()
            case .trimLogs:
                let cutoff = Date().addingTimeInterval(-Double(Self.logRetentionDays) * 86400)
                let count = try await store.trimEvents(completedBefore: cutoff)
                message =
                    "trimmed \(count) log lines from jobs finished over \(Self.logRetentionDays) days ago"
            }
        } catch {
            return DiskCleanupResponse(message: "nothing was removed", error: error.localizedDescription)
        }
        Log.info("disk cleanup: \(message)")
        let after = DiskSpace.volume(at: SaplingPaths.home)?.free
        var freed: Int64?
        if let before, let after { freed = max(0, after - before) }
        return DiskCleanupResponse(message: message, freedBytes: freed)
    }

    // MARK: - Tart

    private func tartVMs() async -> [[String: Any]] {
        guard let command = try? await TartProvider.tart(["list", "--format", "json"]),
            let result = try? await ProcessRunner.run(command.executable, command.arguments),
            result.succeeded,
            let data = result.stdout.data(using: .utf8),
            let entries = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return [] }
        return entries
    }

    private func vmItems() async -> [DiskItem] {
        let gigabyte: Int64 = 1_073_741_824
        var items: [DiskItem] = []
        var cloneBytes: Int64 = 0
        var cloneCount = 0
        for entry in await tartVMs() {
            guard let name = entry["Name"] as? String else { continue }
            let bytes = Int64(entry["Size"] as? Int ?? 0) * gigabyte
            if name == config.macos.baseImage {
                items.append(
                    DiskItem(
                        id: "vm:\(name)", name: "macOS base image",
                        detail: "\(name) — every macOS job is cloned from it. Never removed from here.",
                        bytes: bytes))
            } else if name.hasPrefix(TartProvider.vmPrefix) {
                cloneBytes += bytes
                cloneCount += 1
            } else {
                let running = entry["Running"] as? Bool ?? false
                let accessed = (entry["Accessed"] as? String).map { "last used \($0.prefix(10))" } ?? ""
                items.append(
                    DiskItem(
                        id: "vm:\(name)", name: "VM \(name)",
                        detail: running
                            ? "Running, so it cannot be removed."
                            : "Not used by Sapling, \(accessed). Shares blocks with the base image, so "
                                + "removing it frees up to this much.",
                        bytes: bytes, reclaimableBytes: running ? nil : bytes,
                        action: running ? nil : .deleteVM, target: name))
            }
        }
        if cloneCount > 0 {
            items.append(
                DiskItem(
                    id: "vm:clones", name: "macOS job VMs (\(cloneCount))",
                    detail: "Clones of the base image for running jobs. Most of this is shared with it.",
                    bytes: cloneBytes))
        }
        return items
    }

    /// Deletes a VM that is neither the base nor a job's clone.
    ///
    /// Re-checked against a fresh listing rather than trusting the request:
    /// the API has no auth, and deleting the base image costs an hour's rebuild.
    private func deleteUnmanagedVM(named name: String?) async throws -> String {
        guard let name, !name.isEmpty else { throw ProviderError("no VM named") }
        guard name != config.macos.baseImage, !name.hasPrefix(TartProvider.vmPrefix) else {
            throw ProviderError("\(name) is managed by Sapling and is not removed from here")
        }
        guard let entry = await tartVMs().first(where: { $0["Name"] as? String == name }) else {
            throw ProviderError("no VM named \(name)")
        }
        guard (entry["Running"] as? Bool) != true else { throw ProviderError("\(name) is running") }
        let command = try await TartProvider.tart(["delete", name])
        let result = try await ProcessRunner.run(
            command.executable, command.arguments, timeout: .seconds(300))
        guard result.succeeded else {
            throw ProviderError("tart delete \(name) failed: \(result.trimmedOutput)")
        }
        return "deleted VM \(name)"
    }

    // MARK: - container

    private struct SystemDF: Decodable {
        struct Usage: Decodable {
            let active: Int
            let total: Int
            let sizeInBytes: Int64
            let reclaimable: Int64
        }
        let images: Usage
        let containers: Usage
    }

    private func containerItems() async -> [DiskItem] {
        guard
            let command = try? await SessionCommand.invocation(
                "container", ["system", "df", "--format", "json"]),
            let result = try? await ProcessRunner.run(
                command.executable, command.arguments, timeout: .seconds(60)),
            result.succeeded,
            let usage = try? JSONDecoder().decode(SystemDF.self, from: Data(result.stdout.utf8))
        else { return [] }
        var items = [
            DiskItem(
                id: "images", name: "Linux images (\(usage.images.total))",
                detail: "\(usage.images.active) in use. Housekeeping keeps the two newest builds of "
                    + "each repository image. Removing the rest means the runner image is pulled "
                    + "again, and built images rebuilt, when a job next needs them.",
                bytes: usage.images.sizeInBytes, reclaimableBytes: usage.images.reclaimable,
                action: usage.images.reclaimable > 0 ? .pruneImages : nil)
        ]
        // `system df` counts the builder as a container; it is not a job's.
        let builder = await builderBytes()
        if let builder {
            items.append(
                DiskItem(
                    id: "builder", name: "Image builder cache",
                    detail: "BuildKit's layer cache, kept for as long as the builder exists. Resetting "
                        + "it makes the next image build start from scratch.",
                    bytes: builder, reclaimableBytes: builder, action: .resetBuilder))
        }
        let jobContainers = usage.containers.total - (builder == nil ? 0 : 1)
        items.append(
            DiskItem(
                id: "containers", name: "Linux job containers (\(jobContainers))",
                detail: "Running jobs' containers, removed when each job ends.",
                bytes: max(0, usage.containers.sizeInBytes - (builder ?? 0))))
        return items
    }

    /// The builder container's allocated size, or `nil` if there is none.
    private func builderBytes() async -> Int64? {
        guard let home = await containerUserHome() else { return nil }
        let directory = home.appendingPathComponent(
            "Library/Application Support/com.apple.container/containers/\(Self.builderContainerID)")
        guard FileManager.default.fileExists(atPath: directory.path) else { return nil }
        return DiskSpace.allocatedSize(of: directory)
    }

    /// Home of the user whose `container` state this is.
    private func containerUserHome() async -> URL? {
        guard getuid() == 0 else { return URL(fileURLWithPath: NSHomeDirectory()) }
        guard let user = await SessionCommand.sessionUser() else { return nil }
        return FileManager.default.homeDirectory(forUser: user.name)
    }

    /// Deletes the builder, unless a Linux job might be building with it.
    private func resetBuilder() async throws -> String {
        let linuxJobs = try await store.activeJobs().filter { $0.platform == .linux }
        guard linuxJobs.isEmpty else {
            throw ProviderError(
                "\(linuxJobs.count) Linux job(s) running; reset the builder when none are")
        }
        let command = try await SessionCommand.invocation("container", ["builder", "delete", "--force"])
        let result = try await ProcessRunner.run(
            command.executable, command.arguments, timeout: .seconds(300))
        guard result.succeeded else {
            throw ProviderError("builder delete failed: \(result.trimmedOutput)")
        }
        return "deleted the image builder and its cache"
    }

    private func pruneUnusedImages() async throws -> String {
        let command = try await SessionCommand.invocation("container", ["image", "prune", "--all"])
        let result = try await ProcessRunner.run(
            command.executable, command.arguments, timeout: .seconds(600))
        guard result.succeeded else { throw ProviderError("image prune failed: \(result.trimmedOutput)") }
        return "removed unused Linux images"
    }
}
