import Foundation

/// The `[macos]` section: how macOS jobs are run.
public struct MacOSConfig: Codable, Sendable {
    /// Apple's virtualization licensing allows at most 2 concurrent macOS VMs per host.
    ///
    /// This is a hard ceiling, not a tuning knob (§5.1).
    public static let appleConcurrencyLimit = 2

    /// Whether this node accepts jobs for this platform.
    public var enabled: Bool
    /// Tart image that every job's VM is cloned from.
    public var baseImage: String
    /// Requested concurrency.
    ///
    /// Read `effectiveMaxConcurrent` instead — this value is advisory and may be clamped.
    public var maxConcurrent: Int
    /// Account the agent logs into inside the VM.
    public var sshUsername: String
    /// Base image password.
    ///
    /// Only used for first-time image preparation; running jobs are reached with a key.
    public var sshPassword: String
    /// Runner labels this node offers.
    ///
    /// A job is eligible when its labels are a subset of these.
    public var labels: [String]
    /// How long to wait for a VM to boot and accept SSH.
    public var bootTimeoutSeconds: Int
    /// How long a single job may run before it is terminated.
    public var jobTimeoutSeconds: Int
    /// CPU cores per environment. `nil` uses the tool's default.
    public var cpuCount: Int?
    /// Default memory per job in GB, when the workflow doesn't ask for a size.
    ///
    /// A job overrides this with a `mem:` label. `nil` falls through to the
    /// tool's own default, which is rarely what anyone wants — see
    /// `containerDefaultMemoryGB`.
    public var memoryGB: Int?
    /// Largest size a `mem:` label may ask for on this platform, in GB.
    ///
    /// A ceiling on what a workflow can request, separate from what the machine
    /// happens to have: a repository asking for 64GB should be told its request
    /// is refused, not left queued forever on a node that can never satisfy it.
    /// `nil` means only the node's memory budget limits it.
    public var maxMemoryGB: Int?

    /// What a prepared base image asks for, when config names no size.
    ///
    /// Tart honours the image's own setting, and the documented base image asks
    /// for 8GB. Used only as the figure a VM of unknown size is *charged*
    /// against the budget: guessing low would let the scheduler admit work
    /// against memory the VM is about to take anyway.
    public static let baseImageDefaultMemoryGB = 8

    /// `maxConcurrent` clamped to Apple's limit.
    ///
    /// Always use this, never the raw config value.
    public var effectiveMaxConcurrent: Int {
        guard enabled else { return 0 }
        return min(max(0, maxConcurrent), Self.appleConcurrencyLimit)
    }

    enum CodingKeys: String, CodingKey {
        case enabled, labels
        case baseImage = "base_image"
        case maxConcurrent = "max_concurrent"
        case sshUsername = "ssh_username"
        case sshPassword = "ssh_password"
        case bootTimeoutSeconds = "boot_timeout_seconds"
        case jobTimeoutSeconds = "job_timeout_seconds"
        case cpuCount = "cpu_count"
        case memoryGB = "memory_gb"
        case maxMemoryGB = "max_memory_gb"
    }

    /// Creates a platform configuration.
    public init(
        enabled: Bool = true,
        baseImage: String = "sapling-macos-base",
        maxConcurrent: Int = 2,
        sshUsername: String = "admin",
        sshPassword: String = "admin",
        labels: [String] = ["self-hosted", "macos", "arm64"],
        bootTimeoutSeconds: Int = 300,
        jobTimeoutSeconds: Int = 7200,
        cpuCount: Int? = nil,
        memoryGB: Int? = nil,
        maxMemoryGB: Int? = nil
    ) {
        self.enabled = enabled
        self.baseImage = baseImage
        self.maxConcurrent = maxConcurrent
        self.sshUsername = sshUsername
        self.sshPassword = sshPassword
        self.labels = labels
        self.bootTimeoutSeconds = bootTimeoutSeconds
        self.jobTimeoutSeconds = jobTimeoutSeconds
        self.cpuCount = cpuCount
        self.memoryGB = memoryGB
        self.maxMemoryGB = maxMemoryGB
    }

