import Foundation
import GRDB
import SaplingCore
import Security

extension SaplingStore {
    /// Issues a single-use enrollment token.
    ///
    /// - Parameter ttl: How long the token stays valid, in seconds.
    /// - Returns: The newly issued token.
    /// - Throws: If the token cannot be written.
    public func createJoinToken(ttl: TimeInterval = 3600) async throws -> JoinToken {
        let token = JoinToken(
            token: Self.randomToken(),
            createdAt: Date(),
            expiresAt: Date().addingTimeInterval(ttl)
        )
        try await writer.write { db in
            // The endpoint has no auth, so an expired token is dropped and the
            // live ones are capped rather than left to pile up.
            try db.execute(
                sql: "DELETE FROM join_tokens WHERE expires_at < ? OR used_at IS NOT NULL",
                arguments: [Date()])
            try db.execute(
                sql: """
                    DELETE FROM join_tokens WHERE token IN (
                      SELECT token FROM join_tokens ORDER BY created_at DESC, rowid DESC LIMIT -1 OFFSET ?)
                    """, arguments: [Self.maxOutstandingJoinTokens - 1])
            try JoinTokenRecord(token).insert(db)
        }
        return token
    }

    /// How many unused tokens may be outstanding at once.
    static let maxOutstandingJoinTokens = 20

    /// Marks a token used and reports whether it was valid.
    ///
    /// Single-use by design — a leaked enrollment token shouldn't stay useful.
    public func consumeJoinToken(_ raw: String) async throws -> Bool {
        try await writer.write { db in
            guard var record = try JoinTokenRecord.fetchOne(db, key: raw) else { return false }
            guard record.usedAt == nil, record.expiresAt > Date() else { return false }
            record.usedAt = Date()
            try record.update(db)
            return true
        }
    }

    static func randomToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}
