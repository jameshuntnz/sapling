import Foundation
import Testing

@testable import SaplingAgent

/// The build cache's directory handling, against a real temporary directory.
///
/// Runs the same `cp`, `mv` and `rm` the node runs. Not as root, so
/// `SessionCommand` hands them straight through — the routing itself is
/// `SessionRoutingTests`' business.
@Suite("Build cache")
struct BuildCacheTests {
    let root: URL
    let cache: BuildCache

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sapling-build-cache-\(UUID().uuidString)")
        cache = BuildCache(root: root)
    }

    func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    func read(_ url: URL) -> String? {
        (try? Data(contentsOf: url)).map { String(decoding: $0, as: UTF8.self) }
    }

    @Test("a first lease is empty, and promoting it seeds the next one")
    func leaseThenPromote() async throws {
        defer { try? FileManager.default.removeItem(at: root) }

        let first = try await cache.prepareLease(repo: "acme/app", jobName: "build", jobID: "1")
        #expect(try FileManager.default.contentsOfDirectory(atPath: first.path).isEmpty)
        try write("v1", to: first.appendingPathComponent(".build/out"))
        try await cache.promote(lease: first, repo: "acme/app", jobName: "build")

        let second = try await cache.prepareLease(repo: "acme/app", jobName: "build", jobID: "2")
        #expect(read(second.appendingPathComponent(".build/out")) == "v1")
    }

    /// The property that makes concurrent jobs on one key safe.
    @Test("writing a lease leaves the seed alone until it is promoted")
    func leasesAreIsolated() async throws {
        defer { try? FileManager.default.removeItem(at: root) }

        let seeded = try await cache.prepareLease(repo: "acme/app", jobName: "build", jobID: "1")
        try write("v1", to: seeded.appendingPathComponent("out"))
        try await cache.promote(lease: seeded, repo: "acme/app", jobName: "build")

        let lease = try await cache.prepareLease(repo: "acme/app", jobName: "build", jobID: "2")
        try write("v2", to: lease.appendingPathComponent("out"))
        let seed = await cache.seed(repo: "acme/app", jobName: "build")
        #expect(read(seed.appendingPathComponent("out")) == "v1")

        await cache.discard(lease: lease)
        #expect(!FileManager.default.fileExists(atPath: lease.path))
        #expect(read(seed.appendingPathComponent("out")) == "v1")
    }

    @Test("two jobs in one repository keep separate seeds")
    func keyedByJob() async throws {
        defer { try? FileManager.default.removeItem(at: root) }

        let ios = try await cache.prepareLease(repo: "acme/app", jobName: "iOS", jobID: "1")
        try write("ios", to: ios.appendingPathComponent("out"))
        try await cache.promote(lease: ios, repo: "acme/app", jobName: "iOS")

        let tests = try await cache.prepareLease(repo: "acme/app", jobName: "tests", jobID: "2")
        #expect(!FileManager.default.fileExists(atPath: tests.appendingPathComponent("out").path))
    }

    @Test("reaping removes leases nothing is running, and keeps the rest")
    func reaping() async throws {
        defer { try? FileManager.default.removeItem(at: root) }

        let live = try await cache.prepareLease(repo: "acme/app", jobName: "build", jobID: "live")
        let dead = try await cache.prepareLease(repo: "acme/app", jobName: "build", jobID: "dead")
        let removed = await cache.reapLeases(keeping: ["live"])

        #expect(removed.count == 1)
        #expect(FileManager.default.fileExists(atPath: live.path))
        #expect(!FileManager.default.fileExists(atPath: dead.path))
    }

    @Test("pruning drops the least recently used seed first")
    func pruning() async throws {
        defer { try? FileManager.default.removeItem(at: root) }

        for (id, name) in [("1", "old"), ("2", "new")] {
            let lease = try await cache.prepareLease(repo: "acme/app", jobName: name, jobID: id)
            try Data(count: 256 * 1024).write(to: lease.appendingPathComponent("blob"))
            try await cache.promote(lease: lease, repo: "acme/app", jobName: name)
        }
        let old = await cache.seed(repo: "acme/app", jobName: "old")
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -3600)], ofItemAtPath: old.path)

        let removed = await cache.prune(maxBytes: 300 * 1024)
        #expect(removed.count == 1)
        #expect(!FileManager.default.fileExists(atPath: old.path))
        let new = await cache.seed(repo: "acme/app", jobName: "new")
        #expect(FileManager.default.fileExists(atPath: new.path))
    }

    @Test("names that sanitise alike still get different directories")
    func componentsDoNotCollide() {
        #expect(BuildCache.component("a/b") != BuildCache.component("a_b"))
        #expect(!BuildCache.component("../../etc").contains("/"))
        #expect(BuildCache.component("build (ios)").hasPrefix("build__ios_-"))
    }

    @Test("the VM gets the lease shared under a fixed name, and no share without one")
    func tartArguments() {
        let shared = TartProvider.runArguments(
            vmName: "sapling-job-1", buildCache: URL(fileURLWithPath: "/cache/leases/1"))
        #expect(shared == ["run", "--no-graphics", "--dir=sapling-cache:/cache/leases/1", "sapling-job-1"])
        #expect(TartProvider.runArguments(vmName: "vm", buildCache: nil) == ["run", "--no-graphics", "vm"])
    }
}