    /// Creates a platform configuration.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        baseImage = try c.decodeIfPresent(String.self, forKey: .baseImage) ?? "sapling-macos-base"
        maxConcurrent = try c.decodeIfPresent(Int.self, forKey: .maxConcurrent) ?? 2
        sshUsername = try c.decodeIfPresent(String.self, forKey: .sshUsername) ?? "admin"
        sshPassword = try c.decodeIfPresent(String.self, forKey: .sshPassword) ?? "admin"
        labels = try c.decodeIfPresent([String].self, forKey: .labels) ?? ["self-hosted", "macos", "arm64"]
        bootTimeoutSeconds = try c.decodeIfPresent(Int.self, forKey: .bootTimeoutSeconds) ?? 300
        jobTimeoutSeconds = try c.decodeIfPresent(Int.self, forKey: .jobTimeoutSeconds) ?? 7200
        cpuCount = try c.decodeIfPresent(Int.self, forKey: .cpuCount)
        memoryGB = try c.decodeIfPresent(Int.self, forKey: .memoryGB)
        maxMemoryGB = try c.decodeIfPresent(Int.self, forKey: .maxMemoryGB)
    }
}

/// The `[linux]` section: how Linux jobs are run.
public struct LinuxConfig: Codable, Sendable {
    /// Whether this node accepts jobs for this platform.
    public var enabled: Bool
    /// Container image used when a workflow doesn't name one.
    public var defaultImage: String
    /// Requested concurrency.
    ///
    /// Read `effectiveMaxConcurrent` instead — this value is advisory and may be clamped.
    public var maxConcurrent: Int
    /// Runner labels this node offers.
    ///
    /// A job is eligible when its labels are a subset of these.
    public var labels: [String]
    /// How long a single job may run before it is terminated.
    public var jobTimeoutSeconds: Int
    /// CPU cores per environment. `nil` uses the tool's default.
    public var cpuCount: Int?
    /// Default memory per job in GB, when the workflow doesn't ask for a size.
    ///
    /// A job overrides this with a `mem:` label. `nil` falls through to the
    /// tool's own default, which is rarely what anyone wants — see
    /// `containerDefaultMemoryGB`.
    public var memoryGB: Int?
    /// Largest size a `mem:` label may ask for on this platform, in GB.
    ///
    /// A ceiling on what a workflow can request, separate from what the machine
    /// happens to have: a repository asking for 64GB should be told its request
    /// is refused, not left queued forever on a node that can never satisfy it.
    /// `nil` means only the node's memory budget limits it.
    public var maxMemoryGB: Int?
    /// Image architecture to run. `nil` uses the host's, which is `arm64` here.
    ///
    /// Set this only to run a foreign-architecture image outright; to run the
    /// occasional x86-64 binary on an otherwise native arm64 image, leave this
    /// alone and turn on `rosetta` instead — that keeps the JVM, compilers and
    /// everything else running natively.
    public var arch: String?
    /// Whether this node will build images defined by the repositories it runs.
    ///
    /// A repository's Dockerfile executes arbitrary commands on the node at
    /// build time, outside the job container. What bounds that is `ForkPolicy`
    /// — the definition is read at the job's own commit, and only commits from
    /// the watched repository are ever run — so this is the same trust as
    /// running a job, granted more widely. A node can decline it, and on a
    /// public repository that is worth thinking about twice: the people who can
    /// push to it are the people who can run a build step as this daemon.
    public var buildImages: Bool
    /// Directory, within each repository, holding image definitions.
    ///
    /// One subdirectory per image: `<imagesPath>/<name>/Dockerfile`.
    public var imagesPath: String
    /// Whether to expose Rosetta translation inside the container.
    ///
    /// Apple's `container` registers Rosetta as a binfmt handler, so x86-64
    /// binaries run on an arm64 guest. The one build tool that needs this is
    /// Android's `aapt2`, which Google publishes for `linux-x86_64` only —
    /// with this on, an Android build runs natively apart from resource
    /// packaging. The image must also carry the x86-64 loader and libc
    /// (`libc6:amd64`, `libgcc-s1:amd64` on Debian/Ubuntu), and the *host*
    /// must have Rosetta installed.
    public var rosetta: Bool

