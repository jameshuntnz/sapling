import Foundation

/// Puts an executable where the root daemon will run it.
///
/// A copy made by root keeps the source's owner, and the source is a build
/// product or an archive member owned by whoever built it. Left that way, the
/// console user could rewrite the binary launchd next starts as root.
public enum BinaryInstall {
    /// Copies `source` to `target` as a root-owned 0755 regular file.
    ///
    /// Ownership is only changed when running as root, which every real
    /// install is; tests run unprivileged against temporary paths.
    ///
    /// - Throws: If `source` is not a regular file, or the copy fails.
    public static func copy(from source: String, to target: String) throws {
        let fileManager = FileManager.default
        let type = try fileManager.attributesOfItem(atPath: source)[.type] as? FileAttributeType
        guard type == .typeRegular else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSFilePathErrorKey: source])
        }
        try fileManager.copyItem(atPath: source, toPath: target)
        var attributes: [FileAttributeKey: Any] = [.posixPermissions: 0o755]
        if geteuid() == 0 {
            attributes[.ownerAccountID] = 0
            attributes[.groupOwnerAccountID] = 0
        }
        try fileManager.setAttributes(attributes, ofItemAtPath: target)
    }

    /// Takes back ownership of an installed binary that is not root's.
    ///
    /// The daemon runs this on start, because the release that brought this
    /// check was installed by a daemon that did not have it.
    ///
    /// - Parameter path: The installed binary.
    /// - Returns: Whether ownership was changed.
    @discardableResult
    public static func reclaim(_ path: String) -> Bool {
        let fileManager = FileManager.default
        guard geteuid() == 0, let attributes = try? fileManager.attributesOfItem(atPath: path),
            attributes[.type] as? FileAttributeType == .typeRegular,
            (attributes[.ownerAccountID] as? Int) != 0 || (attributes[.groupOwnerAccountID] as? Int) != 0
        else { return false }
        return
            (try? fileManager.setAttributes(
                [.ownerAccountID: 0, .groupOwnerAccountID: 0, .posixPermissions: 0o755], ofItemAtPath: path))
            != nil
    }
}
