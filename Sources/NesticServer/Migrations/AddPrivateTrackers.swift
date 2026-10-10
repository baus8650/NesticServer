import Fluent
import SQLKit
import Vapor

struct AddPrivateTrackers: AsyncMigration {
    func prepare(on db: any Database) async throws {
        try await db.schema(TrackableAction.schema)
            .field("private_owner_id", .uuid, .references("users", "id", onDelete: .cascade))
            .deleteUnique(on: "nest_id", "name")
            .update()
        if let sql = db as? any SQLDatabase {
            try await sql.raw("CREATE UNIQUE INDEX tracker_shared_name ON trackable_actions (nest_id, name) WHERE private_owner_id IS NULL").run()
            try await sql.raw("CREATE UNIQUE INDEX tracker_private_name ON trackable_actions (nest_id, private_owner_id, name) WHERE private_owner_id IS NOT NULL").run()
        }
    }
    func revert(on db: any Database) async throws {
        guard try await TrackableAction.query(on: db).filter(\.$privateOwnerId != nil).count() == 0 else {
            throw Abort(.conflict, reason: "Remove private trackers before reverting this migration; reverting must never publish private data.")
        }
        if let sql = db as? any SQLDatabase {
            try await sql.raw("DROP INDEX IF EXISTS tracker_shared_name").run()
            try await sql.raw("DROP INDEX IF EXISTS tracker_private_name").run()
        }
        try await db.schema(TrackableAction.schema).deleteField("private_owner_id").unique(on: "nest_id", "name").update()
    }
}
