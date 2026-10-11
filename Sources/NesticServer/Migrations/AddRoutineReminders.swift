import Fluent
struct AddRoutineReminders: AsyncMigration {
    func prepare(on db: any Database) async throws {
        try await db.schema("nest_reminders").field("routine_id", .uuid).field("last_completed_at", .datetime).update()
    }
    func revert(on db: any Database) async throws {
        try await db.schema("nest_reminders").deleteField("routine_id").deleteField("last_completed_at").update()
    }
}
