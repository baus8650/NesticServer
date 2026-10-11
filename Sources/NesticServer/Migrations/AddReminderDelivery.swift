import Fluent
struct AddReminderDelivery: AsyncMigration {
    func prepare(on db: any Database) async throws {
        try await db.schema("nest_reminder_preferences").field("delivery_mode", .string).update()
    }
    func revert(on db: any Database) async throws {
        try await db.schema("nest_reminder_preferences").deleteField("delivery_mode").update()
    }
}
