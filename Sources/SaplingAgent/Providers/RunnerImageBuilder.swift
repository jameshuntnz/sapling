import Foundation
import SaplingCore

/// Builds the container images a repository defines for its own jobs.
///
/// A repository keeps one directory per image — `.sapling/images/<name>/` —
/// and a job asks for one with an `image:<name>` label. The node reads that
/// directory at the job's own commit, builds it, and runs the job in it. No
/// registry is involved, and nothing has to be published before a workflow
/// change can take effect.
///
/// The cache key is the directory's **git tree SHA**. That is not an
/// optimisation detail — it is what makes this correct without a registry:
/// git hashes the directory's exact contents, so the tag changes when and only
/// when the image definition changes, and a commit that touches only
/// application code resolves to a tag that already exists.
struct RunnerImageBuilder: Sendable {
    let config: LinuxConfig
    let github: GitHubClient

    /// How long a single image build may run before it is abandoned.
    ///
    /// Generous because a first Android build pulls a JDK and the SDK; a build
    /// that overruns this is stuck, not slow.
    static let buildTimeout: Duration = .seconds(3600)

    init(config: LinuxConfig, github: GitHubClient) {
        self.config = config
        self.github = github
    }

    /// Resolves the image a job should run in.
    ///
    /// Returns the node's configured default when the job named no image,
    /// which is the common case. Throws rather than silently falling back when
    /// a job *did* name one and it could not be produced — running an Android
    /// build in a toolless image fails much further from the cause.
    func resolve(
        imageName: String?,
        repo: String,
        ref: String?,
        events: any EventSink
    ) async throws -> String {
        guard let imageName else { return config.defaultImage }

        guard RunnerImageSelector.isValidName(imageName) else {
            throw ProviderError(
                "invalid image selector \"\(imageName)\": use lowercase letters, digits, "
                    + "'-', '_' or '.'")
        }
        guard config.buildImages else {
            throw ProviderError(
                "job asked for image \"\(imageName)\" but this node has build_images = false")
        }
        guard let ref else {
            throw ProviderError(
                "job asked for image \"\(imageName)\" but GitHub reported no head_sha for it")
        }

        let directory = "\(config.imagesPath)/\(imageName)"
        guard
            let treeSHA = try await github.directoryTreeSHA(
                repo: repo, path: directory, ref: ref)
        else {
            throw ProviderError(
                "job asked for image \"\(imageName)\" but \(repo) has no \(directory)/ at "
                    + String(ref.prefix(7)))
        }

        let image = RunnerImageRef(name: imageName, repo: repo, treeSHA: treeSHA)
        if await Self.imageExists(tag: image.tag) {
            await events.log("image \(imageName) is current (\(image.tag))")
            return image.tag
        }

        await events.record(RunEventName.imageBuildStarted, detail: image.tag)
        do {
            try await build(image: image, directory: directory, events: events)
        } catch {
            await events.record(RunEventName.imageBuildFailed, detail: error.localizedDescription)
            throw error
        }
        await events.record(RunEventName.imageBuildFinished, detail: image.tag)
        return image.tag
    }

    // MARK: - Building

    private func build(
        image: RunnerImageRef, directory: String, events: any EventSink
    ) async throws {
        let context = FileManager.default.temporaryDirectory
            .appendingPathComponent("sapling-build-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: context, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: context) }

        let files = try await github.treeFiles(repo: image.repo, treeSHA: image.treeSHA)
        guard files.contains(where: { $0.path == "Dockerfile" }) else {
            throw ProviderError("\(directory)/ has no Dockerfile")
        }

        for file in files {
            // The tree is rooted at the image directory, so every path is
            // already relative to it — but a `..` component would still escape
            // the context, so refuse rather than normalise.
            guard !file.path.split(separator: "/").contains("..") else {
                throw ProviderError("refusing path outside the build context: \(file.path)")
            }
            let destination = context.appendingPathComponent(file.path)
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try file.data.write(to: destination)
        }

        await events.log("building \(image.tag) from \(directory)/ (\(files.count) files)")

        var arguments = ["build", "--tag", image.tag]
        arguments += ["--arch", config.arch ?? ContainerProvider.hostArch]
        arguments += ["--file", context.appendingPathComponent("Dockerfile").path]
        arguments.append(context.path)

        let command = try await SessionCommand.invocation("container", arguments)
        var tail: [String] = []
        var status: Int32 = -1
        for try await chunk in ProcessRunner.stream(command.executable, command.arguments) {
            switch chunk {
            case .stdout(let text), .stderr(let text):
                await events.log(text)
                // Kept so a failure can say what actually went wrong instead
                // of only reporting an exit code.
                tail.append(text)
                if tail.count > 20 { tail.removeFirst() }
            case .exit(let code):
                status = code
            }
        }

        guard status == 0 else {
            let detail = tail.joined().trimmingCharacters(in: .whitespacesAndNewlines)
            throw ProviderError(
                "building \(image.tag) failed with status \(status)"
                    + (detail.isEmpty ? "" : ": \(detail)"))
        }
    }

    /// Whether a tag is already present on this node.
    static func imageExists(tag: String) async -> Bool {
        guard let command = try? await SessionCommand.invocation("container", ["image", "inspect", tag])
        else { return false }
        let result = try? await ProcessRunner.run(
            command.executable, command.arguments, timeout: .seconds(30))
        return result?.succeeded ?? false
    }

    /// Tags this node built, newest first, for housekeeping to consider.
    static func builtImageTags() async -> [String] {
        guard
            let command = try? await SessionCommand.invocation(
                "container", ["image", "list", "--format", "json"]),
            let result = try? await ProcessRunner.run(
                command.executable, command.arguments, timeout: .seconds(60)),
            result.succeeded,
            let data = result.stdout.data(using: .utf8),
            let entries = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return [] }

        // `container image list --format json` reports one fully-qualified
        // reference per image under configuration.name, not separate name and
        // tag fields.
        return entries.compactMap { entry in
            guard let configuration = entry["configuration"] as? [String: Any],
                let reference = configuration["name"] as? String
            else { return nil }
            let bare =
                reference.hasPrefix("docker.io/")
                ? String(reference.dropFirst("docker.io/".count)) : reference
            return bare.hasPrefix(RunnerImageRef.tagPrefix) ? bare : nil
        }
    }

    /// Removes a built image.
    static func remove(tag: String) async {
        guard let command = try? await SessionCommand.invocation("container", ["image", "delete", tag])
        else { return }
        _ = try? await ProcessRunner.run(
            command.executable, command.arguments, timeout: .seconds(120))
    }
}
