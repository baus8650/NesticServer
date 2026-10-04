import Fluent

struct AddActionEventPhoto: AsyncMigration {
    func prepare(on db: any Database) async throws {
        try await db.schema("action_events")
            .field("photo_url", .string)
            .update()
    }

    func revert(on db: any Database) async throws {
        try await db.schema("action_events")
            .deleteField("photo_url")
            .update()
    }
}
