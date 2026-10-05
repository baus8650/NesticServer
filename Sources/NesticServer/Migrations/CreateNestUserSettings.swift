import Fluent

struct CreateNestUserSettings: AsyncMigration {
    func prepare(on db: any Database) async throws {
        try await db.schema("nest_user_settings")
            .id()
            .field("nest_id", .uuid, .required, .references("nests", "id", onDelete: .cascade))
            .field("user_id", .uuid, .required, .references("users", "id", onDelete: .cascade))
            .field("prediction_preferences_json", .text)
            .field("quiet_hours_json", .text)
            .field("reminders_json", .text)
            .field("updated_at", .datetime)
            .unique(on: "nest_id", "user_id")
            .create()
    }

    func revert(on db: any Database) async throws {
        try await db.schema("nest_user_settings").delete()
    }
}
