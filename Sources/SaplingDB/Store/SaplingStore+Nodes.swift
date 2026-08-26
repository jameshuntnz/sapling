import Foundation
import GRDB
import SaplingCore

extension SaplingStore {
    /// Inserts a node, or updates it if the id already exists.
    public func upsertNode(_ node: Node) async throws {
        try await writer.write { db in
            try NodeRecord(node).save(db)
        }
    }

    /// Fetches one node, or `nil` if it isn't known.
    public func node(id: String) async throws -> Node? {
        try await writer.read { db in
            try NodeRecord.fetchOne(db, key: id)?.model
        }
    }

    /// Every known node, ordered by name.
    public func allNodes() async throws -> [Node] {
        try await writer.read { db in
            try NodeRecord.order(Column("name")).fetchAll(db).map(\.model)
        }
    }

    /// Changes a node's availability.
    public func setNodeStatus(id: String, status: NodeStatus) async throws {
        try await writer.write { db in
            try db.execute(
                sql: "UPDATE nodes SET status = ? WHERE id = ?",
                arguments: [status.rawValue, id]
            )
        }
    }

    /// Records that the node just checked in.
    public func touchNode(id: String) async throws {
        try await writer.write { db in
            try db.execute(
                sql: "UPDATE nodes SET last_seen_at = ? WHERE id = ?",
                arguments: [Date(), id]
            )
        }
    }
}
