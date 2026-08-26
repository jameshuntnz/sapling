import Foundation
import SaplingCore

/// VM cleanup for callers outside the agent.
///
/// `sapling uninstall --purge` has to remove the VMs Sapling created, but the
/// installer has no business knowing which provider made them or how one is
/// constructed — this is the whole surface it needs.
public enum VMMaintenance {
    /// Delete every VM Sapling created, returning the names it removed.
    ///
    /// Safe to call when Tart isn't installed: there is nothing to remove in
    /// that case, and it reports an empty list rather than failing.
    ///
    /// - Parameters:
    ///   - config: Supplies the base image name.
    ///   - includingBaseImage: Also delete the base image. Only `uninstall
    ///     --purge` should pass true — the running daemon must never remove
    ///     the image every macOS job is cloned from.
    /// - Returns: The names of the VMs removed.
    public static func removeSaplingVMs(
        config: MacOSConfig,
        includingBaseImage: Bool = false
    ) async -> [String] {
        guard ProcessRunner.which("tart") != nil else { return [] }
        var removed = await TartProvider(config: config).reapOrphans()
        guard includingBaseImage else { return removed }

        let base = config.baseImage
        if let command = try? await TartProvider.tart(["get", base]),
            let exists = try? await ProcessRunner.run(command.executable, command.arguments),
            exists.succeeded
        {
            await TartProvider.forceTeardown(vmName: base)
            removed.append(base)
        }
        return removed
    }
}
