import Foundation
import SaplingCore

/// Reading a repository's own files, for images the repository defines.
extension GitHubClient {
    /// Tree SHA of one directory at a commit, or `nil` if it isn't there.
    ///
    /// This is the whole fast path for repository-defined images: git already
    /// hashes a directory's exact contents, so one call answers "has this
    /// image definition changed" without fetching a byte of it. A cache hit
    /// costs exactly this request.
    func directoryTreeSHA(repo: String, path: String, ref: String) async throws -> String? {
        let parent = (path as NSString).deletingLastPathComponent
        let name = (path as NSString).lastPathComponent
        let encoded =
            parent.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? parent
        let entries: [ContentEntry]
        do {
            entries = try await request(
                "GET", "/repos/\(repo)/contents/\(encoded)?ref=\(ref)", as: [ContentEntry].self)
        } catch let error as GitHubError where error.statusCode == 404 {
            return nil
        }
        return entries.first { $0.name == name && $0.type == "dir" }?.sha
    }

    /// Every file in a tree, as path/bytes pairs.
    ///
    /// Only called on a cache miss. Symlinks and submodules are skipped rather
    /// than followed — a build context is files, and following either would
    /// reach outside the directory the workflow named.
    func treeFiles(repo: String, treeSHA: String) async throws -> [(path: String, data: Data)] {
        let tree = try await request(
            "GET", "/repos/\(repo)/git/trees/\(treeSHA)?recursive=1", as: GitTreeResponse.self)
        if tree.truncated == true {
            throw ProviderError(
                "image directory is too large for one tree response; keep build contexts small")
        }

        var files: [(path: String, data: Data)] = []
        for entry in tree.tree where entry.type == "blob" {
            // 120000 is a symlink; anything else non-regular is skipped too.
            guard entry.mode == "100644" || entry.mode == "100755" else { continue }
            let blob = try await request(
                "GET", "/repos/\(repo)/git/blobs/\(entry.sha)", as: GitBlobResponse.self)
            guard blob.encoding == "base64",
                let data = Data(base64Encoded: blob.content, options: .ignoreUnknownCharacters)
            else {
                throw ProviderError("unexpected blob encoding \(blob.encoding) for \(entry.path)")
            }
            files.append((entry.path, data))
        }
        return files
    }
}
