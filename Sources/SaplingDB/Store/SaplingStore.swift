import Foundation
import GRDB
import SaplingCore
import Security

/// The control plane's storage.
///
/// One SQLite file, no external dependencies. Everything the API serves
/// is read from here; nothing inspects live processes, which is what
/// makes crash recovery tractable.
public final class SaplingStore: Sendable {
    /// Keys for the small daemon-state table.
    public enum StateKey {
        /// When GitHub was last polled successfully.
        public static let lastPollAt = "last_poll_at"
        /// Why the last poll failed, if it did.
        public static let lastPollError = "last_poll_error"
        /// Repositories currently being polled, as a JSON array.
        ///
        /// Written by the agent because the list may be discovered from the
        /// App installation rather than configured; the control plane reads it
        /// so `status` reports what is actually watched, not what was asked
        /// for.
        public static let watchedRepos = "watched_repos"
    }

    let writer: any DatabaseWriter

    /// Opens the database, creating and migrating it if needed.
    public init(path: URL) throws {
        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        var config = Configuration()
        config.foreignKeysEnabled = true
        config.prepareDatabase { db in
            // WAL plus a busy timeout: the API server reads while the agent
            // writes, and without this a concurrent read returns SQLITE_BUSY
            // instead of waiting.
            try db.execute(sql: "PRAGMA busy_timeout = 5000")
        }
        let pool = try DatabasePool(path: path.path, configuration: config)
        writer = pool
        try SaplingMigrations.migrator.migrate(pool)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
    }

    /// In-memory store for tests.
    public init(inMemoryNamed name: String = UUID().uuidString) throws {
        var config = Configuration()
        config.foreignKeysEnabled = true
        let queue = try DatabaseQueue(named: name, configuration: config)
        writer = queue
        try SaplingMigrations.migrator.migrate(queue)
    }
}
