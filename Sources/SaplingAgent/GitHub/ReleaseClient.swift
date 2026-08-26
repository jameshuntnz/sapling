import Foundation
import SaplingCore

/// A published release, as GitHub reports it.
struct GitHubRelease: Decodable, Sendable {
    let tagName: String
    let name: String?
    let prerelease: Bool
    let draft: Bool
    let publishedAt: Date?
    let assets: [GitHubReleaseAsset]

    /// The version this release publishes, or `nil` if the tag isn't a version.
    var version: SemanticVersion? { SemanticVersion(tagName) }
}

struct GitHubReleaseAsset: Decodable, Sendable {
    let id: Int64
    let name: String
    let size: Int
}

/// An update that is available to install.
public struct AvailableUpdate: Codable, Sendable {
    /// Version being offered.
    public var version: String
    /// The release's tag.
    public var tag: String
    /// Which channel it came from.
    public var channel: ReleaseChannel
    /// When it was published.
    public var publishedAt: Date?
    /// Size of the binary archive, in bytes.
    public var size: Int

    /// Creates a description of an available update.
    public init(version: String, tag: String, channel: ReleaseChannel, publishedAt: Date?, size: Int) {
        self.version = version
        self.tag = tag
        self.channel = channel
        self.publishedAt = publishedAt
        self.size = size
    }
}

/// Reads Sapling's own releases from GitHub.
///
/// Uses the same credentials as job polling. The repository is private, so
/// even listing releases needs authentication — and downloading an asset needs
/// `Contents: Read-only` on the App, which job polling does not require.
actor ReleaseClient {
    private let config: SaplingConfig
    private let tokens: GitHubTokenProvider
    private let session: URLSession

    init(config: SaplingConfig) {
        self.config = config
        self.tokens = GitHubTokenProvider(config: config.github)
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.timeoutIntervalForRequest = 30
        // A release archive is tens of megabytes over a home connection.
        sessionConfig.timeoutIntervalForResource = 900
        self.session = URLSession(configuration: sessionConfig)
    }

    /// The newest release this node should install, or `nil` if it is current.
    ///
    /// - Parameter current: The version running now.
    /// - Returns: The update to install, or `nil` when nothing newer exists on
    ///   the configured channel.
    /// - Throws: `GitHubError` if the releases cannot be read.
    func latestUpdate(newerThan current: SemanticVersion) async throws -> AvailableUpdate? {
        let wanted = config.update.channel
        let candidates = try await releases()
            .filter { !$0.draft }
            .compactMap { release -> (GitHubRelease, SemanticVersion)? in
                guard let version = release.version else { return nil }
                // The channel comes from the version itself, so a release
                // mismarked in GitHub's UI can't put a dev build on a stable
                // node.
                guard wanted.accepts(version.channel) else { return nil }
                guard version > current else { return nil }
                return (release, version)
            }
            .sorted { $0.1 < $1.1 }

        guard let (release, version) = candidates.last else { return nil }
        guard let asset = binaryAsset(in: release) else { return nil }

        return AvailableUpdate(
            version: version.description,
            tag: release.tagName,
            channel: version.channel,
            publishedAt: release.publishedAt,
            size: asset.size)
    }

    /// Download a release's binary archive and its checksums.
    ///
    /// - Parameter tag: The release tag to fetch.
    /// - Returns: Local paths to the archive and the `SHA256SUMS` file.
    /// - Throws: `GitHubError` if either asset is missing or cannot be fetched.
    func download(tag: String) async throws -> (archive: URL, checksums: URL) {
        guard let release = try await releases().first(where: { $0.tagName == tag }) else {
            throw GitHubError(statusCode: 404, message: "no release tagged \(tag)")
        }
        guard let archive = binaryAsset(in: release) else {
            throw GitHubError(statusCode: 404, message: "release \(tag) has no macOS arm64 archive")
        }
        guard let checksums = release.assets.first(where: { $0.name == "SHA256SUMS" }) else {
            // Refusing here is the point: an unverifiable download must not be
            // installed, and a release without checksums cannot be verified.
            throw GitHubError(
                statusCode: 404,
                message: "release \(tag) publishes no SHA256SUMS, so it cannot be verified")
        }
        return (
            archive: try await downloadAsset(archive, named: archive.name),
            checksums: try await downloadAsset(checksums, named: "SHA256SUMS")
        )
    }

    /// The macOS arm64 archive within a release.
    nonisolated func binaryAsset(in release: GitHubRelease) -> GitHubReleaseAsset? {
        release.assets.first { $0.name.hasSuffix("-macos-arm64.tar.gz") }
    }

    // MARK: - Transport

    private func releases() async throws -> [GitHubRelease] {
        let data = try await get(
            "\(config.github.apiBaseURL)/repos/\(config.update.repository)/releases?per_page=30",
            accept: "application/vnd.github+json")
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([GitHubRelease].self, from: data)
    }

    private func downloadAsset(_ asset: GitHubReleaseAsset, named name: String) async throws -> URL {
        // The octet-stream Accept header is what makes this return the asset
        // rather than its JSON metadata.
        let data = try await get(
            "\(config.github.apiBaseURL)/repos/\(config.update.repository)/releases/assets/\(asset.id)",
            accept: "application/octet-stream")

        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("sapling-update-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let file = destination.appendingPathComponent(name)
        try data.write(to: file)
        return file
    }

    private func get(_ urlString: String, accept: String) async throws -> Data {
        guard let url = URL(string: urlString) else {
            throw GitHubError(statusCode: -1, message: "bad URL: \(urlString)")
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(try await tokens.token())", forHTTPHeaderField: "Authorization")
        request.setValue(accept, forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("sapling/\(SaplingVersion.current)", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw GitHubError(statusCode: -1, message: "no HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            var message = String(decoding: data, as: UTF8.self).prefix(300).description
            if http.statusCode == 404 {
                // The likeliest cause by far, and invisible otherwise.
                message +=
                    " — if the repository is private, the GitHub App also needs "
                    + "`Contents: Read-only` to read releases."
            }
            throw GitHubError(statusCode: http.statusCode, message: message)
        }
        return data
    }
}
