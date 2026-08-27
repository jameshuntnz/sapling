import Foundation
import GRDB

enum SaplingMigrations {
    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1_initial") { db in
            try db.create(table: "nodes") { t in
                t.column("id", .text).primaryKey()
                t.column("name", .text).notNull()
                t.column("platform", .text).notNull()
                t.column("last_seen_at", .datetime)
                t.column("status", .text).notNull()
            }

            try db.create(table: "jobs") { t in
                t.column("id", .text).primaryKey()
                t.column("node_id", .text).references("nodes", onDelete: .setNull)
                t.column("repo", .text).notNull()
                t.column("workflow_run_id", .text)
                t.column("platform", .text).notNull()
                t.column("labels", .text).notNull()
                t.column("status", .text).notNull()
                t.column("name", .text)
                t.column("queued_at", .datetime)
                t.column("started_at", .datetime)
                t.column("completed_at", .datetime)
                t.column("exit_reason", .text)
                t.column("updated_at", .datetime).notNull()
            }
            // The job list is always "most recent first, optionally filtered
            // by status" — this is the only index that query needs.
            try db.create(index: "idx_jobs_status_updated", on: "jobs", columns: ["status", "updated_at"])
            try db.create(index: "idx_jobs_updated", on: "jobs", columns: ["updated_at"])

            try db.create(table: "runs") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("job_id", .text).notNull().references("jobs", onDelete: .cascade)
                t.column("ts", .datetime).notNull()
                t.column("event", .text).notNull()
                t.column("detail", .text)
            }
            try db.create(index: "idx_runs_job_id", on: "runs", columns: ["job_id", "id"])

            try db.create(table: "join_tokens") { t in
                t.column("token", .text).primaryKey()
                t.column("created_at", .datetime).notNull()
                t.column("expires_at", .datetime).notNull()
                t.column("used_at", .datetime)
            }

            try db.create(table: "daemon_state") { t in
                t.column("key", .text).primaryKey()
                t.column("value", .text).notNull()
                t.column("updated_at", .datetime).notNull()
            }
        }

        // Additive and nullable, so an existing database keeps every row and
        // a job that predates repository-defined images simply has no image
        // recorded — which is the truth about it.
        migrator.registerMigration("v2_job_image_ref") { db in
            try db.alter(table: "jobs") { t in
                t.add(column: "image_ref", .text)
            }
        }

        // Requeueing had no ceiling: a job GitHub keeps reporting as queued
        // was retried every cooldown forever, so a permanently broken base
        // image meant an endless clone-boot-fail loop rather than a job that
        // gives up and says why.
        migrator.registerMigration("v3_job_attempts") { db in
            try db.alter(table: "jobs") { t in
                t.add(column: "attempts", .integer).notNull().defaults(to: 0)
            }
        }

        return migrator
    }
}