/// Which finished jobs may replace a seed.
@Suite("Build cache policy")
struct BuildCachePolicyTests {
    func job(
        conclusion: String? = "success", branch: String? = "main", runner: String? = "sap-macos-1"
    ) -> WorkflowJob {
        WorkflowJob(
            id: 1, runId: 2, name: "build", status: "completed", conclusion: conclusion,
            labels: [], headSha: "abc", headBranch: branch, startedAt: nil, completedAt: nil,
            runnerName: runner)
    }

    func run(event: String? = "push", head: String? = "acme/widgets") -> WorkflowRun {
        WorkflowRun(
            id: 2, name: "CI", status: "completed", event: event, headBranch: "main",
            headRepository: RunHeadRepository(fullName: head))
    }

    func refusal(
        _ remote: WorkflowJob, run: WorkflowRun? = nil, runner: String = "sap-macos-1",
        defaultBranch: String? = "main", merged: Bool? = true
    ) -> String? {
        BuildCachePolicy.refusal(
            remote: remote, run: run ?? self.run(), repo: "acme/widgets", runnerName: runner,
            defaultBranch: defaultBranch, onDefaultBranch: merged)
    }

    @Test("a successful default-branch push on our runner is promoted")
    func promotes() {
        #expect(refusal(job()) == nil)
        #expect(refusal(job(), run: run(event: "schedule")) == nil)
    }

    /// A release builds from this cache, and the node installs its releases.
    @Test("a pull request's branch reads the cache but never writes it")
    func branchesDoNotWrite() {
        #expect(refusal(job(branch: "feature"))?.contains("only main") == true)
    }

    /// A JIT runner takes any queued job that matches its labels.
    @Test("output from a job that ran on another runner is not promoted")
    func otherRunner() {
        #expect(refusal(job(runner: "sap-macos-2")) != nil)
    }

    /// These name the default branch while running whatever a pull request,
    /// or a tag of the same name, points at.
    @Test("comment, pull_request_target and workflow_run triggers, and tags named main, refuse")
    func lookalikesOfMain() {
        for event in ["issue_comment", "pull_request_target", "workflow_run", nil] {
            #expect(refusal(job(), run: run(event: event)) != nil, "\(event ?? "nil")")
        }
        #expect(refusal(job(), run: run(head: "mallory/widgets")) != nil)
        #expect(refusal(job(), merged: false)?.contains("not on main") == true)
        #expect(refusal(job(), merged: nil) != nil)
    }

    @Test("failure, an unfinished job, or an unknown default branch all refuse")
    func refusals() {
        #expect(refusal(job(conclusion: "failure")) != nil)
        #expect(refusal(job(), defaultBranch: nil) != nil)
        #expect(refusal(job(branch: nil)) != nil)
    }
}
