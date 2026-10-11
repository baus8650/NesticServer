import Fluent
struct AddReminderScheduleOptions: AsyncMigration {
    func prepare(on db: any Database) async throws {
        try await db.schema("nest_reminders").field("recurrence_days", .int).field("start_from_first_tracking", .bool).update()
    }
    func revert(on db: any Database) async throws {
        try await db.schema("nest_reminders").deleteField("recurrence_days").deleteField("start_from_first_tracking").update()
    }
}
