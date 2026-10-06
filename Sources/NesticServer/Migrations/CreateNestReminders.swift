import Fluent

struct CreateNestReminders: AsyncMigration {
    func prepare(on db: any Database) async throws {
        try await db.schema("nest_reminders")
            .id()
            .field("nest_id", .uuid, .required, .references("nests", "id", onDelete: .cascade))
            .field("subject_id", .uuid, .required)
            .field("subject_name", .string, .required)
            .field("tracker_id", .uuid, .required)
            .field("tracker_name", .string, .required)
            .field("cadence", .string, .required)
            .field("linked_tracker_id", .uuid)
            .field("linked_tracker_name", .string)
            .field("delay_minutes", .int, .required)
            .field("anchor_date", .datetime, .required)
            .field("hour", .int, .required)
            .field("minute", .int, .required)
            .field("created_by_user_id", .uuid, .required)
            .field("created_by_name", .string, .required)
            .field("created_at", .datetime)
            .field("updated_at", .datetime)
            .create()
    }

    func revert(on db: any Database) async throws {
        try await db.schema("nest_reminders").delete()
    }
}
