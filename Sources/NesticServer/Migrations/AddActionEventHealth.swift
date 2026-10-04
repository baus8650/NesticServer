import Fluent

struct AddActionEventHealth: AsyncMigration {
    func prepare(on db: any Database) async throws {
        try await db.schema("action_events")
            .field("resolved_at", .datetime)
            .field("resolution_note", .string)
            .update()
    }

    func revert(on db: any Database) async throws {
        try await db.schema("action_events")
            .deleteField("resolution_note")
            .deleteField("resolved_at")
            .update()
    }
}
