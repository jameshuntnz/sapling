import CryptoKit
import Foundation

extension CacheProxy {
    /// Hash the path so arbitrarily deep module paths can't blow past the
    /// filesystem's name limits, and keep a readable suffix for debugging.
    ///
    /// Every job on the node shares these entries, and immutable ones are
    /// served forever, so the hash must resist a job crafting a collision
    /// with a package another repository depends on.
    static func cacheKey(upstream: String, path: String) -> String {
        let hash = SHA256.hash(data: Data(path.utf8)).map { String(format: "%02x", $0) }.joined()
        let readable =
            path
            .split(separator: "/")
            .suffix(2)
            .joined(separator: "_")
            .filter { $0.isLetter || $0.isNumber || $0 == "." || $0 == "_" || $0 == "-" }
            .suffix(60)
        return hash + "_" + readable
    }
}
