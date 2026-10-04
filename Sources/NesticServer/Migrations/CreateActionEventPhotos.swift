import Fluent

struct CreateActionEventPhotos: AsyncMigration {
    func prepare(on db: any Database) async throws {
        try await db.schema(ActionEventPhoto.schema)
            .id()
            .field("event_id", .uuid, .required, .references("action_events", "id", onDelete: .cascade))
            .field("actor_user_id", .uuid, .references("users", "id", onDelete: .setNull))
            .field("captured_at", .datetime, .required)
            .field("photo_url", .string, .required)
            .field("created_at", .datetime)
            .create()
    }

    func revert(on db: any Database) async throws {
        try await db.schema(ActionEventPhoto.schema).delete()
    }
}
