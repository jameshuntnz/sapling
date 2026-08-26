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
            try JoinTokenRecord(token).insert(db)
        }
        return token
    }

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
