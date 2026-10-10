import Foundation
import SaplingCore

/// Fetching a job's image before the container starts.
extension ContainerProvider {
    /// Pulls `image` unless this node built it.
    ///
    /// A built image exists only locally, so pulling it asked Docker Hub for a
    /// name it has never heard of and failed with a 401, ~2s into every job.
    func pullIfRemote(_ image: String, events: any EventSink) async throws {
        guard !image.hasPrefix(RunnerImageRef.tagPrefix) else { return }
        await events.log("pulling \(image)")
        // Three things this call has to get right, each of which failed
        // silently before because a pull failure is treated as non-fatal:
        //   `image`, not `images` — the latter resolves no plugin at all;
        //   through SessionCommand, since as root the apiserver is unreachable;
        //   and pinned to one architecture, or `container` fetches every
        //   platform in the manifest list (riscv64 and s390x included).
        let pullCommand = try await SessionCommand.invocation(
            "container",
            ["image", "pull", "--arch", config.arch ?? Self.hostArch, image])
        let pull = try await ProcessRunner.run(
            pullCommand.executable, pullCommand.arguments, timeout: .seconds(1800))
        if !pull.succeeded {
            // A pull failure is not fatal on its own — the image may already
            // be present locally from a previous job.
            await events.log(
                "image pull reported: \(pull.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
    }
}
