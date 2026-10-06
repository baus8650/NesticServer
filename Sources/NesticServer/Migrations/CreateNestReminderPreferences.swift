import Fluent

struct CreateNestReminderPreferences: AsyncMigration {
    func prepare(on db: any Database) async throws {
        try await db.schema("nest_reminder_preferences")
            .id()
            .field("reminder_id", .uuid, .required, .references("nest_reminders", "id", onDelete: .cascade))
            .field("user_id", .uuid, .required, .references("users", "id", onDelete: .cascade))
            .field("enabled", .bool, .required)
            .field("updated_at", .datetime)
            .unique(on: "reminder_id", "user_id")
            .create()
    }

    func revert(on db: any Database) async throws {
        try await db.schema("nest_reminder_preferences").delete()
    }
}
