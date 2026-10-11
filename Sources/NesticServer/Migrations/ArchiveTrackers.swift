import Fluent
import SQLKit
import Vapor
struct ArchiveTrackers: AsyncMigration {
    func prepare(on db: any Database) async throws {
        try await db.schema("trackable_actions").field("is_archived", .bool).update()
        if let sql = db as? any SQLDatabase {
            try await sql.raw("DROP INDEX IF EXISTS tracker_shared_name").run()
            try await sql.raw("DROP INDEX IF EXISTS tracker_private_name").run()
            try await sql.raw("CREATE UNIQUE INDEX tracker_shared_name ON trackable_actions (nest_id, name) WHERE private_owner_id IS NULL AND is_archived IS NOT TRUE").run()
            try await sql.raw("CREATE UNIQUE INDEX tracker_private_name ON trackable_actions (nest_id, private_owner_id, name) WHERE private_owner_id IS NOT NULL AND is_archived IS NOT TRUE").run()
        }
    }
    func revert(on db: any Database) async throws {
        guard try await TrackableAction.query(on: db).filter(\.$isArchived == true).count() == 0 else { throw Abort(.conflict, reason: "Archived history must be retained; this migration cannot be reverted while archived trackers exist.") }
        if let sql = db as? any SQLDatabase {
            try await sql.raw("DROP INDEX IF EXISTS tracker_shared_name").run()
            try await sql.raw("DROP INDEX IF EXISTS tracker_private_name").run()
            try await sql.raw("CREATE UNIQUE INDEX tracker_shared_name ON trackable_actions (nest_id, name) WHERE private_owner_id IS NULL").run()
            try await sql.raw("CREATE UNIQUE INDEX tracker_private_name ON trackable_actions (nest_id, private_owner_id, name) WHERE private_owner_id IS NOT NULL").run()
        }
        try await db.schema("trackable_actions").deleteField("is_archived").update()
    }
}