    /// What `container` gives a container when `--memory` is absent.
    ///
    /// Apple's default, reported by `container system property list`. Leaving
    /// `memoryGB` nil does not mean "let the tool size it sensibly" — it means
    /// this, and 1GB is under half what a real CI build needs. It is enough to
    /// boot a runner, check out a repository and compile, which is what makes
    /// it dangerous: the job dies late, in whatever step allocates most, and
    /// the guest's OOM killer leaves no message in the job log. See
    /// `MemoryKill` for what the survivors report instead.
    public static let containerDefaultMemoryGB = 1

    /// Concurrency the scheduler actually uses, after clamping.
    public var effectiveMaxConcurrent: Int {
        enabled ? max(0, maxConcurrent) : 0
    }

    enum CodingKeys: String, CodingKey {
        case enabled, labels, arch, rosetta
        case defaultImage = "default_image"
        case buildImages = "build_images"
        case imagesPath = "images_path"
        case maxConcurrent = "max_concurrent"
        case jobTimeoutSeconds = "job_timeout_seconds"
        case cpuCount = "cpu_count"
        case memoryGB = "memory_gb"
        case maxMemoryGB = "max_memory_gb"
    }

    /// Creates a platform configuration.
    public init(
        enabled: Bool = true,
        defaultImage: String = "ghcr.io/actions/actions-runner:latest",
        maxConcurrent: Int = 2,
        labels: [String] = ["self-hosted", "linux", "arm64"],
        jobTimeoutSeconds: Int = 7200,
        cpuCount: Int? = nil,
        memoryGB: Int? = nil,
        maxMemoryGB: Int? = nil,
        arch: String? = nil,
        rosetta: Bool = false,
        buildImages: Bool = true,
        imagesPath: String = ".sapling/images"
    ) {
        self.enabled = enabled
        self.defaultImage = defaultImage
        self.maxConcurrent = maxConcurrent
        self.labels = labels
        self.jobTimeoutSeconds = jobTimeoutSeconds
        self.cpuCount = cpuCount
        self.memoryGB = memoryGB
        self.maxMemoryGB = maxMemoryGB
        self.arch = arch
        self.rosetta = rosetta
        self.buildImages = buildImages
        self.imagesPath = imagesPath
    }

    /// Creates a platform configuration.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        defaultImage =
            try c.decodeIfPresent(String.self, forKey: .defaultImage)
            ?? "ghcr.io/actions/actions-runner:latest"
        maxConcurrent = try c.decodeIfPresent(Int.self, forKey: .maxConcurrent) ?? 2
        labels = try c.decodeIfPresent([String].self, forKey: .labels) ?? ["self-hosted", "linux", "arm64"]
        jobTimeoutSeconds = try c.decodeIfPresent(Int.self, forKey: .jobTimeoutSeconds) ?? 7200
        cpuCount = try c.decodeIfPresent(Int.self, forKey: .cpuCount)
        memoryGB = try c.decodeIfPresent(Int.self, forKey: .memoryGB)
        maxMemoryGB = try c.decodeIfPresent(Int.self, forKey: .maxMemoryGB)
        arch = try c.decodeIfPresent(String.self, forKey: .arch)
        rosetta = try c.decodeIfPresent(Bool.self, forKey: .rosetta) ?? false
        buildImages = try c.decodeIfPresent(Bool.self, forKey: .buildImages) ?? true
        imagesPath = try c.decodeIfPresent(String.self, forKey: .imagesPath) ?? ".sapling/images"
    }
}
