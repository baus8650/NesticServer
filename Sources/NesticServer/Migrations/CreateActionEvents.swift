import Fluent
import SQLKit

struct CreateActionEvents: AsyncMigration {
    func prepare(on db: any Database) async throws {
        try await db.schema("action_events")
            .id()
            .field("nest_id", .uuid, .required, .references("nests", "id", onDelete: .cascade))
            .field("entity_id", .uuid, .required, .references("entities", "id", onDelete: .cascade))
            .field("action_id", .uuid, .required, .references("trackable_actions", "id", onDelete: .restrict))
            .field("actor_user_id", .uuid, .references("users", "id", onDelete: .setNull))
            .field("occurred_at", .datetime, .required)
            .field("value_number", .double)
            .field("value_text", .string)
            .field("value_bool", .bool)
            .field("value_json", .json)
            .field("note", .string)
            .field("created_at", .datetime)
            .create()

        let sql = db as! any SQLDatabase

        try await sql.create(index: "idx_action_events_nest_id")
            .on("action_events")
            .column("nest_id")
            .run()

        try await sql.create(index: "idx_action_events_entity_id")
            .on("action_events")
            .column("entity_id")
            .run()

        try await sql.create(index: "idx_action_events_action_id")
            .on("action_events")
            .column("action_id")
            .run()

        try await sql.create(index: "idx_action_events_occurred_at")
            .on("action_events")
            .column("occurred_at")
            .run()
    }

    func revert(on db: any Database) async throws {
        let sql = db as! any SQLDatabase

        // Postgres doesn't require `.on("action_events")` for drop, per the blog.
        try await sql.drop(index: "idx_action_events_nest_id").run()
        try await sql.drop(index: "idx_action_events_entity_id").run()
        try await sql.drop(index: "idx_action_events_action_id").run()
        try await sql.drop(index: "idx_action_events_occurred_at").run()

        try await db.schema("action_events").delete()
    }
}
