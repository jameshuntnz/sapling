import Foundation
import Testing

@testable import SaplingCore

extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}

/// Runs `body` with `SAPLING_HOME` pointed at a fresh scratch directory, then
/// restores whatever was there before.
///
/// The environment is process-wide, so every suite that uses this must sit
/// under a `.serialized` parent or they will trample each other.
enum TemporaryHome {
    static func run<T>(_ body: (URL) async throws -> T) async rethrows -> T {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("sapling-test-\(UUID().uuidString)")
        let previous = ProcessInfo.processInfo.environment["SAPLING_HOME"]
        setenv("SAPLING_HOME", home.path, 1)
        defer {
            if let previous {
                setenv("SAPLING_HOME", previous, 1)
            } else {
                unsetenv("SAPLING_HOME")
            }
            try? FileManager.default.removeItem(at: home)
        }
        return try await body(home)
    }
}

/// Scratch directory that cleans itself up, for tests that need files but not
/// a whole Sapling home.
struct TemporaryDirectory: ~Copyable {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sapling-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func appending(_ component: String) -> URL {
        url.appendingPathComponent(component)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }
}

/// Parse config TOML through the real loader, which is the only path the
/// daemon ever uses.
enum ConfigFixture {
    static func decode(_ toml: String) throws -> SaplingConfig {
        let directory = try TemporaryDirectory()
        let url = directory.appending("config.toml")
        try toml.write(to: url, atomically: true, encoding: .utf8)
        return try SaplingConfig.load(from: url)
    }
}
