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
    public static func removeSaplingVMs(config: MacOSConfig) async -> [String] {
        guard ProcessRunner.which("tart") != nil else { return [] }
        return await TartProvider(config: config).reapOrphans()
    }
}
