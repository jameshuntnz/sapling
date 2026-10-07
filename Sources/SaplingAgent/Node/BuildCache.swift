import CryptoKit
import Foundation
import SaplingCore

/// Build output kept on the host between jobs, one copy per repository and job.
///
/// Each key holds a *seed*: what the last trusted run of that job left behind.
/// A job never touches a seed directly. It gets a *lease* — an APFS clone of
/// the seed, which costs nothing however large the seed is — mounted into its
/// VM. When the job ends the lease either replaces the seed or is thrown away,
/// so two jobs on the same key never write over each other, and a job that
/// dies half way through a write leaves the seed as it was.
///
/// Whether a lease may replace its seed is not decided here — see
/// `BuildCachePolicy`. This type only moves directories.
///
/// Every file operation runs as the console user. That user's `tart` mounts
/// the lease, and the guest's writes arrive owned by it; a lease created by
/// the root daemon would be a directory the job cannot write to.
actor BuildCache {
    /// Where the cache lives.
    let root: URL

    init(root: URL = SaplingPaths.buildCacheDirectory) {
        self.root = root
    }

    var seedsDirectory: URL { root.appendingPathComponent("seeds") }
    var leasesDirectory: URL { root.appendingPathComponent("leases") }

    /// The seed directory for a job, whether or not it exists yet.
    ///
    /// Keyed by job name as well as repository: two jobs in one repository
    /// usually build different things, and sharing one directory would have
    /// each promotion throw away the other's output.
    func seed(repo: String, jobName: String) -> URL {
        seedsDirectory
            .appendingPathComponent(Self.component(repo))
            .appendingPathComponent(Self.component(jobName))
    }

    /// The lease directory for a job.
    func lease(jobID: String) -> URL {
        leasesDirectory.appendingPathComponent(Self.component(jobID))
    }

    /// A filesystem-safe name that cannot collide with another input's.
    ///
    /// Readable for whoever is looking at the directory, with a short hash so
    /// that `a/b` and `a_b` — which sanitise to the same thing — stay apart.
    static func component(_ raw: String) -> String {
        let readable = String(
            raw.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "." ? $0 : "_" }.prefix(60))
        let digest = SHA256.hash(data: Data(raw.utf8))
        let hash = digest.prefix(4).map { String(format: "%02x", $0) }.joined()
        return "\(readable)-\(hash)"
    }

    /// Prepare a job's lease and return the directory to mount.
    ///
    /// - Parameters:
    ///   - repo: The repository, as `owner/name`.
    ///   - jobName: The job's name in its workflow.
    ///   - jobID: The job, which names the lease.
    /// - Returns: The lease, a clone of the seed if there is one and empty if not.
    /// - Throws: If the directories cannot be created or cloned.
    func prepareLease(repo: String, jobName: String, jobID: String) async throws -> URL {
        let seed = seed(repo: repo, jobName: jobName)
        let lease = lease(jobID: jobID)
        try await run("mkdir", ["-p", seedsDirectory.path, leasesDirectory.path])
        try await run("rm", ["-rf", lease.path])

        guard FileManager.default.fileExists(atPath: seed.path) else {
            try await run("mkdir", ["-p", lease.path])
            return lease
        }
        // `-c` asks for clonefile(2): the copy shares the seed's blocks until
        // one side writes, so a multi-gigabyte seed clones in well under a
        // second and costs no disk until the job changes something.
        try await run("cp", ["-c", "-R", seed.path, lease.path])
        // Marks the seed as used, which is what pruning orders by.
        try? await run("touch", [seed.path])
        return lease
    }

    /// Make a lease the new seed for its key.
    ///
    /// The old seed is moved aside before the lease takes its place, then
    /// deleted, so there is never a moment when a reader finds half of each.
    func promote(lease: URL, repo: String, jobName: String) async throws {
        let seed = seed(repo: repo, jobName: jobName)
        let retired = leasesDirectory.appendingPathComponent("retired-\(UUID().uuidString)")
        try await run("mkdir", ["-p", seed.deletingLastPathComponent().path])
        if FileManager.default.fileExists(atPath: seed.path) {
            try await run("mv", [seed.path, retired.path])
        }
        try await run("mv", [lease.path, seed.path])
        try? await run("touch", [seed.path])
        try? await run("rm", ["-rf", retired.path])
    }

    /// Throw a lease away.
    func discard(lease: URL) async {
        try? await run("rm", ["-rf", lease.path])
    }

    /// Delete every lease not held by a running job.
    ///
    /// Leases are only ever left behind by a daemon that stopped mid-job;
    /// nothing will come back for them.
    ///
    /// - Parameter active: Job ids whose leases are still in use.
    /// - Returns: The leases removed.
    @discardableResult
    func reapLeases(keeping active: Set<String>) async -> [String] {
        let keep = Set(active.map(Self.component))
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: leasesDirectory.path)) ?? []
        var removed: [String] = []
        for entry in entries where !keep.contains(entry) {
            try? await run("rm", ["-rf", leasesDirectory.appendingPathComponent(entry).path])
            removed.append(entry)
        }
        return removed
    }

    /// Delete the least recently used seeds until the cache fits its ceiling.
    ///
    /// - Parameter maxBytes: What the seeds may hold between them.
    /// - Returns: The seeds removed, as paths relative to the seeds directory.
    @discardableResult
    func prune(maxBytes: Int64) async -> [String] {
        var seeds = await seedSizes()
        var total = seeds.reduce(0) { $0 + $1.bytes }
        seeds.sort { $0.used < $1.used }
        var removed: [String] = []
        for seed in seeds where total > maxBytes {
            try? await run("rm", ["-rf", seed.url.path])
            total -= seed.bytes
            removed.append(seed.url.pathComponents.suffix(2).joined(separator: "/"))
        }
        return removed
    }

    /// Every seed, with what it occupies and when it was last used.
    func seedSizes() async -> [(url: URL, bytes: Int64, used: Date)] {
        let fm = FileManager.default
        var out: [(url: URL, bytes: Int64, used: Date)] = []
        for repo in (try? fm.contentsOfDirectory(atPath: seedsDirectory.path)) ?? [] {
            let repoURL = seedsDirectory.appendingPathComponent(repo)
            for job in (try? fm.contentsOfDirectory(atPath: repoURL.path)) ?? [] {
                let url = repoURL.appendingPathComponent(job)
                let used =
                    (try? fm.attributesOfItem(atPath: url.path)[.modificationDate] as? Date)
                    ?? .distantPast
                out.append((url, await Self.allocatedBytes(of: url), used))
            }
        }
        return out
    }

    /// Disk a directory occupies, as `du` counts it.
    static func allocatedBytes(of url: URL) async -> Int64 {
        guard let result = try? await ProcessRunner.run("du", ["-sk", url.path]), result.succeeded,
            let kilobytes = Int64(result.trimmedOutput.split(separator: "\t").first ?? "")
        else { return 0 }
        return kilobytes * 1024
    }

    private func run(_ tool: String, _ arguments: [String]) async throws {
        let command = try await SessionCommand.invocation(tool, arguments)
        try await ProcessRunner.runChecked(
            command.executable, command.arguments, timeout: .seconds(300))
    }
}
