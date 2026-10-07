import Foundation
import SaplingCore

/// Which built images housekeeping keeps.
///
/// Each edit to an image's directory gives it a new tag, and each tag unpacks
/// to a few GB, so keeping everything recently used filled the node within a
/// day of branch builds.
enum BuiltImageRetention {
    /// Tags kept per image: the default branch's and one other branch's.
    static let keptPerImage = 2

    /// The built tags to delete.
    ///
    /// - Parameters:
    ///   - built: Tags present on the node.
    ///   - recentRefs: Images recent jobs ran in, most recent job first.
    ///   - active: Images jobs holding a slot are using; never removed.
    /// - Returns: Every built tag outside the newest `keptPerImage` of its
    ///   image, and not in use.
    static func removable(built: [String], recentRefs: [String], active: Set<String>) -> [String] {
        let present = Set(built)
        var kept = active
        var keptCount: [String: Int] = [:]
        for ref in recentRefs where present.contains(ref) && !kept.contains(ref) {
            let image = repository(of: ref)
            guard keptCount[image, default: 0] < keptPerImage else { continue }
            keptCount[image, default: 0] += 1
            kept.insert(ref)
        }
        return built.filter { !kept.contains($0) }
    }

    /// The tag without its `:<tree sha>` suffix.
    static func repository(of tag: String) -> String {
        guard let colon = tag.lastIndex(of: ":") else { return tag }
        return String(tag[..<colon])
    }
}
