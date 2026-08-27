import Foundation
import Testing

@testable import SaplingAgent
@testable import SaplingCore

@Suite("Repository-defined images")
struct RunnerImageTests {
    // MARK: - Label parsing

    /// The selector must leave the label set before eligibility is decided.
    ///
    /// Left in, it is not one of the node's advertised labels, the subset test
    /// fails, and every job asking for an image queues forever against a node
    /// that could have run it.
    @Test("an image selector is split out and never treated as a capability")
    func splitsSelector() {
        let (capabilities, image) = RunnerImageSelector.split(
            ["self-hosted", "linux", "arm64", "image:android"])
        #expect(capabilities == ["self-hosted", "linux", "arm64"])
        #expect(image == "android")

        let plain = RunnerImageSelector.split(["self-hosted", "linux", "arm64"])
        #expect(plain.capabilities == ["self-hosted", "linux", "arm64"])
        #expect(plain.image == nil)
    }

    @Test("the last selector wins when a workflow supplies several")
    func lastSelectorWins() {
        #expect(RunnerImageSelector.split(["image:a", "image:b"]).image == "b")
    }

    /// The name is joined onto a repository path, so anything that could
    /// escape that directory is refused rather than rewritten — a silently
    /// sanitised name would build something other than what was asked for.
    @Test("selector names that could escape the images directory are refused")
    func rejectsUnsafeNames() {
        #expect(RunnerImageSelector.isValidName("android"))
        #expect(RunnerImageSelector.isValidName("release-tools"))
        #expect(RunnerImageSelector.isValidName("node_22.1"))

        #expect(!RunnerImageSelector.isValidName(""))
        #expect(!RunnerImageSelector.isValidName(".."))
        #expect(!RunnerImageSelector.isValidName("."))
        #expect(!RunnerImageSelector.isValidName(".hidden"))
        #expect(!RunnerImageSelector.isValidName("a/b"))
        #expect(!RunnerImageSelector.isValidName("../etc/passwd"))
        #expect(!RunnerImageSelector.isValidName("Android"))
        #expect(!RunnerImageSelector.isValidName(String(repeating: "a", count: 65)))
    }

    // MARK: - Tagging

    /// Tags stay flat because a slash would be read as a registry path.
    ///
    /// Tagged `sapling/x/y`, an image is stored by Apple's `container` as
    /// `docker.io/sapling/x/y` — which breaks a prefix match when listing and
    /// makes a local build look like it came from Docker Hub.
    @Test("tags are flat, prefixed, and namespaced by repository")
    func tagFormat() {
        let ref = RunnerImageRef(
            name: "android",
            repo: "jameshuntnz/wayfairer-app",
            treeSHA: "a1b2c3d4e5f60718293a4b5c6d7e8f9012345678")

        #expect(!ref.tag.contains("/"))
        #expect(ref.tag.hasPrefix(RunnerImageRef.tagPrefix))
        #expect(ref.tag == "sapling-img-jameshuntnz-wayfairer-app-android:a1b2c3d4e5f6")
    }

    /// The tree SHA is the cache key, so two commits that leave the image
    /// directory untouched must resolve to the same tag — that is what makes
    /// an ordinary application commit a cache hit rather than a rebuild.
    @Test("the tag changes only when the image directory changes")
    func tagTracksTreeNotCommit() {
        let repo = "acme/widgets"
        let unchanged = RunnerImageRef(name: "ci", repo: repo, treeSHA: "aaaaaaaaaaaabbbb")
        let same = RunnerImageRef(name: "ci", repo: repo, treeSHA: "aaaaaaaaaaaabbbb")
        let edited = RunnerImageRef(name: "ci", repo: repo, treeSHA: "ccccccccccccdddd")

        #expect(unchanged.tag == same.tag)
        #expect(unchanged.tag != edited.tag)
    }

    @Test("two repositories may both define an image of the same name")
    func namespacedByRepo() {
        let a = RunnerImageRef(name: "android", repo: "acme/one", treeSHA: "abcdef123456")
        let b = RunnerImageRef(name: "android", repo: "acme/two", treeSHA: "abcdef123456")
        #expect(a.tag != b.tag)
    }

    // MARK: - Resolution

    /// A job that names no image is the common case and must not touch the
    /// network: it gets the node's configured default directly.
    @Test("no selector resolves to the node default without any lookup")
    func defaultWhenUnspecified() async throws {
        let config = LinuxConfig(defaultImage: "ghcr.io/actions/actions-runner:latest")
        let builder = RunnerImageBuilder(config: config, github: GitHubClient(config: GitHubConfig()))
        let resolved = try await builder.resolve(
            imageName: nil, repo: "acme/widgets", ref: "abc", events: SilentEventSink())
        #expect(resolved == "ghcr.io/actions/actions-runner:latest")
    }

    /// Falling back to the default here would run an Android build in a
    /// toolless image, and fail somewhere far from the cause.
    @Test("a node that won't build images refuses rather than silently falling back")
    func refusesWhenBuildingDisabled() async {
        let config = LinuxConfig(buildImages: false)
        let builder = RunnerImageBuilder(config: config, github: GitHubClient(config: GitHubConfig()))
        await #expect(throws: ProviderError.self) {
            _ = try await builder.resolve(
                imageName: "android", repo: "acme/widgets", ref: "abc", events: SilentEventSink())
        }
    }

    @Test("an unsafe selector is refused before anything is fetched")
    func refusesUnsafeSelector() async {
        let builder = RunnerImageBuilder(
            config: LinuxConfig(), github: GitHubClient(config: GitHubConfig()))
        await #expect(throws: ProviderError.self) {
            _ = try await builder.resolve(
                imageName: "../../etc", repo: "acme/widgets", ref: "abc",
                events: SilentEventSink())
        }
    }

    @Test("a job with no head_sha cannot be pinned to a commit, so it is refused")
    func refusesWithoutRef() async {
        let builder = RunnerImageBuilder(
            config: LinuxConfig(), github: GitHubClient(config: GitHubConfig()))
        await #expect(throws: ProviderError.self) {
            _ = try await builder.resolve(
                imageName: "android", repo: "acme/widgets", ref: nil, events: SilentEventSink())
        }
    }

    // MARK: - Config

    @Test("image settings round-trip through config, defaulting conservatively")
    func configRoundTrip() throws {
        let config = try ConfigFixture.decode(
            """
            [linux]
            rosetta = true
            build_images = false
            images_path = ".ci/images"
            """)
        #expect(config.linux.rosetta)
        #expect(!config.linux.buildImages)
        #expect(config.linux.imagesPath == ".ci/images")

        // Absent keys keep a node behaving exactly as it did before this
        // feature existed — no Rosetta, no forced architecture.
        let bare = try ConfigFixture.decode("[linux]\nenabled = true")
        #expect(bare.linux.buildImages)
        #expect(bare.linux.imagesPath == ".sapling/images")
        #expect(!bare.linux.rosetta)
        #expect(bare.linux.arch == nil)
    }
}

/// Discards events; resolution behaviour is what these tests are about.
struct SilentEventSink: EventSink {
    func log(_ text: String) async {}
    func record(_ event: String, detail: String?) async {}
}
