import Foundation
import GRDB
import SaplingCore

extension SaplingStore {
    /// Stores a daemon-state value, or clears it when passed `nil`.
    public func setState(_ key: String, _ value: String?) async throws {
        try await writer.write { db in
            if let value {
                try StateRecord(key: key, value: value, updatedAt: Date()).save(db)
            } else {
                try db.execute(sql: "DELETE FROM daemon_state WHERE key = ?", arguments: [key])
            }
        }
    }

    /// Reads a daemon-state value.
    public func state(_ key: String) async throws -> String? {
        try await writer.read { db in
            try StateRecord.fetchOne(db, key: key)?.value
        }
    }
}
