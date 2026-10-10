import Fluent

struct AddDoseReminders: AsyncMigration {
    func prepare(on db: any Database) async throws {
        try await db.schema("nest_reminders").field("interval_hours", .double).field("total_pills", .int).update()
    }
    func revert(on db: any Database) async throws {
        try await db.schema("nest_reminders").deleteField("interval_hours").deleteField("total_pills").update()
    }
}
